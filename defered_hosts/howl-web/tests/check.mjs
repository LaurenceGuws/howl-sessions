// Independent byte-level assertions against the emitted Wasm boundary.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const bytes = await readFile(process.argv[2]);
const module = await WebAssembly.compile(bytes);
assert.deepEqual(WebAssembly.Module.imports(module), []);
const expected = ['memory', 'hw_input_ptr', 'hw_input_capacity', 'hw_output_ptr', 'hw_output_len',
  'hw_text_ptr', 'hw_text_len', 'hw_text_truncated', 'hw_snapshot_ptr', 'hw_snapshot_len', 'hw_error_ptr', 'hw_error_len', 'hw_phase', 'hw_identity',
  'hw_image_ptr', 'hw_image_len', 'hw_image_id', 'hw_image_generation', 'hw_image_width', 'hw_image_height', 'hw_selection_ptr', 'hw_selection_len',
  'hw_revision', 'hw_terminal_revision', 'hw_rows', 'hw_columns', 'hw_maximum_rows', 'hw_maximum_columns', 'hw_history_offset', 'hw_history_count', 'hw_history_row_base', 'hw_alternate_screen', 'hw_leader_present', 'hw_last_result_code', 'hw_control_ready',
  'hw_interaction_terminal_revision', 'hw_interaction_alternate_scroll', 'hw_interaction_mouse_tracking', 'hw_interaction_mouse_protocol', 'hw_interaction_pointer_mode',
  'hw_reset', 'hw_observe', 'hw_observe_live', 'hw_send_text', 'hw_send_paste', 'hw_request_interaction_state', 'hw_request_text_extract',
  'hw_request_image', 'hw_release_image',
  'hw_send_named_key', 'hw_send_unicode_key', 'hw_send_focus', 'hw_send_mouse', 'hw_send_resize', 'hw_send_resize_owned',
  'hw_feed', 'hw_finish'].sort();
assert.deepEqual(WebAssembly.Module.exports(module).map(x => x.name).sort(), expected);
const w = (await WebAssembly.instantiate(module)).exports;
assert.equal(w.memory.buffer.byteLength, 32 * 1024 * 1024);
assert.throws(() => w.memory.grow(1), RangeError);
assert.equal(w.hw_maximum_rows(), 192);
assert.equal(w.hw_maximum_columns(), 512);
assert.equal(w.hw_text_truncated(), 0);
assert.equal(w.hw_leader_present(), 0);
function feed(bytes) {
  assert.ok(bytes.length <= w.hw_input_capacity());
  new Uint8Array(w.memory.buffer, w.hw_input_ptr(), bytes.length).set(bytes);
  return w.hw_feed(bytes.length);
}
const ready = Buffer.from('53525652020c000000000028000000000000005b000000000000000700000000000000030000000000000002000000000000002a', 'hex');
for (let split = 0; split <= ready.length; split++) {
  assert.equal(w.hw_reset(), 1);
  assert.equal(w.hw_output_len(), 0);
  assert.equal(feed(ready.subarray(0, split)), 1);
  assert.equal(feed(ready.subarray(split)), 1);
  assert.equal(w.hw_phase(), 2);
  assert.equal(w.hw_identity(), 42n);
  assert.equal(w.hw_finish(), 1);
}
w.hw_reset();
for (const byte of ready) assert.equal(feed(Uint8Array.of(byte)), 1);
assert.equal(w.hw_identity(), 42n);
assert.equal(feed(ready), 0); // unsolicited duplicate
assert.equal(w.hw_phase(), 99);
assert.equal(w.hw_reset(), 1);
assert.equal(w.hw_finish(), 0); // waiting for ready is not a clean EOF
w.hw_reset();
assert.equal(feed(ready.subarray(0, 19)), 1);
assert.equal(w.hw_finish(), 0);
for (const [offset, value] of [[0, 0], [4, 1], [6, 1]]) {
  w.hw_reset(); const bad = Buffer.from(ready); bad[offset] = value;
  assert.equal(feed(bad), 0);
  assert.equal(w.hw_phase(), 99);
}
for (let field = 0; field < 5; field++) {
  w.hw_reset();
  const bad = Buffer.from(ready);
  bad.fill(0, 12 + field * 8, 20 + field * 8);
  assert.equal(feed(bad), 0);
  assert.equal(w.hw_phase(), 99);
}
w.hw_reset();
const oversized = Buffer.from(ready.subarray(0, 12));
oversized.writeUInt32BE(1024 * 1024 + 1, 8);
assert.equal(feed(oversized), 0);
w.hw_reset();
assert.equal(w.hw_feed(w.hw_input_capacity() + 1), 0);
feed(ready);
assert.equal(w.hw_control_ready(), 1);
assert.equal(w.hw_send_text(4097), 0);
new Uint8Array(w.memory.buffer, w.hw_input_ptr(), 1).set([255]);
assert.equal(w.hw_send_text(1), 0);

