import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:howl_sessions/servers/servers_settings.dart';

import 'dart:async';

import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:howl_sessions/servers/configured_server.dart';
import 'package:howl_sessions/servers/server_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('host endpoints persist without Server or Session identity', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final store = ServerStore();
    expect(await store.load(), isEmpty);
    await store.save(const [
      ConfiguredServer(name: 'Home', endpoint: 'tcp://127.0.0.1:43150'),
      ConfiguredServer(name: 'Portable', endpoint: 'tcp://127.0.0.1:43151'),
    ]);
    final saved = await ServerStore().load();
    expect(saved.map((server) => server.name), ['Home', 'Portable']);
    expect(saved[1].endpoint, 'tcp://127.0.0.1:43151');
  });

  test('invalid stored endpoints are rejected, not silently lost', () {
    expect(
      () => ConfiguredServer.fromJson({'name': 'Bad', 'endpoint': ''}),
      throwsFormatException,
    );
  });
  test(
    'Stored strings and list size are bounded before accepting a catalog',
    () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
      final preferences = SharedPreferencesAsync();
      const key = 'howl.sessions.servers.v1';
      final cases = [
        ' ' * 65537,
        jsonEncode(
          List.generate(
            33,
            (i) => {'name': 's$i', 'endpoint': 'tcp:${4000 + i}'},
          ),
        ),
        jsonEncode([
          {'name': 'x', 'endpoint': 'x' * 1025},
        ]),
        jsonEncode([
          {'name': 'x', 'endpoint': 'tcp:43150\n'},
        ]),
        jsonEncode([
          {'name': 'x', 'endpoint': 'tcp:43150'},
          {'name': 'y', 'endpoint': 'tcp:43150'},
        ]),
      ];
      for (final raw in cases) {
        await preferences.setString(key, raw);
        await expectLater(ServerStore().load(), throwsFormatException);
        expect(await preferences.getString(key), raw);
      }
    },
  );

  test('Invalid saves leave existing valid settings unchanged', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    final store = ServerStore();
    const good = ConfiguredServer(name: 'Home', endpoint: 'tcp:43150');
    await store.save([good]);
    await expectLater(store.save([good, good]), throwsFormatException);
    await expectLater(
      store.save([ConfiguredServer(name: 'x', endpoint: 'é' * 513)]),
      throwsFormatException,
    );
    await expectLater(
      store.save([const ConfiguredServer(name: ' Home ', endpoint: 'tcp:1')]),
      throwsFormatException,
    );
    expect((await store.load()).single.name, 'Home');
  });

  test('Bounds count Unicode names and endpoint UTF-8 bytes deliberately', () {
    expect(ConfiguredServer.nameError('😀' * 64), isNull);
    expect(ConfiguredServer.nameError('😀' * 65), isNotNull);
    expect(ConfiguredServer.endpointError('é' * 512), isNull);
    expect(ConfiguredServer.endpointError('é' * 513), isNotNull);
    expect(
      ConfiguredServer.endpointError('unix:/private/path with spaces'),
      isNull,
    );
    expect(ConfiguredServer.endpointError('tcp://host\x00:12'), isNotNull);
  });

  testWidgets(
    'Settings owns one editor and save through asynchronous completion',
    (tester) async {
      final pending = Completer<void>();
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServersSettings(
              servers: const [],
              onChanged: (next) {
                writes++;
                return pending.future;
              },
            ),
          ),
        ),
      );
      final add = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add server'))
          .onPressed!;
      add();
      add();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a server name'), findsOneWidget);
      expect(find.text('Enter an endpoint'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).at(0), 'Home');
      await tester.enterText(find.byType(TextFormField).at(1), 'tcp:43150');
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed!;
      save();
      save();
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Add server'),
            )
            .onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Add server'),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Failed settings save unlocks controls and reports the failure', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServersSettings(
            servers: const [],
            onChanged: (_) async => throw StateError('disk unavailable'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), 'Home');
    await tester.enterText(find.byType(TextFormField).at(1), 'tcp:43150');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('disk unavailable'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add server'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('Global save gate survives leaving and reopening Settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServersSettings(
            saving: true,
            servers: const [
              ConfiguredServer(name: 'Home', endpoint: 'tcp:43150'),
            ],
            onChanged: (_) async => fail('No second save may start'),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add server'))
          .onPressed,
      isNull,
    );
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      expect(button.onPressed, isNull);
    }
    expect(find.text('Saving server settings…'), findsOneWidget);
  });

  testWidgets('Remove confirmation is one decision without double route pop', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServersSettings(
            servers: const [
              ConfiguredServer(name: 'Home', endpoint: 'tcp:43150'),
            ],
            onChanged: (next) async {
              writes++;
              expect(next, isEmpty);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Remove server'));
    await tester.pumpAndSettle();
    final remove = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Remove'))
        .onPressed!;
    remove();
    remove();
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(find.byType(ServersSettings), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Server editor remains scrollable above a short keyboard viewport',
    (tester) async {
      tester.view.physicalSize = const Size(430, 280);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ServersSettings(servers: const [], onChanged: (_) async {}),
          ),
        ),
      );
      await tester.tap(find.text('Add server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.ancestor(
          of: find.byType(Form),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
