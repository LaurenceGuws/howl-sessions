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
      final preview = await client.readTextPreview(
        endpoint,
        before.serverId,
        sessionId,
        instanceId,
      );
      expect(preview.serverId, before.serverId);
      expect(preview.sessionId, sessionId);
      expect(preview.instanceId, instanceId);
      expect(preview.clientId, greaterThan(BigInt.zero));
      expect(preview.rows, 24);
      expect(preview.columns, 80);
      expect(preview.lines, hasLength(24));

      final follower = await client.followText(
        endpoint,
        before.serverId,
        sessionId,
        instanceId,
      );
      try {
        final live = await follower.next().timeout(const Duration(seconds: 10));
        expect(live.serverId, before.serverId);
        expect(live.instanceId, instanceId);
        expect(live.rows, 24);
        expect(live.lines, hasLength(24));
        final blocked = follower.next().then(
          (_) => false,
          onError: (Object _) => true,
        );
        await follower.close().timeout(const Duration(seconds: 5));
        expect(await blocked, isTrue);
      } finally {
        await follower.close();
      }

      final inputFollower = await client.followText(
        endpoint,
        before.serverId,
        sessionId,
        instanceId,
      );
      try {
        final initial = await inputFollower.next().timeout(
          const Duration(seconds: 10),
        );
        final input = await client.openTextInput(
          endpoint,
          before.serverId,
          sessionId,
          instanceId,
        );
        try {
          await input.ready.timeout(const Duration(seconds: 10));
          // Flutter sends on a separate native attachment while the long-poll
          // remains outstanding on the observation attachment.
          final next = inputFollower.next();
          await input
              .sendText('echo HOWL_ANDROID_INPUT\n')
              .timeout(const Duration(seconds: 10));
          final changed = await next.timeout(const Duration(seconds: 10));
          expect(changed.clientId, initial.clientId);
          expect(
            changed.deliveryRevision,
            greaterThan(initial.deliveryRevision),
          );
        } finally {
          await input.close();
        }
      } finally {
        await inputFollower.close();
      }
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