const output = () => Buffer.from(w.memory.buffer, w.hw_output_ptr(), w.hw_output_len());
function frame(kind, payload) {
  const result = Buffer.alloc(12 + payload.length);
  result.write('SRVR', 0, 'ascii'); result[4] = 2; result[5] = kind;
  result.writeUInt32BE(payload.length, 8); Buffer.from(payload).copy(result, 12);
  return result;
}
function splitFrames(bytes) {
  const frames = [];
  for (let offset = 0; offset < bytes.length;) {
    assert.ok(bytes.length - offset >= 12);
    const payloadLength = bytes.readUInt32BE(offset + 8);
    const length = 12 + payloadLength;
    assert.ok(length <= bytes.length - offset);
    frames.push(Buffer.from(bytes.subarray(offset, offset + length)));
    offset += length;
  }
  return frames;
}
const result = (requestKind, code) => frame(40, [requestKind, code]);
const ok = requestKind => result(requestKind, 0);
const inputBytes = value => {
  const encoded = new TextEncoder().encode(value);
  new Uint8Array(w.memory.buffer, w.hw_input_ptr(), encoded.length).set(encoded);
  return encoded;
};

inputBytes('é');
assert.equal(w.hw_send_text(2), 1);
assert.equal(output()[5], 36); assert.deepEqual([...output().subarray(12)], [1, 0xc3, 0xa9]);
assert.equal(w.hw_control_ready(), 0); assert.equal(feed(ok(36)), 1); assert.equal(w.hw_phase(), 6);

inputBytes('paste');
assert.equal(w.hw_send_paste(5), 1);
assert.deepEqual([...output().subarray(12)], [2, 112, 97, 115, 116, 101]);
assert.equal(feed(ok(36)), 1);

assert.equal(w.hw_send_named_key(5, 1, 5), 1); // Up + shift/control.
let payload = output().subarray(12);
assert.equal(payload[0], 3); assert.equal(payload[1], 1); assert.equal(payload[2], 1); assert.equal(payload[3], 5);
assert.equal(payload.readUInt32BE(5), 5); assert.equal(feed(ok(36)), 1);
assert.equal(w.hw_send_named_key(0, 1, 0), 0); assert.equal(w.hw_send_named_key(59, 1, 0), 0);

assert.equal(w.hw_send_unicode_key(0x03bb, 1, 4), 1);
payload = output().subarray(12);
assert.equal(payload[0], 3); assert.equal(payload[1], 2); assert.equal(payload[2], 1); assert.equal(payload[3], 4);
assert.equal(payload.readUInt32BE(5), 0x03bb); assert.equal(feed(ok(36)), 1);
assert.equal(w.hw_send_unicode_key(0xd800, 1, 0), 0);

assert.equal(w.hw_send_focus(1), 1);
assert.deepEqual([...output().subarray(12)], [5, 1]); assert.equal(feed(ok(36)), 1);
assert.equal(w.hw_send_focus(3), 0);

