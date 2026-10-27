import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howl_server_client/howl_server_client.dart';
import 'package:howl_sessions/instances/terminal_input_events.dart';

void main() {
  test('IME preedit is not emitted as text before commit', () {
    final ime = TerminalImeBuffer();
    expect(ime.value.text, '\uE000\uE001');
    expect(
      ime.update(
        const TextEditingValue(
          text: '\uE000e\uE001',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 1, end: 2),
        ),
      ),
      isNull,
    );
    expect(
      ime.update(
        const TextEditingValue(
          text: '\uE000é\uE001',
          selection: TextSelection.collapsed(offset: 2),
        ),
      ),
      (text: 'é', key: null),
    );
    expect(ime.value.text, '\uE000\uE001');
    expect(
      ime.update(
        const TextEditingValue(
          text: '\uE000x\uE001',
          selection: TextSelection.collapsed(offset: 2),
        ),
      ),
      (text: 'x', key: null),
    );
    expect(ime.update(ime.value), isNull);
  });

  test('software deletion is one semantic key, never guard text', () {
    final ime = TerminalImeBuffer();
    expect(ime.update(const TextEditingValue(text: '\uE001')), (
      text: null,
      key: TerminalNamedKey.backspace,
    ));
    expect(ime.value.text, '\uE000\uE001');
    expect(ime.update(const TextEditingValue(text: '\uE000')), (
      text: null,
      key: TerminalNamedKey.delete,
    ));
    expect(ime.update(TextEditingValue.empty), isNull);
  });

  test('plain keys are IME commits; Ctrl+C is a Unicode key transition', () {
    expect(terminalPhysicalKey(LogicalKeyboardKey.keyC, 0), isNull);
    final chord = terminalPhysicalKey(
      LogicalKeyboardKey.keyC,
      TerminalModifiers.control,
    );
    expect(chord?.named, isNull);
    expect(chord?.scalar, 0x63);
    expect(
      terminalPhysicalKey(LogicalKeyboardKey.arrowLeft, 0)?.named,
      TerminalNamedKey.left,
    );
    expect(
      terminalPhysicalKey(LogicalKeyboardKey.backspace, 0)?.named,
      TerminalNamedKey.backspace,
    );
    expect(
      terminalPhysicalKey(LogicalKeyboardKey.enter, 0)?.named,
      TerminalNamedKey.enter,
    );
  });

  test('ABI key vocabulary and input validation stay exact', () {
    expect(TerminalNamedKey.enter.code, 1);
    expect(TerminalNamedKey.backspace.code, 3);
    expect(TerminalNamedKey.right.code, 8);
    expect(TerminalNamedKey.f12.code, 40);
    expect(TerminalNamedKey.keypadEnter.code, 58);
    expect(TerminalKeyAction.press.code, 1);
    expect(TerminalKeyAction.repeat.code, 2);
    expect(TerminalKeyAction.release.code, 3);
    expect(() => validateTerminalScalar(0xe9), returnsNormally);
    expect(() => validateTerminalScalar(0xd800), throwsRangeError);
    expect(() => validateTerminalScalar(0x110000), throwsRangeError);
    expect(() => validateTerminalModifiers(255), returnsNormally);
    expect(() => validateTerminalModifiers(256), throwsRangeError);
  });

  for (final cause in ['focus loss', 'long-press cancellation', 'disable']) {
    testWidgets('software repeat terminates on $cause', (tester) async {
      final events = <TerminalKeyAction>[];
      final repeat = TerminalSoftwareRepeat((key, action) {
        events.add(action);
      });
      repeat.start(TerminalNamedKey.left);
      await tester.pump(const Duration(milliseconds: 270));
      expect(events.first, TerminalKeyAction.press);
      expect(
        events.where((action) => action == TerminalKeyAction.repeat),
        isNotEmpty,
      );

      // Focus loss and gesture cancellation release the live key. Disabling
      // an attachment destroys its identity; no release is sent to a dead one.
      repeat.stop(sendRelease: cause != 'disable');
      final stoppedCount = events.length;
      expect(repeat.active, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(events.length, stoppedCount);
      expect(
        events.last,
        cause == 'disable'
            ? TerminalKeyAction.repeat
            : TerminalKeyAction.release,
      );
    });
  }

  testWidgets('replacing and disposing a hold leaves no active timer', (
    tester,
  ) async {
    final events = <(TerminalNamedKey, TerminalKeyAction)>[];
    final repeat = TerminalSoftwareRepeat((key, action) {
      events.add((key, action));
    });
    repeat.start(TerminalNamedKey.left);
    repeat.start(TerminalNamedKey.right);
    expect(events, [
      (TerminalNamedKey.left, TerminalKeyAction.press),
      (TerminalNamedKey.left, TerminalKeyAction.release),
      (TerminalNamedKey.right, TerminalKeyAction.press),
    ]);
    repeat.stop(sendRelease: false); // Attachment replacement/dispose.
    await tester.pump(const Duration(seconds: 2));
    expect(events.length, 3);
  });
}
