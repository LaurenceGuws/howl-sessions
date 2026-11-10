import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:howl_server_client/howl_server_client.dart';
import 'package:howl_sessions/instances/terminal_input_events.dart';

void main() {
  TextEditingDeltaInsertion insert(
    String old,
    String text,
    int offset, {
    TextRange composing = TextRange.empty,
  }) => TextEditingDeltaInsertion(
    oldText: old,
    textInserted: text,
    insertionOffset: offset,
    selection: TextSelection.collapsed(offset: offset + text.length),
    composing: composing,
  );

  test('Queued cumulative platform edits emit each insertion exactly once', () {
    final ime = TerminalImeBuffer();
    var remote = '\uE000\uE001';
    final committed = StringBuffer();
    for (final char in 'printf hello'.split('')) {
      final action = ime.updateDelta(insert(remote, char, remote.length - 1));
      committed.write(action?.text);
      remote = '${remote.substring(0, remote.length - 1)}$char\uE001';
      expect(ime.value.text, '\uE000\uE001');
    }
    expect(committed.toString(), 'printf hello');
    // The engine finally observes reset. Repeated characters remain real input.
    expect(ime.updateDelta(insert('\uE000\uE001', 'o', 1))?.text, 'o');
    expect(ime.updateDelta(insert('\uE000o\uE001', 'o', 2))?.text, 'o');
  });

  test('IME preedit is emitted once on composition commit', () {
    final ime = TerminalImeBuffer();
    expect(
      ime.updateDelta(
        insert(
          '\uE000\uE001',
          'e',
          1,
          composing: const TextRange(start: 1, end: 2),
        ),
      ),
      isNull,
    );
    expect(ime.preedit, 'e');
    expect(
      ime.updateDelta(
        const TextEditingDeltaReplacement(
          oldText: '\uE000e\uE001',
          replacementText: 'é',
          replacedRange: TextRange(start: 1, end: 2),
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange.empty,
        ),
      ),
      (text: 'é', key: null),
    );
    expect(ime.preedit, '');
    expect(
      ime.updateDelta(
        const TextEditingDeltaNonTextUpdate(
          oldText: '\uE000é\uE001',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange.empty,
        ),
      ),
      isNull,
    );
  });

  test('Composition preserves an already committed queued prefix', () {
    final ime = TerminalImeBuffer();
    expect(ime.updateDelta(insert('\uE000\uE001', 'a', 1))?.text, 'a');
    expect(
      ime.updateDelta(
        insert(
          '\uE000a\uE001',
          '中',
          2,
          composing: const TextRange(start: 2, end: 3),
        ),
      ),
      isNull,
    );
    expect(
      ime
          .updateDelta(
            const TextEditingDeltaNonTextUpdate(
              oldText: '\uE000a中\uE001',
              selection: TextSelection.collapsed(offset: 3),
              composing: TextRange.empty,
            ),
          )
          ?.text,
      '中',
    );
  });

  test('Cancelled composition sends nothing; reset abandons preedit', () {
    final ime = TerminalImeBuffer();
    ime.updateDelta(
      insert(
        '\uE000\uE001',
        'e',
        1,
        composing: const TextRange(start: 1, end: 2),
      ),
    );
    expect(
      ime.updateDelta(
        const TextEditingDeltaDeletion(
          oldText: '\uE000e\uE001',
          deletedRange: TextRange(start: 1, end: 2),
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange.empty,
        ),
      ),
      isNull,
    );
    ime.updateDelta(
      insert(
        '\uE000\uE001',
        'e',
        1,
        composing: const TextRange(start: 1, end: 2),
      ),
    );
    ime.reset();
    expect(ime.preedit, '');
    expect(ime.updateDelta(insert('\uE000\uE001', 'x', 1))?.text, 'x');
  });

  test('Software deletion uses semantic keys, never guard text', () {
    final ime = TerminalImeBuffer();
    expect(
      ime.updateDelta(
        const TextEditingDeltaDeletion(
          oldText: '\uE000\uE001',
          deletedRange: TextRange(start: 0, end: 1),
          selection: TextSelection.collapsed(offset: 0),
          composing: TextRange.empty,
        ),
      ),
      (text: null, key: TerminalNamedKey.backspace),
    );
    expect(
      ime.updateDelta(
        const TextEditingDeltaDeletion(
          oldText: '\uE000\uE001',
          deletedRange: TextRange(start: 1, end: 2),
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange.empty,
        ),
      ),
      (text: null, key: TerminalNamedKey.delete),
    );
  });

  test('Oversize edits and replacement of committed text fail explicitly', () {
    final ime = TerminalImeBuffer();
    expect(
      () => ime.updateDelta(insert('\uE000\uE001', 'x' * 4096, 1)),
      throwsFormatException,
    );
    expect(
      () => ime.updateDelta(
        const TextEditingDeltaReplacement(
          oldText: '\uE000word\uE001',
          replacementText: 'other',
          replacedRange: TextRange(start: 1, end: 5),
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        ),
      ),
      throwsFormatException,
    );
  });

  test('Unicode commits preserve scalars and reserved guards never leak', () {
    final ime = TerminalImeBuffer();
    expect(ime.updateDelta(insert('\uE000\uE001', 'é中😀', 1))?.text, 'é中😀');
    expect(
      () => ime.updateDelta(insert('\uE000\uE001', '\uE000', 1)),
      throwsFormatException,
    );
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
