/// Server catalog and control operations backed by Howl's own native client.
///
/// Every operation owns a short-lived control connection on a worker isolate.
/// Long-lived Instance attachments are separate and are not represented here.
library;

import 'dart:isolate';

import 'src/catalog.dart';
import 'src/native.dart';
import 'src/launch.dart';

export 'src/catalog.dart';
export 'src/launch.dart';

/// The native module owns framing and transport. Flutter schedules requests.
final class ServerClient {
  const ServerClient();

  Future<SessionTree> readTree(String endpoint) =>
      Isolate.run(() => NativeServerClient().readTree(endpoint));

  Future<BigInt> createSession(String endpoint, String name) =>
      Isolate.run(() => NativeServerClient().createSession(endpoint, name));

  Future<void> closeSession(String endpoint, BigInt sessionId) =>
      Isolate.run(() => NativeServerClient().closeSession(endpoint, sessionId));

  Future<BigInt> createInstance(String endpoint, InstanceLaunch launch) =>
      Isolate.run(() => NativeServerClient().createInstance(endpoint, launch));

  Future<void> closeInstance(
    String endpoint,
    BigInt sessionId,
    BigInt instanceId,
  ) => Isolate.run(
    () => NativeServerClient().closeInstance(endpoint, sessionId, instanceId),
  );
}