assert.equal(w.hw_send_mouse(3, 0, 2, 4, 7, 9, 1, 95, 123), 1);
payload = output().subarray(12);
assert.equal(payload[0], 4);
assert.deepEqual([...payload.subarray(1, 5)], [3, 0, 2, 4]);
assert.equal(payload.readInt32BE(5), 7);
assert.equal(payload.readUInt16BE(9), 9);
assert.equal(payload[11], 1);
assert.equal(payload.readUInt32BE(12), 95);
assert.equal(payload.readUInt32BE(16), 123);
assert.equal(feed(ok(36)), 1);
assert.equal(w.hw_send_mouse(0, 0, 0, 0, 0, 0, 0, 0, 0), 0);
assert.equal(w.hw_send_mouse(1, 1, 0, 8, 0, 0, 0, 0, 0), 0);
assert.equal(w.hw_send_mouse(1, 1, 0, 1, 0, 0, 0, 1, 0), 0);

assert.equal(w.hw_request_interaction_state(), 1);
assert.equal(output()[5], 41);
assert.equal(output().length, 12);
const interactionVector = Buffer.from('53525652022a000000000014010203040506070800001ffd0403ff7f12340300', 'hex');
assert.equal(feed(interactionVector), 1);
assert.equal(w.hw_phase(), 6);
assert.equal(w.hw_control_ready(), 1);
assert.equal(w.hw_interaction_terminal_revision(), 0x0102030405060708n);
assert.equal(w.hw_interaction_alternate_scroll(), 1);
assert.equal(w.hw_interaction_mouse_tracking(), 4);
assert.equal(w.hw_interaction_mouse_protocol(), 3);
assert.equal(w.hw_interaction_pointer_mode(), 3);

assert.equal(w.hw_request_text_extract(-3, 4, 7, 8, 80, 0), 1);
assert.equal(output()[5], 50);
payload = output().subarray(12);
assert.equal(payload.readInt32BE(0), -3); assert.equal(payload.readUInt16BE(4), 4);
assert.equal(payload.readInt32BE(6), 7); assert.equal(payload.readUInt16BE(10), 8);
assert.equal(payload.readUInt16BE(12), 80); assert.equal(payload[14], 0); assert.equal(payload[15], 0);
const selectedText = Buffer.from('alpha λ', 'utf8');
assert.equal(feed(frame(51, selectedText)), 1); assert.equal(w.hw_phase(), 6);
assert.equal(w.hw_last_result_code(), 0); assert.equal(w.hw_selection_len(), selectedText.length);
assert.deepEqual(Buffer.from(w.memory.buffer, w.hw_selection_ptr(), w.hw_selection_len()), selectedText);
assert.equal(w.hw_request_text_extract(1, 2, 3, 4, 80, 1), 1);
assert.equal(feed(result(50, 5)), 1); assert.equal(w.hw_phase(), 6);
assert.equal(w.hw_last_result_code(), 5); assert.equal(w.hw_selection_len(), 0);
assert.equal(w.hw_request_text_extract(0, 0x10000, 0, 0, 80, 0), 0);
assert.equal(w.hw_request_text_extract(0, 0, 0, 0, 0, 0), 0);
assert.equal(w.hw_request_text_extract(0, 0, 0, 0, 80, 2), 0);

assert.equal(w.hw_send_resize(20, 80), 1);
assert.equal(output()[5], 37); assert.equal(output().subarray(12).readBigUInt64BE(), 42n);
assert.equal(w.hw_control_ready(), 0);
assert.equal(feed(ok(37)), 2); // Follow-up resize frame is now ready.
assert.equal(output()[5], 38); payload = output().subarray(12);
assert.equal(payload.readUInt16BE(0), 20); assert.equal(payload.readUInt16BE(2), 80);
assert.equal(feed(ok(38)), 1); assert.equal(w.hw_phase(), 6); assert.equal(w.hw_control_ready(), 1);
assert.equal(w.hw_last_result_code(), 0);
assert.equal(w.hw_send_resize_owned(21, 81), 1);
assert.equal(output()[5], 38); payload = output().subarray(12);
assert.equal(payload.readUInt16BE(0), 21); assert.equal(payload.readUInt16BE(2), 81);
assert.equal(feed(result(38, 4)), 1); assert.equal(w.hw_phase(), 6);
assert.equal(w.hw_last_result_code(), 4); assert.equal(w.hw_control_ready(), 1);
assert.equal(w.hw_send_resize(0, 80), 0);

