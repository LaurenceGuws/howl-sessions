// Browser platform input vocabulary. Values are frozen Howl semantic identities,
// never terminal escape strings.
export const KeyAction = Object.freeze({press: 1, repeat: 2, release: 3});
export const Modifier = Object.freeze({shift:1, alt:2, control:4, super:8, capsLock:64, numLock:128});
export const MouseKind = Object.freeze({press:1, release:2, move:3, wheel:4});
export const MouseButton = Object.freeze({none:0, left:1, middle:2, right:3, wheelUp:4, wheelDown:5});
export const NamedKey = Object.freeze({
  Enter:1, Tab:2, Backspace:3, Escape:4, ArrowUp:5, ArrowDown:6,
  ArrowLeft:7, ArrowRight:8, Insert:9, Delete:10, Home:11, End:12,
  PageUp:13, PageDown:14, ShiftLeft:15, ShiftRight:16, ControlLeft:17,
  ControlRight:18, AltLeft:19, AltRight:20, MetaLeft:21, MetaRight:22,
  CapsLock:27, NumLock:28, F1:29, F2:30, F3:31, F4:32, F5:33, F6:34,
  F7:35, F8:36, F9:37, F10:38, F11:39, F12:40, Numpad0:41,
  Numpad1:42, Numpad2:43, Numpad3:44, Numpad4:45, Numpad5:46,
  Numpad6:47, Numpad7:48, Numpad8:49, Numpad9:50, NumpadDecimal:51,
  NumpadAdd:52, NumpadSubtract:53, NumpadMultiply:54, NumpadDivide:55,
  NumpadComma:56, NumpadEqual:57, NumpadEnter:58,
});

export const leftGuard = '\uE000';
export const rightGuard = '\uE001';
export const guardText = `${leftGuard}${rightGuard}`;

export function modifierBits(event) {
  let result = 0;
  if (event.shiftKey) result |= Modifier.shift;
  if (event.altKey) result |= Modifier.alt;
  if (event.ctrlKey) result |= Modifier.control;
  if (event.metaKey) result |= Modifier.super;
  if (typeof event.getModifierState === 'function' && event.getModifierState('CapsLock')) result |= Modifier.capsLock;
  if (typeof event.getModifierState === 'function' && event.getModifierState('NumLock')) result |= Modifier.numLock;
  return result;
}

export function namedKeyForCode(code) { return NamedKey[code] ?? null; }

export function singleScalar(value) {
  const scalars = [...value];
  return scalars.length === 1 ? scalars[0].codePointAt(0) : null;
}

// The hidden editor is the sole DOM keyboard/IME focus owner. Canvas pointer
// interactions may change terminal-local selection state, but must not strand
// browser keyboard focus on the canvas itself.
export function focusKeyboardCapture(target, {composing=false} = {}) {
  target.focus({preventScroll:true});
  return !composing;
}

export function committedActions(text) {
  if (!text) return [];
  const actions = [];
  let segment = '';
  for (let index = 0; index < text.length;) {
    const code = text.charCodeAt(index);
    if (code !== 0x0a && code !== 0x0d) {
      segment += text[index]; index += 1; continue;
    }
    if (segment) { actions.push({kind:'text', text:segment}); segment = ''; }
    actions.push({kind:'key', key:NamedKey.Enter});
    if (code === 0x0d && index + 1 < text.length && text.charCodeAt(index + 1) === 0x0a) index += 2;
    else index += 1;
  }
  if (segment) actions.push({kind:'text', text:segment});
  return actions;
}

// Same terminal-editing model accepted by Flutter: two private-use guards keep
// Backspace/Delete observable while the editor is not a retained document.
export class TerminalInputStager {
  constructor() { this.value = guardText; }
  reset() { this.value = guardText; }
  update(text, {composing=false} = {}) {
    this.value = text;
    if (composing) return [];
    let actions = [];
    if (text === rightGuard) actions = [{kind:'key', key:NamedKey.Backspace}];
    else if (text === leftGuard) actions = [{kind:'key', key:NamedKey.Delete}];
    else if (text.startsWith(leftGuard) && text.endsWith(rightGuard)) {
      const committed = text.slice(leftGuard.length, text.length - rightGuard.length);
      if (!committed.includes(leftGuard) && !committed.includes(rightGuard)) actions = committedActions(committed);
    } else if (!text.includes(leftGuard) && !text.includes(rightGuard)) {
      // Some IMEs replace the whole editable. Empty replacement is ambiguous.
      actions = committedActions(text);
    }
    this.reset();
    return actions;
  }
}
