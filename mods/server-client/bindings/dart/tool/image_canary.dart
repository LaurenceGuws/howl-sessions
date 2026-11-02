import 'dart:convert';
import 'dart:io';

import 'package:howl_server_client/howl_server_client.dart';
import 'package:howl_server_client/src/native_attachment.dart';

/// Only against an explicitly started disposable Server. No renderer or fake
/// residency is involved: this qualifies the independent Client image owner.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('usage: dart run tool/image_canary.dart ENDPOINT');
    exitCode = 64;
    return;
  }
  const client = ServerClient();
  final endpoint = arguments.single;
  final tree = await client.readTree(endpoint);
  final session = await client.createSession(
    endpoint,
    'image_${DateTime.now().microsecondsSinceEpoch}',
    serverId: tree.serverId,
  );
  NativeTerminalAttachment? attachment;
  TerminalImageData? copied;
  try {
    final instance = await client.createInstance(
      endpoint,
      InstanceLaunch(
        sessionId: session,
        shell: '/bin/sh',
        rows: 4,
        columns: 20,
        historyRows: 16,
        command:
            r"printf '\033_Ga=T,f=32,s=1,v=1,i=7,q=2;AQIDBA==\033\\'; exec cat",
      ),
      serverId: tree.serverId,
    );
    final owner = NativeTerminalAttachment.connect(
      endpoint,
      tree.serverId,
      session,
      instance,
    );
    attachment = owner;
    owner.enableIncrementalObservation();
    final watch = Stopwatch()..start();
    while (copied == null && watch.elapsed < const Duration(seconds: 5)) {
      copied = owner.observeWith((snapshot, _) {
        final manifest = owner.imageManifest(snapshot);
        if (manifest.isEmpty) return null;
        if (manifest.length != 1) throw StateError('Unexpected image manifest');
        final image = owner.fetchImage(manifest.single);
        final after = owner.imageManifest(snapshot);
        if (after.single != manifest.single)
          throw StateError('Fetch changed borrowed snapshot');
        return image;
      });
      if (copied == null)
        await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final image = copied;
    if (image == null ||
        image.pixels.length != 4 ||
        image.pixels[0] != 1 ||
        image.pixels[1] != 2 ||
        image.pixels[2] != 3 ||
        image.pixels[3] != 4) {
      throw StateError('Exact RGBA image was not delivered');
    }
    final stale = TerminalImageIdentity(
      id: image.identity.id,
      generation: image.identity.generation + BigInt.one,
      width: image.identity.width,
      height: image.identity.height,
    );
    var rejected = false;
    try {
      owner.fetchImage(stale);
    } on ServerClientFailure catch (failure) {
      if (failure.status != 29) rethrow;
      rejected = true;
    }
    if (!rejected) throw StateError('Stale image generation was accepted');
    image.pixels[0] = 99;
    final fresh = owner.fetchImage(image.identity);
    if (fresh.pixels[0] != 1)
      throw StateError('Copied pixels borrowed native storage');

    final interrupt = NativeTerminalInterrupt.create();
    NativeTerminalAttachment? cancelled;
    try {
      cancelled = NativeTerminalAttachment.connect(
        endpoint,
        tree.serverId,
        session,
        instance,
        interruptAddress: interrupt.address,
      );
      interrupt.cancel();
      var interrupted = false;
      try {
        cancelled.fetchImage(image.identity);
      } on ServerClientFailure catch (failure) {
        if (failure.status != 4 && failure.status != 7) rethrow;
        interrupted = true;
      }
      if (!interrupted)
        throw StateError('Cancelled image request was accepted');
    } finally {
      cancelled?.close();
      interrupt.close();
    }
    owner.close();
    attachment = null;
    if (image.pixels[0] != 99 || fresh.pixels[3] != 4)
      throw StateError('Pixels expired with their owner');
    stdout.writeln(
      jsonEncode({
        'status': 'pass',
        'server_id': '${tree.serverId}',
        'snapshot_held_during_fetch': true,
        'copied_rgba': true,
        'stale_rejected_connection_reusable': true,
        'pre_cancelled_fetch': true,
        'pixels_outlive_attachment': true,
      }),
    );
  } finally {
    attachment?.close();
    await client.closeSession(endpoint, session, serverId: tree.serverId);
  }
}
