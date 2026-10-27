/// Exact semantic key values from howl_server_client.h ABI v1.
/// Text committed by an IME is sent with sendText, never as key transitions.
enum TerminalNamedKey {
  enter(1),
  tab(2),
  backspace(3),
  escape(4),
  up(5),
  down(6),
  left(7),
  right(8),
  insert(9),
  delete(10),
  home(11),
  end(12),
  pageUp(13),
  pageDown(14),
  leftShift(15),
  rightShift(16),
  leftControl(17),
  rightControl(18),
  leftAlt(19),
  rightAlt(20),
  leftSuper(21),
  rightSuper(22),
  leftHyper(23),
  rightHyper(24),
  leftMeta(25),
  rightMeta(26),
  capsLock(27),
  numLock(28),
  f1(29),
  f2(30),
  f3(31),
  f4(32),
  f5(33),
  f6(34),
  f7(35),
  f8(36),
  f9(37),
  f10(38),
  f11(39),
  f12(40),
  keypad0(41),
  keypad1(42),
  keypad2(43),
  keypad3(44),
  keypad4(45),
  keypad5(46),
  keypad6(47),
  keypad7(48),
  keypad8(49),
  keypad9(50),
  keypadDecimal(51),
  keypadAdd(52),
  keypadSubtract(53),
  keypadMultiply(54),
  keypadDivide(55),
  keypadSeparator(56),
  keypadEqual(57),
  keypadEnter(58);

  const TerminalNamedKey(this.code);
  final int code;
}

enum TerminalKeyAction {
  press(1),
  repeat(2),
  release(3);

  const TerminalKeyAction(this.code);
  final int code;
}

abstract final class TerminalModifiers {
  static const shift = 1;
  static const alt = 2;
  static const control = 4;
  static const superKey = 8;
  static const hyper = 16;
  static const meta = 32;
  static const capsLock = 64;
  static const numLock = 128;
  static const supported = 255;
}

void validateTerminalModifiers(int modifiers) {
  if (modifiers < 0 || modifiers & ~TerminalModifiers.supported != 0) {
    throw RangeError.value(modifiers, 'modifiers', 'unknown native modifier');
  }
}

void validateTerminalScalar(int scalar) {
  if (scalar < 0 ||
      scalar > 0x10ffff ||
      (scalar >= 0xd800 && scalar <= 0xdfff)) {
    throw RangeError.value(scalar, 'scalar', 'not a Unicode scalar');
  }
}
