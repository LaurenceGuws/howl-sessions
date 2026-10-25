import 'dart:async';
import 'dart:isolate';

import 'package:howl_server_client/src/native_attachment.dart';

import 'frame.dart';
import 'native.dart';

/// One dedicated Instance observation, with a native renderer in its worker.
///
/// Only copied frames cross isolates. Flutter reports actual decoded texture
/// residency on each pull; capture never treats an unconfirmed upload as live.
final class RenderObserver {
  RenderObserver._(this._interrupt, this._inbox) {
    _subscription = _inbox.listen(_receive);
  }

  final NativeTerminalInterrupt _interrupt;
  final ReceivePort _inbox;
  late final StreamSubscription<Object?> _subscription;
  final Completer<void> _ready = Completer<void>();
  final Completer<void> _exited = Completer<void>();
  SendPort? _commands;
  Completer<RenderFrame>? _pending;
  String? _failure;
  bool _stopping = false;
  Future<void>? _closeFuture;

  static Future<RenderObserver> start(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId, {
    required String fontPath,
    List<String> fallbackPaths = const [],
    int pixelSize = 16,
    String? libraryPath,
  }) async {
    final interrupt = NativeTerminalInterrupt.create(libraryPath: libraryPath);
    final inbox = ReceivePort();
    final result = RenderObserver._(interrupt, inbox);
    try {
      await Isolate.spawn<_Request>(
        _run,
        _Request(
          inbox.sendPort,
          interrupt.address,
          endpoint,
          serverId,
          sessionId,
          instanceId,
          fontPath,
          fallbackPaths,
          pixelSize,
          libraryPath,
        ),
        onExit: inbox.sendPort,
        onError: inbox.sendPort,
        errorsAreFatal: true,
      );
      return result;
    } catch (_) {
      await result._subscription.cancel();
      inbox.close();
      interrupt.close();
      rethrow;
    }
  }

  Future<RenderFrame> next({List<RenderResidency> resident = const []}) async {
    if (_stopping) throw StateError('Render observation is closing');
    await _ready.future;
    if (_stopping) throw StateError('Render observation is closing');
    if (_failure != null) throw StateError(_failure!);
    if (_pending != null) {
      throw StateError('Render observation already pending');
    }
    final pending = Completer<RenderFrame>();
    _pending = pending;
    _commands!.send(['next', resident]);
    return pending.future;
  }

  Future<void> close() => _closeFuture ??= _stop();

  Future<void> _stop() async {
    _stopping = true;
    _pending?.completeError(StateError('Render observation cancelled'));
    _pending = null;
    // The C interrupt is the only object borrowed across isolates.
    _interrupt.cancel();
    _commands?.send('close');
    await _exited.future;
    await _subscription.cancel();
    _inbox.close();
    _interrupt.close();
  }

  void _receive(Object? message) {
    if (message == null) {
      _failure ??= 'Render observer exited';
      if (!_ready.isCompleted) _ready.complete();
      _pending?.completeError(StateError(_failure!));
      _pending = null;
      if (!_exited.isCompleted) _exited.complete();
      return;
    }
    if (message is! List || message.isEmpty) {
      _failure = 'Invalid Render observation response';
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
        if (!_stopping) pending?.complete(message[1] as RenderFrame);
      case 'failed':
        _failure = message[1] as String;
        if (!_ready.isCompleted) _ready.complete();
        _pending?.completeError(StateError(_failure!));
        _pending = null;
      default:
        _failure = 'Render observer failed: $message';
        if (!_ready.isCompleted) _ready.complete();
        _pending?.completeError(StateError(_failure!));
        _pending = null;
    }
  }
}

final class _Request {
  const _Request(
    this.events,
    this.interrupt,
    this.endpoint,
    this.serverId,
    this.sessionId,
    this.instanceId,
    this.fontPath,
    this.fallbackPaths,
    this.pixelSize,
    this.libraryPath,
  );

  final SendPort events;
  final int interrupt;
  final String endpoint;
  final BigInt serverId, sessionId, instanceId;
  final String fontPath;
  final List<String> fallbackPaths;
  final int pixelSize;
  final String? libraryPath;
}

Future<void> _run(_Request request) async {
  final commands = ReceivePort();
  NativeTerminalAttachment? attachment;
  NativeRenderer? renderer;
  try {
    attachment = NativeTerminalAttachment.connect(
      request.endpoint,
      request.serverId,
      request.sessionId,
      request.instanceId,
      interruptAddress: request.interrupt,
      libraryPath: request.libraryPath,
    );
    attachment.enableIncrementalObservation();
    renderer = NativeRenderer.create(
      request.fontPath,
      fallbacks: request.fallbackPaths,
      pixelSize: request.pixelSize,
      libraryPath: request.libraryPath,
    );
    request.events.send(['ready', commands.sendPort]);
    var revision = BigInt.zero;
    await for (final command in commands) {
      if (command == 'close') break;
      if (command is! List ||
          command.length != 2 ||
          command.first != 'next' ||
          command[1] is! List<RenderResidency>) {
        throw StateError('Invalid Render observation command');
      }
      final resident = command[1] as List<RenderResidency>;
      final observed = attachment.observeWith(
        (snapshot, deliveryRevision) =>
            (renderer!.capture(snapshot, resident: resident), deliveryRevision),
        afterRevision: revision,
      );
      revision = observed.$2;
      request.events.send(['frame', observed.$1]);
    }
  } catch (error) {
    request.events.send(['failed', error.toString()]);
  } finally {
    try {
      renderer?.close();
    } finally {
      attachment?.close();
      commands.close();
    }
  }
}
