import 'dart:convert';
import 'dart:io';

import 'package:howl_server_client/howl_server_client.dart';

/// Real native ABI proof against an explicitly started disposable Server.
/// Creates and closes its own Session/Instance; never launches a listener.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/semantic_input_canary.dart ENDPOINT');
    exitCode = 64;
    return;
  }
  const client = ServerClient();
  final endpoint = args.single;
  final tree = await client.readTree(endpoint);
  final session = await client.createSession(
    endpoint,
    'semantic_keys_${DateTime.now().microsecondsSinceEpoch}',
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
    final observer = await client.followText(
      endpoint,
      tree.serverId,
      session,
      instance,
    );
    try {
      await observer.next().timeout(const Duration(seconds: 8));
      final input = await client.openTextInput(
        endpoint,
        tree.serverId,
        session,
        instance,
      );
      try {
        await input.ready.timeout(const Duration(seconds: 8));

        // Edit a shell command through native semantic keys, then submit it.
        // IME-committed Unicode remains text, not a duplicate key transition.
        await input.sendText('echo HOWL_KEYBOARD_X');
        await input.sendNamedKey(
          TerminalNamedKey.backspace,
          TerminalKeyAction.press,
        );
        await input.sendNamedKey(
          TerminalNamedKey.backspace,
          TerminalKeyAction.release,
        );
        await input.sendUnicodeKey(0x59, TerminalKeyAction.press);
        await input.sendUnicodeKey(0x59, TerminalKeyAction.release);
        await input.sendNamedKey(
          TerminalNamedKey.enter,
          TerminalKeyAction.press,
        );
        await input.sendNamedKey(
          TerminalNamedKey.enter,
          TerminalKeyAction.release,
        );

        var found = false;
        for (var attempt = 0; attempt < 16 && !found; attempt++) {
          final frame = await observer.next().timeout(
            const Duration(seconds: 8),
          );
          // Match shell output, not the echoed command line.
          found = frame.lines.any((line) => line.trim() == 'HOWL_KEYBOARD_Y');
        }
        if (!found)
          throw StateError(
            'Semantic Backspace/Unicode/Enter did not produce expected shell output',
          );

        await input.sendText('echo CAFÉ_OK\n');
        // Repeat and release must share the same physical key contract.
        await input.sendNamedKey(
          TerminalNamedKey.left,
          TerminalKeyAction.press,
        );
        await input.sendNamedKey(
          TerminalNamedKey.left,
          TerminalKeyAction.repeat,
        );
        await input.sendNamedKey(
          TerminalNamedKey.left,
          TerminalKeyAction.release,
        );
        try {
          await input.sendUnicodeKey(0xd800, TerminalKeyAction.press);
          throw StateError('Invalid Unicode surrogate was accepted');
        } on RangeError {
          // Local validation must leave this attachment available.
        }

        // Ctrl+C is a physical Unicode transition with Control, not text.
        await input.sendText('sleep 30\n');
        await input.sendUnicodeKey(
          0x63,
          TerminalKeyAction.press,
          modifiers: TerminalModifiers.control,
        );
        await input.sendUnicodeKey(
          0x63,
          TerminalKeyAction.release,
          modifiers: TerminalModifiers.control,
        );
        await input.sendText('echo AFTER_CONTROL_C\n');
        var recovered = false;
        for (var attempt = 0; attempt < 16 && !recovered; attempt++) {
          final frame = await observer.next().timeout(
            const Duration(seconds: 8),
          );
          recovered = frame.lines.any(
            (line) => line.trim() == 'AFTER_CONTROL_C',
          );
        }
        if (!recovered)
          throw StateError('Ctrl+C did not release the child for later input');
      } finally {
        await input.close().timeout(const Duration(seconds: 8));
      }
      final blocked = observer.next().then(
        (_) => false,
        onError: (Object _) => true,
      );
      await observer.close().timeout(const Duration(seconds: 8));
      if (!await blocked)
        throw StateError('Blocking observation did not cancel');
    } finally {
      await observer.close();
    }
    stdout.writeln(
      jsonEncode({
        'status': 'pass',
        'operation': 'semantic_keyboard',
        'server_id': '${tree.serverId}',
        'instance_id': '$instance',
      }),
    );
  } finally {
    if (instance != null)
      await client.closeInstance(endpoint, session, instance);
    await client.closeSession(endpoint, session);
  }
}
