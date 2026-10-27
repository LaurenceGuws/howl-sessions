import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'native_attachment.dart';
import 'terminal_text.dart';
import 'terminal_keys.dart';

/// Each public role owns a distinct isolate and native Instance attachment.
/// Only the worker implementation is shared between observation and input.
///
/// One call at a time. Only the C interrupt's documented thread-safe cancel
/// crosses isolates; closing joins the worker before releasing its token.
final class _TerminalAttachment {
  _TerminalAttachment._(this._interrupt, this._inbox, this._inputOnly) {
    _events = _inbox.listen(_receive);
  }

  final NativeTerminalInterrupt _interrupt;
  final ReceivePort _inbox;
  final bool _inputOnly;
  late final StreamSubscription<Object?> _events;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _exited = Completer<void>();
  SendPort? _commands;
  Completer<TerminalTextSnapshot>? _pending;
  Completer<void>? _pendingInput;
  String? _failure;
  bool _stopping = false;
  Future<void>? _closeFuture;

  static Future<_TerminalAttachment> start(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
    bool inputOnly,
  ) async {
    final interrupt = NativeTerminalInterrupt.create();
    final inbox = ReceivePort();
    final attachment = _TerminalAttachment._(interrupt, inbox, inputOnly);
    try {
      await Isolate.spawn<_AttachmentRequest>(
        _runAttachment,
        _AttachmentRequest(
          inbox.sendPort,
          interrupt.address,
          endpoint,
          serverId,
          sessionId,
          instanceId,
          inputOnly,
        ),
        onExit: inbox.sendPort,
        onError: inbox.sendPort,
        errorsAreFatal: true,
      );
      return attachment;
    } catch (_) {
      await attachment._events.cancel();
      inbox.close();
      interrupt.close();
      rethrow;
    }
  }

  /// Waits for exactly one newer cut; the first request is immediate.
  Future<TerminalTextSnapshot> next() async {
    if (_inputOnly) throw StateError('Input attachment cannot observe');
    await waitReady();
    if (_pending != null || _pendingInput != null) {
      throw StateError('Attachment operation already pending');
    }
    final result = Completer<TerminalTextSnapshot>();
    _pending = result;
    _commands!.send('next');
    return result.future;
  }

  Future<void> _sendInput(List<Object> command) async {
    if (!_inputOnly)
      throw StateError('Observation attachment cannot send input');
    await waitReady();
    if (_pending != null || _pendingInput != null) {
      throw StateError('Attachment operation already pending');
    }
    final result = Completer<void>();
    _pendingInput = result;
    _commands!.send(command);
    return result.future;
  }

  Future<void> _sendText(String text) {
    if (text.length > 65535) throw RangeError('Input exceeds 65535 bytes');
    final bytes = utf8.encode(text);
    if (bytes.isEmpty || bytes.length > 65535) {
      throw RangeError('Input must contain 1..65535 UTF-8 bytes');
    }
    return _sendInput(['text', text]);
  }

  Future<void> _sendNamedKey(
    TerminalNamedKey key,
    TerminalKeyAction action,
    int modifiers,
  ) {
    validateTerminalModifiers(modifiers);
    return _sendInput(['named', key.code, action.code, modifiers]);
  }

  Future<void> _sendUnicodeKey(
    int scalar,
    TerminalKeyAction action,
    int modifiers,
  ) {
    validateTerminalScalar(scalar);
    validateTerminalModifiers(modifiers);
    return _sendInput(['unicode', scalar, action.code, modifiers]);
  }

  /// A worker existing is not proof that its native connection is ready.
  /// The owner keeps the attachment available for cancellation while waiting.
  Future<void> waitReady() async {
    if (_stopping) throw StateError('Terminal attachment is closing');
    await _ready.future;
    if (_stopping) throw StateError('Terminal attachment is closing');
    if (_failure != null) throw StateError(_failure!);
  }

  Future<void> close() => _closeFuture ??= _stop();

  Future<void> _stop() async {
    _stopping = true;
    _pending?.completeError(StateError('Terminal observation cancelled'));
    _pending = null;
    _pendingInput?.completeError(StateError('Terminal input cancelled'));
    _pendingInput = null;
    // The worker borrows the token through connection setup and blocked I/O.
    // Cancel is synchronous; the worker cannot free the token itself.
    _interrupt.cancel();
    _commands?.send('close');
    await _exited.future;
    await _events.cancel();
    _inbox.close();
    _interrupt.close();
  }

