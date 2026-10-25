import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:howl_sessions/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Sessions owns its add action; Servers live under Settings', (
    tester,
  ) async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    await tester.pumpWidget(const HowlSessionsApp());
    await tester.pumpAndSettle();
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.byTooltip('New session'), findsOneWidget);
    expect(
      tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('New session'),
          matching: find.byType(IconButton),
        ),
      ).onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Add server'), findsOneWidget);
    expect(find.byTooltip('New session'), findsNothing);
  });
}
