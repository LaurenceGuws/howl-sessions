import 'dart:async';

import 'package:flutter/services.dart';

import 'package:howl_server_client/howl_server_client.dart';

/// Owns one software key hold. Stopping cancels its timer synchronously;
/// a release is sent only while the same live attachment can accept it.
final class TerminalSoftwareRepeat {
  TerminalSoftwareRepeat(this.send);

  final void Function(TerminalNamedKey, TerminalKeyAction) send;
  Timer? _timer;
  TerminalNamedKey? _held;

  bool get active => _held != null;

  void start(TerminalNamedKey key) {
    stop();
    _held = key;
    send(key, TerminalKeyAction.press);
    _timer = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (_held == key) send(key, TerminalKeyAction.repeat);
    });
  }

  void stop({bool sendRelease = true}) {
    _timer?.cancel();
    _timer = null;
    final held = _held;
    _held = null;
    if (held != null && sendRelease) send(held, TerminalKeyAction.release);
  }
}

/// IMEs delete surrounding text instead of delivering physical Backspace.
/// One private guard on each side of the cursor makes that action observable.
/// Neither guard ever crosses the terminal boundary.
final class TerminalImeBuffer {
  static const left = '\uE000';
  static const right = '\uE001';
  static const _canonical = TextEditingValue(
    text: '$left$right',
    selection: TextSelection.collapsed(offset: 1),
  );

  TextEditingValue _value = _canonical;
  TextEditingValue get value => _value;

  void reset() => _value = _canonical;

  /// Returns either one committed UTF-8 segment or one native editing key.
  /// During composition, all intermediate updates stay in the IME.
  ({String? text, TerminalNamedKey? key})? update(TextEditingValue next) {
    _value = next;
    if (next.composing.isValid && !next.composing.isCollapsed) return null;
    final text = next.text;
    _value = _canonical;
    if (text == right) return (text: null, key: TerminalNamedKey.backspace);
    if (text == left) return (text: null, key: TerminalNamedKey.delete);
    String? committed;
    if (text.startsWith(left) && text.endsWith(right)) {
      committed = text.substring(1, text.length - 1);
    } else if (!text.contains(left) && !text.contains(right)) {
      // Some IMEs replace the entire editable state on committing a word.
      committed = text;
    }
    if (committed == null || committed.isEmpty) return null;
    return (text: committed, key: null);
  }
}

typedef PhysicalTerminalKey = ({TerminalNamedKey? named, int? scalar});

/// A physical key becomes a terminal transition only when it is not plain
/// printable text; the latter arrives separately as an IME commit.
PhysicalTerminalKey? terminalPhysicalKey(
  LogicalKeyboardKey key,
  int modifiers,
) {
  final named = _named[key];
  if (named != null) return (named: named, scalar: null);
  if (modifiers &
          (TerminalModifiers.control |
              TerminalModifiers.alt |
              TerminalModifiers.superKey |
              TerminalModifiers.meta) ==
      0) {
    return null;
  }
  final label = key.keyLabel;
  if (label.runes.length != 1) return null;
  final scalar = label.runes.single;
  if (scalar < 32 || scalar > 126) return null;
  return (
    named: null,
    scalar: scalar >= 65 && scalar <= 90 ? scalar + 32 : scalar,
  );
}

final _named = <LogicalKeyboardKey, TerminalNamedKey>{
  LogicalKeyboardKey.enter: TerminalNamedKey.enter,
  LogicalKeyboardKey.numpadEnter: TerminalNamedKey.keypadEnter,
  LogicalKeyboardKey.tab: TerminalNamedKey.tab,
  LogicalKeyboardKey.backspace: TerminalNamedKey.backspace,
  LogicalKeyboardKey.escape: TerminalNamedKey.escape,
  LogicalKeyboardKey.arrowUp: TerminalNamedKey.up,
  LogicalKeyboardKey.arrowDown: TerminalNamedKey.down,
  LogicalKeyboardKey.arrowLeft: TerminalNamedKey.left,
  LogicalKeyboardKey.arrowRight: TerminalNamedKey.right,
  LogicalKeyboardKey.insert: TerminalNamedKey.insert,
  LogicalKeyboardKey.delete: TerminalNamedKey.delete,
  LogicalKeyboardKey.home: TerminalNamedKey.home,
  LogicalKeyboardKey.end: TerminalNamedKey.end,
  LogicalKeyboardKey.pageUp: TerminalNamedKey.pageUp,
  LogicalKeyboardKey.pageDown: TerminalNamedKey.pageDown,
  LogicalKeyboardKey.f1: TerminalNamedKey.f1,
  LogicalKeyboardKey.f2: TerminalNamedKey.f2,
  LogicalKeyboardKey.f3: TerminalNamedKey.f3,
  LogicalKeyboardKey.f4: TerminalNamedKey.f4,
  LogicalKeyboardKey.f5: TerminalNamedKey.f5,
  LogicalKeyboardKey.f6: TerminalNamedKey.f6,
  LogicalKeyboardKey.f7: TerminalNamedKey.f7,
  LogicalKeyboardKey.f8: TerminalNamedKey.f8,
  LogicalKeyboardKey.f9: TerminalNamedKey.f9,
  LogicalKeyboardKey.f10: TerminalNamedKey.f10,
  LogicalKeyboardKey.f11: TerminalNamedKey.f11,
  LogicalKeyboardKey.f12: TerminalNamedKey.f12,
};
