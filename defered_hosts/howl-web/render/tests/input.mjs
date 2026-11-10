import assert from 'node:assert/strict';
import {
  TerminalInputStager, guardText, leftGuard, rightGuard, committedActions,
  namedKeyForCode, NamedKey, modifierBits, singleScalar, focusKeyboardCapture,
} from '../web/input.mjs';

const stager = new TerminalInputStager();
assert.deepEqual(stager.update(`${leftGuard}e${rightGuard}`, {composing:true}), []);
assert.equal(stager.value, `${leftGuard}e${rightGuard}`);
assert.deepEqual(stager.update(`${leftGuard}é${rightGuard}`), [{kind:'text',text:'é'}]);
assert.equal(stager.value, guardText);
assert.deepEqual(stager.update(`${leftGuard}e\u0301 中 🐺${rightGuard}`), [{kind:'text',text:'e\u0301 中 🐺'}]);
assert.deepEqual(stager.update(rightGuard), [{kind:'key',key:NamedKey.Backspace}]);
assert.deepEqual(stager.update(leftGuard), [{kind:'key',key:NamedKey.Delete}]);
assert.deepEqual(committedActions('a\r\nb\n\rz'), [
  {kind:'text',text:'a'}, {kind:'key',key:NamedKey.Enter}, {kind:'text',text:'b'},
  {kind:'key',key:NamedKey.Enter}, {kind:'key',key:NamedKey.Enter}, {kind:'text',text:'z'},
]);
assert.deepEqual(stager.update(''), []); assert.equal(stager.value, guardText);
assert.equal(namedKeyForCode('ArrowLeft'), NamedKey.ArrowLeft);
assert.equal(namedKeyForCode('KeyA'), null);
assert.equal(modifierBits({shiftKey:true,altKey:false,ctrlKey:true,metaKey:false,getModifierState:k=>k==='CapsLock'}), 1|4|64);
assert.equal(singleScalar('λ'), 0x03bb); assert.equal(singleScalar('🐺'), 0x1f43a); assert.equal(singleScalar('ab'), null);
const focusCalls = [];
const focusTarget = {focus:options => focusCalls.push(options)};
assert.equal(focusKeyboardCapture(focusTarget), true);
assert.equal(focusKeyboardCapture(focusTarget, {composing:true}), false);
assert.deepEqual(focusCalls, [{preventScroll:true}, {preventScroll:true}]);
console.log(JSON.stringify({status:'pass', guards:true, composition:true, editKeys:true, newlines:true, unicode:true, physicalNames:true, keyboardFocusOwner:true}));
