/// Server catalog and control operations backed by Howl's own native client.
///
/// Every operation owns a short-lived control connection on a worker isolate.
/// Long-lived Instance attachments are separate and are not represented here.
library;

import 'dart:isolate';

import 'src/catalog.dart';
import 'src/native.dart';
import 'src/native_attachment.dart';
import 'src/launch.dart';
import 'src/terminal_text.dart';
import 'src/terminal_attachments.dart';

export 'src/catalog.dart';
export 'src/launch.dart';
export 'src/terminal_text.dart';
export 'src/terminal_attachments.dart';
export 'src/terminal_keys.dart';
export 'src/terminal_images.dart';

/// Short-lived management requests, fenced to the catalog incarnation the caller saw.
/// Implementations must never reconnect or replay an uncertain mutation implicitly.
abstract interface class ServerManagement {
  Future<SessionTree> readTree(String endpoint);
  Future<BigInt> createSession(
    String endpoint,
    String name, {
    required BigInt serverId,
  });
  Future<void> closeSession(
    String endpoint,
    BigInt sessionId, {
    required BigInt serverId,
  });
  Future<BigInt> createInstance(
    String endpoint,
    InstanceLaunch launch, {
    required BigInt serverId,
  });
  Future<void> closeInstance(
    String endpoint,
    BigInt sessionId,
    BigInt instanceId, {
    required BigInt serverId,
  });
}

/// The native module owns framing and transport. Flutter schedules requests.
final class ServerClient implements ServerManagement {
  const ServerClient();

  Future<SessionTree> readTree(String endpoint) =>
      Isolate.run(() => NativeServerClient().readTree(endpoint));

  Future<BigInt> createSession(
    String endpoint,
    String name, {
    required BigInt serverId,
  }) => Isolate.run(
    () =>
        NativeServerClient().createSession(endpoint, name, serverId: serverId),
  );

  Future<void> closeSession(
    String endpoint,
    BigInt sessionId, {
    required BigInt serverId,
  }) => Isolate.run(
    () => NativeServerClient().closeSession(
      endpoint,
      sessionId,
      serverId: serverId,
    ),
  );

  Future<BigInt> createInstance(
    String endpoint,
    InstanceLaunch launch, {
    required BigInt serverId,
  }) => Isolate.run(
    () => NativeServerClient().createInstance(
      endpoint,
      launch,
      serverId: serverId,
    ),
  );

  Future<void> closeInstance(
    String endpoint,
    BigInt sessionId,
    BigInt instanceId, {
    required BigInt serverId,
  }) => Isolate.run(
    () => NativeServerClient().closeInstance(
      endpoint,
      sessionId,
      instanceId,
      serverId: serverId,
    ),
  );

  /// One immutable, text-only terminal preview on a short-lived attachment.
  /// This is a canary; an interactive renderer needs a retained attachment.
  Future<TerminalTextSnapshot> readTextPreview(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
  ) => Isolate.run(() {
    final attachment = NativeTerminalAttachment.connect(
      endpoint,
      serverId,
      sessionId,
      instanceId,
    );
    try {
      return attachment.observe();
    } finally {
      attachment.close();
    }
  });

  /// One retained, cancellable, observation-only Instance attachment.
  Future<TerminalTextObserver> followText(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
  ) => TerminalTextObserver.start(endpoint, serverId, sessionId, instanceId);

  /// A separate retained attachment for input while observation is parked.
  Future<TerminalTextInput> openTextInput(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
  ) => TerminalTextInput.start(endpoint, serverId, sessionId, instanceId);

  /// Geometry has independent attachment identity and explicit lease intent.
  Future<TerminalGeometryAttachment> openGeometry(
    String endpoint,
    BigInt serverId,
    BigInt sessionId,
    BigInt instanceId,
  ) => TerminalGeometryAttachment.start(
    endpoint,
    serverId,
    sessionId,
    instanceId,
  );
}
