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
  static const maxCodeUnits = 4096;
  static const _canonical = TextEditingValue(
    text: '$left$right',
    selection: TextSelection.collapsed(offset: 1),
  );

  TextEditingValue _value = _canonical;
  String? _compositionPrefix;
  String? _compositionSuffix;
  TextEditingValue get value => _value;
  String get preedit =>
      _value.composing.isValid && !_value.composing.isCollapsed
      ? _value.composing.textInside(_value.text)
      : '';

  void reset() {
    _value = _canonical;
    _compositionPrefix = null;
    _compositionSuffix = null;
  }

  /// Engine updates are asynchronous. A delta carries its actual insertion;
  /// its oldText may still include text committed before our reset arrived.
  /// Never resend that prefix as if it were new terminal input.
  ({String? text, TerminalNamedKey? key})? updateDelta(TextEditingDelta delta) {
    if (delta.oldText.length > maxCodeUnits) {
      throw const FormatException('Terminal IME context exceeded its bound');
    }
    final next = delta.apply(_value);
    if (next.text.length > maxCodeUnits ||
        !next.selection.isValid ||
        next.selection.end > next.text.length ||
        (next.composing.isValid && next.composing.end > next.text.length)) {
      throw const FormatException('Invalid or oversized terminal IME edit');
    }
    if (next.composing.isValid && !next.composing.isCollapsed) {
      _compositionPrefix ??= next.composing.textBefore(next.text);
      _compositionSuffix ??= next.composing.textAfter(next.text);
      _value = next;
      return null;
    }
    final prefix = _compositionPrefix;
    final suffix = _compositionSuffix;
    reset();
    if (prefix != null && suffix != null) {
      if (!next.text.startsWith(prefix) ||
          !next.text.endsWith(suffix) ||
          next.text.length < prefix.length + suffix.length) {
        throw const FormatException('IME changed text outside its composition');
      }
      final committed = next.text.substring(
        prefix.length,
        next.text.length - suffix.length,
      );
      return _commit(committed);
    }
    if (delta is TextEditingDeltaInsertion) {
      return _commit(delta.textInserted);
    }
    if (delta is TextEditingDeltaNonTextUpdate) return null;
    if (delta is TextEditingDeltaDeletion) {
      // Surrounding-text deletion of a guard represents one terminal key.
      // A queued deletion of ordinary committed text also deletes one key.
      final deleted = delta.textDeleted;
      if (deleted == right) return (text: null, key: TerminalNamedKey.delete);
      if (deleted == left ||
          (deleted.runes.length == 1 &&
              delta.oldText.endsWith(right) &&
              delta.deletedRange.end == delta.oldText.length - 1)) {
        return (text: null, key: TerminalNamedKey.backspace);
      }
      throw const FormatException(
        'Unsupported multi-character terminal IME deletion',
      );
    }
    if (delta is TextEditingDeltaReplacement &&
        (delta.textReplaced.isEmpty || delta.textReplaced == '$left$right')) {
      return _commit(delta.replacementText);
    }
    // Autocorrection/selection replacement of already transmitted text cannot
    // be faithfully replayed against an arbitrary terminal program.
    throw const FormatException(
      'IME replacement requires reconnecting terminal input',
    );
  }

  ({String? text, TerminalNamedKey? key})? _commit(String text) {
    if (text.contains(left) || text.contains(right)) {
      throw const FormatException('IME edit contains reserved terminal guards');
    }
    return text.isEmpty ? null : (text: text, key: null);
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