assert.equal(w.hw_release_image(), 0);
assert.equal(w.hw_request_image(7, 9n), 1);
assert.equal(output()[5], 53);
payload = output().subarray(12);
assert.equal(payload.readUInt32BE(0), 7);
assert.equal(payload.readBigUInt64BE(4), 9n);
const imageBegin = Buffer.alloc(24);
imageBegin.writeUInt32BE(7, 0);
imageBegin.writeBigUInt64BE(9n, 4);
imageBegin.writeUInt32BE(2, 12);
imageBegin.writeUInt32BE(2, 16);
imageBegin.writeUInt32BE(16, 20);
assert.equal(feed(frame(54, imageBegin)), 1);
assert.equal(w.hw_phase(), 7);
assert.equal(feed(frame(55, Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]))), 1);
assert.equal(feed(frame(55, Buffer.from([9, 10, 11, 12, 13, 14, 15, 16]))), 1);
const imageEnd = Buffer.alloc(12);
imageEnd.writeUInt32BE(7, 0);
imageEnd.writeBigUInt64BE(9n, 4);
assert.equal(feed(frame(56, imageEnd)), 1);
assert.equal(w.hw_phase(), 8);
assert.equal(w.hw_image_id(), 7);
assert.equal(w.hw_image_generation(), 9n);
assert.equal(w.hw_image_width(), 2);
assert.equal(w.hw_image_height(), 2);
assert.equal(w.hw_image_len(), 16);
assert.deepEqual(
  [...new Uint8Array(w.memory.buffer, w.hw_image_ptr(), w.hw_image_len())],
  [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
);
assert.equal(w.hw_release_image(), 1);
assert.equal(w.hw_phase(), 2);

// Exact image transport fails closed on stale identity, incomplete bodies, and
// byte-count overflow without exposing a partial resource.
assert.equal(w.hw_request_image(7, 9n), 1);
const staleImageBegin = Buffer.from(imageBegin);
staleImageBegin.writeBigUInt64BE(10n, 4);
assert.equal(feed(frame(54, staleImageBegin)), 0);
assert.equal(w.hw_phase(), 99);

assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_request_image(7, 9n), 1);
assert.equal(feed(frame(54, imageBegin)), 1);
assert.equal(feed(frame(55, Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]))), 1);
assert.equal(feed(frame(56, imageEnd)), 0);
assert.equal(w.hw_phase(), 99);

assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_request_image(7, 9n), 1);
assert.equal(feed(frame(54, imageBegin)), 1);
assert.equal(feed(frame(55, Buffer.alloc(17, 0xa5))), 0);
assert.equal(w.hw_phase(), 99);

assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_request_image(7, 9n), 1);
assert.equal(feed(frame(54, imageBegin)), 1);
assert.equal(feed(frame(55, Buffer.from([1, 2, 3, 4]))), 1);
assert.equal(w.hw_finish(), 0);
assert.equal(w.hw_phase(), 99);

assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_observe(1, 37), 1);
payload = output().subarray(12); assert.equal(output()[5], 32);
assert.equal(payload.readBigUInt64BE(0), 0n); assert.equal(payload.readUInt32BE(8), 37);
assert.equal(w.hw_observe(1, 0), 0); // at most one outstanding operation
assert.equal(w.hw_send_text(1), 0);
const vectorCorpus = JSON.parse(await readFile(process.argv[3], 'utf8'));
const completeVector = vectorCorpus.cases.find(test => test.id === 'snapshot_text_v1_complete');
assert.ok(completeVector?.hex);
const completeSnapshot = Buffer.from(completeVector.hex, 'hex');
const completeFrames = splitFrames(completeSnapshot);
assert.deepEqual(completeFrames.map(value => value[5]), [33, 34, 52, 61, 35]);

assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_observe_live(1), 1);
payload = output().subarray(12); assert.equal(output()[5], 32);
assert.equal(payload.readBigUInt64BE(0), 0n); assert.equal(payload.readUInt32BE(8), 0);
assert.equal(feed(completeSnapshot), 1);
assert.equal(w.hw_phase(), 4);
assert.equal(w.hw_revision(), 10n); assert.equal(w.hw_terminal_revision(), 23n);
assert.equal(w.hw_rows(), 1); assert.equal(w.hw_columns(), 3);
assert.equal(w.hw_history_offset(), 0); assert.equal(w.hw_history_count(), 7); assert.equal(w.hw_history_row_base(), 4);
assert.equal(w.hw_text_len(), 0); // Live wire framing performs no semantic row projection.
assert.equal(w.hw_observe_live(0), 1);
payload = output().subarray(12); assert.equal(output()[5], 32);
assert.equal(payload.readBigUInt64BE(0), 10n); assert.equal(payload.readUInt32BE(8), 0);

assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_observe(1, 0), 1);
assert.equal(feed(completeSnapshot), 1);
assert.equal(w.hw_phase(), 4);
assert.ok(w.hw_text_len() > 0); // History/semantic wire path remains intact.
assert.equal(new TextDecoder().decode(new Uint8Array(w.memory.buffer, w.hw_text_ptr(), w.hw_text_len())), 'é中');

assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_observe_live(1), 1);
const mismatchedEnd = Buffer.from(completeSnapshot);
mismatchedEnd[mismatchedEnd.length - 1] = 11;
assert.equal(feed(mismatchedEnd), 0);
assert.equal(w.hw_phase(), 99);

function rejectLiveEnvelope(frames) {
  assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
  assert.equal(w.hw_observe_live(1), 1);
  assert.equal(feed(Buffer.concat(frames)), 0);
  assert.equal(w.hw_phase(), 99);
}
rejectLiveEnvelope([completeFrames[0], ...completeFrames.slice(2)]); // missing body
rejectLiveEnvelope([completeFrames[0], completeFrames[1], ...completeFrames.slice(3)]); // missing graphics
rejectLiveEnvelope([completeFrames[0], completeFrames[1], completeFrames[2], completeFrames[4]]); // missing properties
const rawBody = Buffer.from(completeFrames[1]); rawBody[5] = 58;
rejectLiveEnvelope([completeFrames[0], completeFrames[1], rawBody, ...completeFrames.slice(2)]); // mixed body encoding
rejectLiveEnvelope([completeFrames[0], completeFrames[1], completeFrames[2], completeFrames[1], ...completeFrames.slice(3)]); // body after graphics

const graphicsVector = vectorCorpus.cases.find(test => test.id === 'snapshot_graphics_manifest');
assert.ok(graphicsVector?.hex);
const graphicsSnapshot = Buffer.from(graphicsVector.hex, 'hex');
assert.equal(w.hw_reset(), 1); assert.equal(feed(ready), 1);
assert.equal(w.hw_observe(1, 37), 1);
for (const byte of graphicsSnapshot) assert.equal(feed(Uint8Array.of(byte)), 1);
assert.equal(w.hw_phase(), 4);
assert.equal(w.hw_snapshot_len(), graphicsSnapshot.length);
assert.equal(w.hw_rows(), 1);
assert.equal(w.hw_columns(), 1);
console.log(JSON.stringify({status:'pass', wasmBytes:bytes.length, memoryBytes:w.memory.buffer.byteLength,
  imports:0, readySplits:ready.length + 1, byteDelivery:true, rejectedInvalidFrames:true, semanticControls:true, semanticMouse:true, textExtract:true, resizeFollowup:true,
  imageFetch:true, graphicsSnapshot:true}));
