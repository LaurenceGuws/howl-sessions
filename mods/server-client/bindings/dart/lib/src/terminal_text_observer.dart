import 'dart:async';
import 'dart:isolate';

import 'native_attachment.dart';
import 'terminal_text.dart';

/// Pull-driven live terminal observations over one retained native attachment.
///
/// The caller requests at most one cut at a time. A worker isolate owns every
/// attachment operation; only the C interrupt's documented thread-safe cancel
/// crosses isolates. Closing waits for the worker to exit before freeing it.
/// This attachment is observation-only: a parked long-poll cannot also accept
/// terminal input on the same Server connection.
final class TerminalTextObserver {
  TerminalTextObserver._(this._interrupt, this._inbox) {
    _events = _inbox.listen(_receive);
  }

  final NativeTerminalInterrupt _interrupt;
  final ReceivePort _inbox;
  late final StreamSubscription<Object?> _events;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _exited = Completer<void>();
  SendPort? _commands;
  Completer<TerminalTextSnapshot>? _pending;
  String? _failure;
  bool _stopping = false;
  Future<void>? _closeFuture;

  static Future<TerminalTextObserver> start(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
  ) async {
    final interrupt = NativeTerminalInterrupt.create();
    final inbox = ReceivePort();
    final observer = TerminalTextObserver._(interrupt, inbox);
    try {
      await Isolate.spawn<_ObservationRequest>(
        _observe,
        _ObservationRequest(
          inbox.sendPort,
          interrupt.address,
          endpoint,
          serverId,
          sessionId,
          instanceId,
        ),
        onExit: inbox.sendPort,
        onError: inbox.sendPort,
        errorsAreFatal: true,
      );
      return observer;
    } catch (_) {
      await observer._events.cancel();
      inbox.close();
      interrupt.close();
      rethrow;
    }
  }

  /// Waits for exactly one newer cut; the first request is immediate.
  Future<TerminalTextSnapshot> next() async {
    if (_stopping) throw StateError('Terminal observer is closing');
    await _ready.future;
    if (_stopping) throw StateError('Terminal observer is closing');
    if (_failure != null) throw StateError(_failure!);
    if (_pending != null) {
      throw StateError('Terminal observation already pending');
    }
    final result = Completer<TerminalTextSnapshot>();
    _pending = result;
    _commands!.send('next');
    return result.future;
  }

  Future<void> close() => _closeFuture ??= _stop();

  Future<void> _stop() async {
    _stopping = true;
    _pending?.completeError(StateError('Terminal observation cancelled'));
    _pending = null;
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
      _failure ??= 'Terminal observer exited';
      if (!_ready.isCompleted) _ready.complete();
      _pending?.completeError(StateError(_failure!));
      _pending = null;
      if (!_exited.isCompleted) _exited.complete();
      return;
    }
    if (message is! List || message.isEmpty) {
      _failure = 'Invalid terminal observer response';
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
      case 'failed':
        _failure = message[1] as String;
        if (!_ready.isCompleted) _ready.complete();
        _pending?.completeError(StateError(_failure!));
        _pending = null;
      default:
        // Isolate error messages are [error, stack], not our tagged records.
        _failure = 'Terminal observer failed: $message';
        if (!_ready.isCompleted) _ready.complete();
        _pending?.completeError(StateError(_failure!));
        _pending = null;
    }
  }
}

final class _ObservationRequest {
  const _ObservationRequest(
    this.events,
    this.interruptAddress,
    this.endpoint,
    this.serverId,
    this.sessionId,
    this.instanceId,
  );

  final SendPort events;
  final int interruptAddress;
  final String endpoint;
  final BigInt serverId;
  final BigInt sessionId;
  final BigInt instanceId;
}

Future<void> _observe(_ObservationRequest request) async {
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
    attachment.enableIncrementalObservation();
    request.events.send(['ready', commands.sendPort]);
    var revision = BigInt.zero;
    await for (final command in commands) {
      if (command == 'close') break;
      if (command != 'next') throw StateError('Unknown observation command');
      final snapshot = attachment.observe(afterRevision: revision);
      revision = snapshot.deliveryRevision;
      request.events.send(['frame', snapshot]);
    }
  } catch (error) {
    request.events.send(['failed', error.toString()]);
  } finally {
    attachment?.close();
    commands.close();
  }
}
