import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howl_sessions/sessions/session_workspace.dart';

void main() {
  testWidgets('Phone opens full terminal and Back returns to catalog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = false;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SessionWorkspace(
                catalog: const Text('Catalog'),
                terminal: const SizedBox.expand(key: Key('terminal')),
                hasSelection: selected,
                onBack: () => setState(() => selected = false),
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('Catalog'), findsOneWidget);
    expect(find.byKey(const Key('terminal')), findsNothing);
    update(() => selected = true);
    await tester.pumpAndSettle();
    expect(find.text('Catalog'), findsNothing);
    expect(
      tester.getSize(find.byKey(const Key('terminal'))).height,
      greaterThan(700),
    );
    await tester.tap(find.text('Sessions'));
    await tester.pumpAndSettle();
    expect(find.text('Catalog'), findsOneWidget);
    expect(find.byKey(const Key('terminal')), findsNothing);
    update(() => selected = true);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Catalog'), findsOneWidget);
  });

  testWidgets('Wide window keeps catalog and terminal side by side', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionWorkspace(
            catalog: const SizedBox.expand(key: Key('catalog')),
            terminal: const SizedBox.expand(key: Key('terminal')),
            hasSelection: true,
            onBack: () => fail('Wide viewport must not detach'),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('catalog'))).width, 300);
    expect(tester.getTopLeft(find.byKey(const Key('terminal'))).dx, 301);
    expect(find.text('Sessions'), findsNothing);
  });
}