  void _receive(Object? message) {
    if (message == null) {
      _failure ??= 'Terminal attachment exited';
      if (!_ready.isCompleted) _ready.complete();
      _pending?.completeError(StateError(_failure!));
      _pending = null;
      _pendingInput?.completeError(StateError(_failure!));
      _pendingInput = null;
      if (!_exited.isCompleted) _exited.complete();
      return;
    }
    if (message is! List || message.isEmpty) {
      _failure = 'Invalid terminal attachment response';
      return;
    }
    switch (message.first) {
      case 'ready':
        _commands = message[1] as SendPort;
        if (!_ready.isCompleted) _ready.complete();
        if (_stopping) _commands!.send('close');
      case 'frame':
        final pending = _pending;
        _pending = null;
        if (!_stopping && pending != null) {
          pending.complete(message[1] as TerminalTextSnapshot);
        }
      case 'sent':
        final pending = _pendingInput;
        _pendingInput = null;
        if (!_stopping) pending?.complete();
      case 'failed':
        _failure = message[1] as String;
        if (!_ready.isCompleted) _ready.complete();
        _pending?.completeError(StateError(_failure!));
        _pending = null;
        _pendingInput?.completeError(StateError(_failure!));
        _pendingInput = null;
      default:
        // Isolate error messages are [error, stack], not our tagged records.
        _failure = 'Terminal attachment failed: $message';
        if (!_ready.isCompleted) _ready.complete();
        _pending?.completeError(StateError(_failure!));
        _pending = null;
        _pendingInput?.completeError(StateError(_failure!));
        _pendingInput = null;
    }
  }
}

/// Pull-driven observations with one outstanding native row-delta cut.
/// This connection cannot be used for input while its long-poll is parked.
final class TerminalTextObserver {
  TerminalTextObserver._(this._attachment);

  final _TerminalAttachment _attachment;

  static Future<TerminalTextObserver> start(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
  ) async => TerminalTextObserver._(
    await _TerminalAttachment.start(
      endpoint,
      serverId,
      sessionId,
      instanceId,
      false,
    ),
  );

  Future<TerminalTextSnapshot> next() => _attachment.next();

  Future<void> close() => _attachment.close();
}

/// A distinct retained Instance connection for ordered text input.
///
/// Unlike a parked observation attachment, this connection is never waiting
/// for terminal changes. There is at most one outstanding input operation.
final class TerminalTextInput {
  TerminalTextInput._(this._attachment);

  final _TerminalAttachment _attachment;

  static Future<TerminalTextInput> start(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
  ) async => TerminalTextInput._(
    await _TerminalAttachment.start(
      endpoint,
      serverId,
      sessionId,
      instanceId,
      true,
    ),
  );

  Future<void> sendText(String text) => _attachment._sendText(text);

  Future<void> sendNamedKey(
    TerminalNamedKey key,
    TerminalKeyAction action, {
    int modifiers = 0,
  }) => _attachment._sendNamedKey(key, action, modifiers);

  Future<void> sendUnicodeKey(
    int scalar,
    TerminalKeyAction action, {
    int modifiers = 0,
  }) => _attachment._sendUnicodeKey(scalar, action, modifiers);

  Future<void> get ready => _attachment.waitReady();

  Future<void> close() => _attachment.close();
}

final class _AttachmentRequest {
  const _AttachmentRequest(
    this.events,
    this.interruptAddress,
    this.endpoint,
    this.serverId,
    this.sessionId,
    this.instanceId,
    this.inputOnly,
  );

  final SendPort events;
  final int interruptAddress;
  final String endpoint;
  final BigInt serverId;
  final BigInt sessionId;
  final BigInt instanceId;
  final bool inputOnly;
}

Future<void> _runAttachment(_AttachmentRequest request) async {
  final commands = ReceivePort();
  NativeTerminalAttachment? attachment;
  try {
    attachment = NativeTerminalAttachment.connect(
      request.endpoint,
      request.serverId,
      request.sessionId,
      request.instanceId,
      interruptAddress: request.interruptAddress,
    );
    if (!request.inputOnly) attachment.enableIncrementalObservation();
    request.events.send(['ready', commands.sendPort]);
    var revision = BigInt.zero;
    await for (final command in commands) {
      if (command == 'close') break;
      if (command == 'next' && !request.inputOnly) {
        final snapshot = attachment.observe(afterRevision: revision);
        revision = snapshot.deliveryRevision;
        request.events.send(['frame', snapshot]);
      } else if (command is List && request.inputOnly && command.isNotEmpty) {
        switch (command.first) {
          case 'text' when command.length == 2:
            attachment.sendText(command[1] as String);
          case 'named' when command.length == 4:
            final key = TerminalNamedKey.values.singleWhere(
              (key) => key.code == command[1],
            );
            final action = TerminalKeyAction.values.singleWhere(
              (action) => action.code == command[2],
            );
            attachment.sendNamedKey(key, action, modifiers: command[3] as int);
          case 'unicode' when command.length == 4:
            final action = TerminalKeyAction.values.singleWhere(
              (action) => action.code == command[2],
            );
            attachment.sendUnicodeKey(
              command[1] as int,
              action,
              modifiers: command[3] as int,
            );
          default:
            throw StateError('Invalid attachment input command');
        }
        request.events.send(['sent']);
      } else {
        throw StateError('Invalid attachment command');
      }
    }
  } catch (error) {
    request.events.send(['failed', error.toString()]);
  } finally {
    attachment?.close();
    commands.close();
  }
}
