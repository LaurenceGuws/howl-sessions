import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {assertTextImports, createTextRuntime} from '../../text/web/runtime.mjs';
import {parseRendererFrameV4, selectRendererFrameV4} from '../web/frame_v4.mjs';

const [wasmPath, primaryPath, fallbackPath, symbolPath, vectorsPath] = process.argv.slice(2);
const binary = await readFile(wasmPath);
const module = await WebAssembly.compile(binary);
assertTextImports(module);
const runtime = createTextRuntime({output:()=>{}});
const instance = await WebAssembly.instantiate(module, runtime.imports);
runtime.bind(instance.exports.memory);
instance.exports._initialize?.();
const w = instance.exports;
const decoder = new TextDecoder();
const bytesAt = (pointer, length) => new Uint8Array(w.memory.buffer, Number(pointer), Number(length));
const errorText = () => decoder.decode(bytesAt(w.rv_error_ptr(), w.rv_error_len()));

for (const [path, pointer, capacity] of [
  [primaryPath, w.rv_font_ptr(), w.rv_font_capacity()],
  [fallbackPath, w.rv_fallback_font_ptr(), w.rv_fallback_font_capacity()],
  [symbolPath, w.rv_symbol_font_ptr(), w.rv_symbol_font_capacity()],
]) {
  const font = await readFile(path);
  assert.ok(font.length > 0 && font.length <= capacity);
  bytesAt(pointer, font.length).set(font);
}
const primary = await readFile(primaryPath);
const fallback = await readFile(fallbackPath);
const symbol = await readFile(symbolPath);
assert.equal(w.rv_init(primary.length, fallback.length, symbol.length, 18), 1, errorText());
selectRendererFrameV4(w);

const corpus = JSON.parse(await readFile(vectorsPath, 'utf8'));
const test = corpus.cases.find(value => value.id === 'snapshot_graphics_manifest');
assert.ok(test?.hex);
const snapshot = Buffer.from(test.hex, 'hex');
let offset = 0;
let graphicsFound = false;
while (offset < snapshot.length) {
  assert.equal(snapshot.toString('ascii', offset, offset + 4), 'SRVR');
  assert.equal(snapshot[offset + 4], 2);
  const kind = snapshot[offset + 5];
  const length = snapshot.readUInt32BE(offset + 8);
  const end = offset + 12 + length;
  assert.ok(end <= snapshot.length);
  if (kind === 52) graphicsFound = true;
  offset = end;
}
assert.equal(offset, snapshot.length);
assert.equal(graphicsFound, true);
assert.ok(snapshot.length <= w.rv_snapshot_capacity());
bytesAt(w.rv_snapshot_ptr(), snapshot.length).set(snapshot);

assert.equal(w.rv_render_count(), 0n);
assert.equal(w.rv_render(snapshot.length), 2, errorText());
assert.equal(w.rv_render_count(), 0n);
assert.equal(w.rv_missing_external(), 1);
assert.ok(w.rv_missing_resource() > 0n);
assert.equal(w.rv_missing_generation(), 9n);
assert.equal(w.rv_missing_format(), 1);
assert.equal(w.rv_missing_width(), 2);
assert.equal(w.rv_missing_height(), 2);
assert.equal(w.rv_missing_stride(), 8);
assert.equal(w.rv_missing_image_id(), 7);
assert.equal(w.rv_missing_image_generation(), 9n);
const externalKey = [
  w.rv_missing_resource(),
  w.rv_missing_generation(),
].map(String);

// Without backend residency the same immutable snapshot remains blocked and no
// render revision or acknowledgement is fabricated.
assert.equal(w.rv_render(snapshot.length), 2, errorText());
assert.equal(w.rv_render_count(), 0n);
assert.equal(w.rv_accept_external(), 1);
assert.equal(w.rv_missing_external(), 0);

assert.equal(w.rv_render(snapshot.length), 1, errorText());
assert.equal(w.rv_render_count(), 1n);
const frame = parseRendererFrameV4(w, decoder.decode(bytesAt(w.rv_frame_ptr(), w.rv_frame_len())));
assert.equal(frame.schema, 'howl.web-frame/v4');
assert.ok(frame.uploads.every(upload => upload.q.every(part => typeof part === 'string')));
assert.ok(frame.removals.every(removal => removal.every(part => typeof part === 'string')));
const pixels = bytesAt(w.rv_pixels_ptr(), w.rv_pixels_len());
const rgba = [];
for (let i = 0; i < frame.commands.count; i += 1) if (frame.commands.kind(i) === 2) rgba.push(i);
assert.equal(rgba.length, 1);
const rgbaIndex = rgba[0];
// Non-vacuous negative-space proof on a required real-producer RGBA command.
const rgbaRecord = bytesAt(w.rv_commands_ptr() + rgbaIndex * 64, 64);
assert.equal(rgbaRecord[0], 2);
assert.equal(rgbaRecord[2], 0, 'RGBA has no cursor-component flag');
assert.equal(rgbaRecord[3], 0, 'private reserved byte');
assert.ok(rgbaRecord.subarray(28, 32).every(byte => byte === 0), 'private padding');
assert.ok(rgbaRecord.subarray(60, 64).every(byte => byte === 0), 'RGBA has no color multiplier');

assert.ok(rgbaIndex > 0); // default background remains below the ordinary negative image
assert.deepEqual([frame.commands.resource(rgbaIndex), frame.commands.generation(rgbaIndex)].map(String), externalKey);
assert.deepEqual([frame.commands.resourceWidth(rgbaIndex), frame.commands.resourceHeight(rgbaIndex)], [2, 2]);
assert.equal(frame.uploads.some(upload => upload.q.map(String).join(':') === externalKey.join(':')), false);
assert.equal(pixels.length, frame.pixels);
assert.equal(frame.residency, 1);
assert.equal(w.rv_ack(), 1);

// The acknowledged exact external resource remains resident on a later frame;
// no second fetch is requested for the same image generation.
bytesAt(w.rv_snapshot_ptr(), snapshot.length).set(snapshot);
assert.equal(w.rv_render(snapshot.length), 1, errorText());
assert.equal(w.rv_missing_external(), 0);
assert.equal(w.rv_render_count(), 2n);
assert.equal(w.rv_ack(), 1);

// Presentation zoom reuses one Wasm instance: reset retained renderer state,
// restore caller-owned font bytes, and initialize a different native lattice.
assert.equal(w.rv_reset(), 1);
for (const [path, pointer, capacity] of [
  [primaryPath, w.rv_font_ptr(), w.rv_font_capacity()],
  [fallbackPath, w.rv_fallback_font_ptr(), w.rv_fallback_font_capacity()],
  [symbolPath, w.rv_symbol_font_ptr(), w.rv_symbol_font_capacity()],
]) {
  const font = await readFile(path);
  assert.ok(font.length > 0 && font.length <= capacity);
  bytesAt(pointer, font.length).set(font);
}
assert.equal(w.rv_init(primary.length, fallback.length, symbol.length, 9), 1, errorText());
assert.equal(w.rv_ready(), 1);
assert.equal(w.rv_render_count(), 0n);

console.log(JSON.stringify({
  status:'pass',
  externalKey,
  image:[7, '9'],
  size:[2, 2],
  stride:8,
  firstBlocked:true,
  zeroExternalUpload:true,
  retainedResidency:true,
  presentationReinit:true,
}));
