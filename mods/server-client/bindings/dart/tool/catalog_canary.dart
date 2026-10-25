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
  final name = 'dart_canary_${DateTime.now().microsecondsSinceEpoch}';
  final id = await client.createSession(endpoint, name);
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
    );
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
      await client.closeInstance(endpoint, id, instanceId);
    }
    await client.closeSession(endpoint, id);
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
    }),
  );
}
