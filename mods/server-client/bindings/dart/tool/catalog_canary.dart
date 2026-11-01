import 'dart:convert';
import 'dart:io';

import 'package:howl_server_client/howl_server_client.dart';

/// Against an explicitly started development Server, verifies the real shared
/// ABI, ownership/copying, Session and Instance CRUD with checked cleanup.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('usage: dart run tool/catalog_canary.dart ENDPOINT');
    exitCode = 64;
    return;
  }

  final client = const ServerClient();
  final endpoint = arguments.single;
  final before = await client.readTree(endpoint);
  final staleServer = before.serverId == BigInt.one ? BigInt.two : BigInt.one;
  await rejectStale(
    () =>
        client.createSession(endpoint, 'must_not_exist', serverId: staleServer),
  );
  final rejected = await client.readTree(endpoint);
  if (rejected.revision != before.revision)
    throw StateError('Stale create mutated catalog');
  final name = 'dart_canary_${DateTime.now().microsecondsSinceEpoch}';
  final id = await client.createSession(
    endpoint,
    name,
    serverId: before.serverId,
  );
  BigInt? instanceId;
  try {
    final during = await client.readTree(endpoint);
    if (during.serverId != before.serverId ||
        during.revision <= before.revision ||
        !during.sessions.any(
          (session) => session.id == id && session.name == name,
        )) {
      throw StateError('Created Session missing or Server incarnation changed');
    }
    instanceId = await client.createInstance(
      endpoint,
      InstanceLaunch(
        sessionId: id,
        shell: '/bin/sh',
        rows: 24,
        columns: 80,
        historyRows: 128,
      ),
      serverId: before.serverId,
    );
    final beforeReject = await client.readTree(endpoint);
    await rejectStale(
      () => client.createInstance(
        endpoint,
        InstanceLaunch(
          sessionId: id,
          shell: '/bin/sh',
          rows: 24,
          columns: 80,
          historyRows: 128,
        ),
        serverId: staleServer,
      ),
    );
    await rejectStale(
      () => client.closeInstance(
        endpoint,
        id,
        instanceId!,
        serverId: staleServer,
      ),
    );
    await rejectStale(
      () => client.closeSession(endpoint, id, serverId: staleServer),
    );
    final afterReject = await client.readTree(endpoint);
    if (afterReject.revision != beforeReject.revision) {
      throw StateError('Stale mutation changed catalog');
    }
    final running = await client.readTree(endpoint);
    if (!running.sessions.any(
      (session) =>
          session.id == id &&
          session.instances.any(
            (instance) => instance.id == instanceId && instance.running,
          ),
    )) {
      throw StateError('Created Instance missing from Server catalog');
    }
  } finally {
    if (instanceId != null) {
      await client.closeInstance(
        endpoint,
        id,
        instanceId,
        serverId: before.serverId,
      );
    }
    await client.closeSession(endpoint, id, serverId: before.serverId);
  }
  final after = await client.readTree(endpoint);
  if (after.sessions.any((session) => session.id == id)) {
    throw StateError('Closed Session remains in Server catalog');
  }
  stdout.writeln(
    jsonEncode({
      'status': 'pass',
      'server_id': '${before.serverId}',
      'session_id': '$id',
      'instance_id': '$instanceId',
      'revision_before': '${before.revision}',
      'revision_after': '${after.revision}',
      'native_client': true,
      'stale_mutations_rejected': 4,
    }),
  );
}

Future<void> rejectStale(Future<Object?> Function() operation) async {
  try {
    await operation();
  } on ServerClientFailure catch (error) {
    if (error.status == 9) return;
    rethrow;
  }
  throw StateError('Stale mutation was accepted');
}
