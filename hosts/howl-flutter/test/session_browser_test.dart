import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howl_server_client/howl_server_client.dart';
import 'package:howl_sessions/servers/configured_server.dart';
import 'package:howl_sessions/instances/instance_view.dart';
import 'package:howl_sessions/sessions/session_browser.dart';
import 'package:howl_sessions/sessions/session_catalog.dart';

SessionTree catalog({
  int server = 91,
  int capacity = 8,
  List<SessionEntry> sessions = const [],
}) => SessionTree(
  serverId: BigInt.from(server),
  revision: BigInt.one,
  sessionCapacity: capacity,
  instancesPerSession: 4,
  sessions: sessions,
);

final class Management implements ServerManagement {
  SessionTree tree = catalog();
  Completer<SessionTree>? reading;
  Completer<BigInt>? creating;
  int reads = 0;
  int creates = 0;
  int closes = 0;
  BigInt? expectedServer;
  String? createdName;

  @override
  Future<SessionTree> readTree(String endpoint) async {
    reads++;
    return reading?.future ?? tree;
  }

  @override
  Future<BigInt> createSession(
    String endpoint,
    String name, {
    required BigInt serverId,
  }) async {
    creates++;
    expectedServer = serverId;
    createdName = name;
    return creating?.future ?? BigInt.one;
  }

  @override
  Future<void> closeSession(
    String endpoint,
    BigInt sessionId, {
    required BigInt serverId,
  }) async {
    closes++;
  }

  @override
  Future<BigInt> createInstance(
    String endpoint,
    InstanceLaunch launch, {
    required BigInt serverId,
  }) async => BigInt.one;
  @override
  Future<void> closeInstance(
    String endpoint,
    BigInt sessionId,
    BigInt instanceId, {
    required BigInt serverId,
  }) async {}
}

Widget app(Management client, {String? endpoint = 'tcp://127.0.0.1:43157'}) =>
    MaterialApp(
      home: Scaffold(
        body: SessionBrowser(
          client: client,
          servers: const [
            ConfiguredServer(name: 'Test', endpoint: 'tcp://127.0.0.1:43157'),
            ConfiguredServer(name: 'Other', endpoint: 'tcp://127.0.0.1:43158'),
          ],
          selectedEndpoint: endpoint,
          onSelectServer: (_) {},
          onOpenSettings: () {},
        ),
      ),
    );

IconButton button(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == tooltip),
    );

void main() {
  testWidgets(
    'Creation requires an observed catalog and respects its capacity',
    (tester) async {
      final client = Management()..reading = Completer<SessionTree>();
      await tester.pumpWidget(app(client));
      expect(button(tester, 'New session').onPressed, isNull);
      client.reading!.complete(catalog(capacity: 0));
      await tester.pumpAndSettle();
      expect(button(tester, 'New session').onPressed, isNull);
      expect(client.creates, 0);
    },
  );

  testWidgets('One dialog and one mutation remain fenced through completion', (
    tester,
  ) async {
    final client = Management()..creating = Completer<BigInt>();
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    final open = button(tester, 'New session').onPressed!;
    open();
    open();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'my_session');
    await tester.pump();
    final create = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
        .onPressed!;
    create();
    create();
    await tester.pumpAndSettle();
    expect(client.creates, 1);
    expect(client.expectedServer, BigInt.from(91));
    expect(client.createdName, 'my_session');
    expect(button(tester, 'New session').onPressed, isNull);
    expect(button(tester, 'Refresh sessions').onPressed, isNull);
    client.creating!.complete(BigInt.one);
    await tester.pumpAndSettle();
    expect(button(tester, 'New session').onPressed, isNotNull);
    expect(client.reads, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Repeated cancel and reopen disposes route-owned editing safely',
    (tester) async {
      final client = Management();
      await tester.pumpWidget(app(client));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byTooltip('New session'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'cancel_me');
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(client.creates, 0);
    },
  );

  testWidgets('A server switch during the dialog never sends the old action', (
    tester,
  ) async {
    final client = Management();
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New session'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'do_not_create');
    await tester.pumpWidget(app(client, endpoint: 'tcp://127.0.0.1:43158'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(client.creates, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Uncertain mutation is displayed, refresh never replays it', (
    tester,
  ) async {
    final client = Management()..creating = Completer<BigInt>();
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New session'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'uncertain');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    client.creating!.completeError(
      const ServerClientFailure('server incarnation', 9),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('status 9'), findsOneWidget);
    await tester.tap(find.text('Refresh catalog'));
    await tester.pumpAndSettle();
    expect(client.creates, 1);
    expect(client.reads, 2);
  });

  testWidgets('Late read cannot restore a removed server selection', (
    tester,
  ) async {
    final client = Management()..reading = Completer<SessionTree>();
    await tester.pumpWidget(app(client));
    await tester.pumpWidget(app(client, endpoint: null));
    client.reading!.complete(catalog());
    await tester.pumpAndSettle();
    final view = tester.widget<SessionCatalog>(find.byType(SessionCatalog));
    expect(view.tree, isNull);
    expect(view.loading, isFalse);
    expect(button(tester, 'New session').onPressed, isNull);
  });
  testWidgets('A restarted server cannot inherit an old numeric selection', (
    tester,
  ) async {
    final session = SessionEntry(
      id: BigInt.one,
      name: 'selected',
      instances: const [],
    );
    final client = Management()..tree = catalog(sessions: [session]);
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New session'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'selected');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<InstanceView>(find.byType(InstanceView)).session?.id,
      BigInt.one,
    );
    client.tree = catalog(server: 92, sessions: [session]);
    await tester.tap(find.byTooltip('Refresh sessions'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<InstanceView>(find.byType(InstanceView)).session,
      isNull,
    );
    expect(
      tester.widget<InstanceView>(find.byType(InstanceView)).instance,
      isNull,
    );
  });

  testWidgets('Close confirmation cannot pop twice or duplicate a mutation', (
    tester,
  ) async {
    final client = Management()
      ..tree = catalog(
        sessions: [
          SessionEntry(id: BigInt.one, name: 'one', instances: const []),
        ],
      );
    await tester.pumpWidget(app(client));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close session'));
    await tester.pumpAndSettle();
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Close'))
        .onPressed!;
    confirm();
    confirm();
    await tester.pumpAndSettle();
    expect(client.closes, 1);
    expect(find.byType(SessionBrowser), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
