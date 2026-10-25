import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:howl_server_client/howl_server_client.dart';
import 'package:howl_server_client/src/native_attachment.dart';
import 'package:howl_server_client/src/native_identity.dart';

/// A real terminal attachment + immutable Unicode projection canary.
/// A development Server must be started explicitly; this never starts one.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/attachment_canary.dart ENDPOINT');
    exitCode = 64;
    return;
  }

  const client = ServerClient();
  final endpoint = args.single;
  final tree = await client.readTree(endpoint);
  final nativeServerId = calloc<Uint64>();
  try {
    nativeServerId.value = toNativeIdentity(tree.serverId);
    if (fromNativeIdentity(nativeServerId.value) != tree.serverId) {
      throw StateError(
        'Dart native u64 conversion lost Server identity: '
        'expected=${tree.serverId} raw=${toNativeIdentity(tree.serverId)} '
        'observed=${nativeServerId.value}',
      );
    }
  } finally {
    calloc.free(nativeServerId);
  }
  final session = await client.createSession(
    endpoint,
    'attachment_canary_${DateTime.now().microsecondsSinceEpoch}',
  );
  BigInt? instance;
  try {
    instance = await client.createInstance(
      endpoint,
      InstanceLaunch(
        sessionId: session,
        shell: '/bin/sh',
        rows: 24,
        columns: 80,
        historyRows: 128,
      ),
    );
    final attachment = NativeTerminalAttachment.connect(
      endpoint,
      tree.serverId,
      session,
      instance,
    );
    try {
      final first = attachment.observe();
      if (first.rows != 24 ||
          first.columns != 80 ||
          first.lines.length != first.rows ||
          first.serverId != tree.serverId ||
          first.sessionId != session ||
          first.instanceId != instance ||
          first.clientId == BigInt.zero) {
        throw StateError('Incomplete initial terminal attachment');
      }
      attachment.sendText('echo HOWL_TERMINAL_CANARY\n');
      final observed = attachment.observe(
        afterRevision: first.deliveryRevision,
      );
      if (observed.deliveryRevision <= first.deliveryRevision ||
          observed.clientId != first.clientId) {
        throw StateError('No advancing observation on the same attachment');
      }
      attachment.resize(26, 90);
      final resized = attachment.observe(
        afterRevision: observed.deliveryRevision,
      );
      if (resized.rows != 26 ||
          resized.columns != 90 ||
          resized.deliveryRevision <= observed.deliveryRevision ||
          resized.clientId != first.clientId) {
        throw StateError('Resize was not observed on the same attachment');
      }
      final follower = await client.followText(
        endpoint,
        tree.serverId,
        session,
        instance,
      );
      try {
        final initial = await follower.next().timeout(
          const Duration(seconds: 5),
        );
        if (initial.serverId != first.serverId ||
            initial.instanceId != first.instanceId ||
            initial.clientId == first.clientId) {
          throw StateError(
            'Live follower lost independent attachment identity',
          );
        }
        final next = follower.next();
        attachment.sendText('echo HOWL_FOLLOW_CANARY\n');
        final changed = await next.timeout(const Duration(seconds: 5));
        if (changed.deliveryRevision <= initial.deliveryRevision ||
            changed.clientId != initial.clientId) {
          throw StateError('Live follower did not advance without polling');
        }
        final blocked = follower.next().then(
          (_) => false,
          onError: (Object _) => true,
        );
        await follower.close().timeout(const Duration(seconds: 5));
        if (!await blocked) {
          throw StateError('Closing blocked follower did not cancel the cut');
        }
      } finally {
        await follower.close();
      }

      final inputFollower = await client.followText(
        endpoint,
        tree.serverId,
        session,
        instance,
      );
      try {
        final initial = await inputFollower.next().timeout(
          const Duration(seconds: 5),
        );
        final input = await client.openTextInput(
          endpoint,
          tree.serverId,
          session,
          instance,
        );
        try {
          await input.ready.timeout(const Duration(seconds: 5));
          // One attachment is blocked in observe while another owns input.
          // Sending over that first attachment would deadlock this test.
          final waiting = inputFollower.next();
          await input
              .sendText('echo HOWL_INDEPENDENT_INPUT\n')
              .timeout(const Duration(seconds: 5));
          final delivered = await waiting.timeout(const Duration(seconds: 5));
          if (delivered.deliveryRevision <= initial.deliveryRevision ||
              delivered.clientId != initial.clientId) {
            throw StateError(
              'Independent input did not wake parked observation',
            );
          }
          try {
            await input.sendText('x' * 65536);
            throw StateError('Oversize input was accepted');
          } on RangeError {
            // A rejected operation must not tear down the retained attachment.
          }
          await input
              .sendText('echo HOWL_INPUT_AFTER_REJECTION\n')
              .timeout(const Duration(seconds: 5));
        } finally {
          await input.close();
        }
      } finally {
        await inputFollower.close();
      }
      final rejected = await client.openTextInput(
        endpoint,
        tree.serverId + BigInt.one,
        session,
        instance,
      );
      try {
        var refused = false;
        try {
          await rejected.ready.timeout(const Duration(seconds: 5));
        } on StateError {
          refused = true;
        }
        if (!refused) {
          throw StateError('Incorrect Server identity opened an attachment');
        }
      } finally {
        await rejected.close();
      }
      stdout.writeln(
        jsonEncode({
          'status': 'pass',
          'server_id': '${first.serverId}',
          'session_id': '$session',
          'instance_id': '$instance',
          'client_id': '${first.clientId}',
          'first_revision': '${first.deliveryRevision}',
          'next_revision': '${resized.deliveryRevision}',
          'rows': resized.rows,
          'columns': resized.columns,
          'nonempty_rows': observed.lines
              .where((line) => line.trim().isNotEmpty)
              .length,
          'live_follow': 'pass',
          'independent_input': 'pass',
          'blocked_cancel': 'pass',
        }),
      );
    } finally {
      attachment.close();
    }

    final preview = await client.readTextPreview(
      endpoint,
      tree.serverId,
      session,
      instance,
    );
    if (preview.clientId == BigInt.zero ||
        preview.lines.length != preview.rows) {
      throw StateError('Short-lived text preview lost identity or rows');
    }
  } finally {
    if (instance != null) {
      await client.closeInstance(endpoint, session, instance);
    }
    await client.closeSession(endpoint, session);
  }
}
