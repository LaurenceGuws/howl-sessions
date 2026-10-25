import 'package:flutter_test/flutter_test.dart';
import 'package:howl_server_client/howl_server_client.dart';
import 'package:integration_test/integration_test.dart';

/// Exercises the real, packaged Server-client shared library on the device.
/// The Server is an explicitly selected development endpoint, not silently
/// localhost: test it over a real network or an explicitly named USB canary.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('native Session and Instance lifecycle over selected endpoint', (
    tester,
  ) async {
    const endpoint = String.fromEnvironment('HOWL_CANARY_ENDPOINT');
    if (endpoint.isEmpty) {
      fail('Set --dart-define=HOWL_CANARY_ENDPOINT=tcp://SERVER:PORT');
    }

    const client = ServerClient();
    final before = await client.readTree(endpoint);
    expect(before.serverId, greaterThan(BigInt.zero));

    final name = 'android_canary_${DateTime.now().microsecondsSinceEpoch}';
    final sessionId = await client.createSession(endpoint, name);
    BigInt? instanceId;
    try {
      final created = await client.readTree(endpoint);
      expect(created.serverId, before.serverId);
      expect(created.revision, greaterThan(before.revision));
      expect(
        created.sessions.any(
          (session) => session.id == sessionId && session.name == name,
        ),
        isTrue,
      );

      instanceId = await client.createInstance(
        endpoint,
        InstanceLaunch(
          sessionId: sessionId,
          shell: '/bin/sh',
          rows: 24,
          columns: 80,
          historyRows: 128,
        ),
      );
      final running = await client.readTree(endpoint);
      expect(running.serverId, before.serverId);
      expect(
        running.sessions.any(
          (session) =>
              session.id == sessionId &&
              session.instances.any(
                (instance) => instance.id == instanceId && instance.running,
              ),
        ),
        isTrue,
      );
    } finally {
      if (instanceId != null) {
        await client.closeInstance(endpoint, sessionId, instanceId);
      }
      await client.closeSession(endpoint, sessionId);
    }

    final after = await client.readTree(endpoint);
    expect(after.serverId, before.serverId);
    expect(after.sessions.any((session) => session.id == sessionId), isFalse);
  });
}
