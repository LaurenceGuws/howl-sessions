import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {assertTextImports, createTextRuntime} from '../../text/web/runtime.mjs';
import {CommandV3Length, selectRendererFrameV3} from '../web/frame_v3.mjs';

const [wasmPath, primaryPath, fallbackPath, symbolPath] = process.argv.slice(2);
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
selectRendererFrameV3(w);

function parseFrames(bytes) {
  const frames = [];
  let offset = 0;
  while (offset < bytes.length) {
    assert.equal(bytes.toString('ascii', offset, offset + 4), 'SRVR');
    assert.equal(bytes[offset + 4], 2);
    assert.equal(bytes[offset + 6], 0);
    assert.equal(bytes[offset + 7], 0);
    const kind = bytes[offset + 5];
    const length = bytes.readUInt32BE(offset + 8);
    const end = offset + 12 + length;
    assert.ok(end <= bytes.length);
    frames.push({kind, payload:Buffer.from(bytes.subarray(offset + 12, end))});
    offset = end;
  }
  assert.equal(offset, bytes.length);
  return frames;
}

function encodeFrame(kind, payload) {
  const result = Buffer.alloc(12 + payload.length);
  result.write('SRVR', 0, 4, 'ascii');
  result[4] = 2;
  result[5] = kind;
  result.writeUInt32BE(payload.length, 8);
  payload.copy(result, 12);
  return result;
}

const images = Array.from({length:7}, (_, index) => ({
  id:7 + index,
  generation:9n + BigInt(index),
  width:index === 0 ? 2 : 1,
  height:index === 0 ? 2 : 1,
}));
const placement = (id, generation, z=0) => {
  const image = images.find(value => value.id === id);
  return {
    id, generation, z,
    sourceWidth:image.width, sourceHeight:image.height,
    pixelWidth:image.width, pixelHeight:image.height,
  };
};
// Raw manifest order is intentionally not paint order. Image 7 appears twice,
// and its newer equal-z placement is encoded before its older one. Content must
// order by z then canonical placement generation, never by manifest slot.
const placements = [
  placement(7, 27n, -3),
  placement(13, 26n),
  placement(12, 25n),
  placement(11, 24n),
  placement(10, 23n),
  placement(9, 22n),
  placement(8, 21n),
  placement(7, 20n, -3),
];

function encodeGraphics() {
  const result = Buffer.alloc(28 + images.length * 20 + placements.length * 52);
  let offset = 0;
  result.writeBigUInt64BE(31n, offset); offset += 8;
  result.writeBigUInt64BE(30n, offset); offset += 8;
  result.writeUInt32BE(10, offset); offset += 4;
  result.writeUInt32BE(20, offset); offset += 4;
  result.writeUInt16BE(images.length, offset); offset += 2;
  result.writeUInt16BE(placements.length, offset); offset += 2;
  for (const image of images) {
    result.writeUInt32BE(image.id, offset); offset += 4;
    result.writeBigUInt64BE(image.generation, offset); offset += 8;
    result.writeUInt32BE(image.width, offset); offset += 4;
    result.writeUInt32BE(image.height, offset); offset += 4;
  }
  for (const value of placements) {
    result.writeUInt32BE(value.id, offset); offset += 4;
    result.writeBigUInt64BE(value.generation, offset); offset += 8;
    result.writeUInt16BE(0, offset); offset += 2; // row
    result.writeUInt16BE(0, offset); offset += 2; // column
    result.writeUInt32BE(0, offset); offset += 4; // source x
    result.writeUInt32BE(0, offset); offset += 4; // source y
    result.writeUInt32BE(value.sourceWidth, offset); offset += 4;
    result.writeUInt32BE(value.sourceHeight, offset); offset += 4;
    result.writeUInt32BE(0, offset); offset += 4; // cell x
    result.writeUInt32BE(0, offset); offset += 4; // cell y
    result.writeUInt32BE(value.pixelWidth, offset); offset += 4;
    result.writeUInt32BE(value.pixelHeight, offset); offset += 4;
    result.writeInt32BE(value.z, offset); offset += 4;
  }
  assert.equal(offset, result.length);
  return result;
}

const corpus = JSON.parse(await readFile('../../../mods/server/protocol/vectors.json', 'utf8'));
const frozen = corpus.cases.find(value => value.id === 'snapshot_graphics_manifest');
assert.ok(frozen?.hex);
const originalFrames = parseFrames(Buffer.from(frozen.hex, 'hex'));
assert.equal(originalFrames.filter(frame => frame.kind === 52).length, 1);
const snapshot = Buffer.concat(originalFrames.map(frame =>
  encodeFrame(frame.kind, frame.kind === 52 ? encodeGraphics() : frame.payload)));
assert.ok(snapshot.length <= w.rv_snapshot_capacity());

const loadSnapshot = () => bytesAt(w.rv_snapshot_ptr(), snapshot.length).set(snapshot);
function missing() {
  assert.equal(w.rv_missing_external(), 1);
  return {
    resource:w.rv_missing_resource(),
    generation:w.rv_missing_generation(),
    imageId:w.rv_missing_image_id(),
    imageGeneration:w.rv_missing_image_generation(),
    width:w.rv_missing_width(),
    height:w.rv_missing_height(),
    stride:w.rv_missing_stride(),
  };
}
const qualified = value => [value.resource, value.generation].map(String);

assert.equal(w.rv_render_count(), 0n);
const misses = [];
for (const image of images) {
  loadSnapshot();
  assert.equal(w.rv_render(snapshot.length), 2, errorText());
  assert.equal(w.rv_render_count(), 0n);
  const value = missing();
  assert.equal(value.imageId, image.id);
  assert.equal(value.imageGeneration, image.generation);
  assert.deepEqual([value.width, value.height, value.stride], [image.width, image.height, image.width * 4]);
  misses.push(value);
  assert.equal(w.rv_accept_external(), 1);
}
assert.equal(new Set(misses.map(value => qualified(value).join(':'))).size, 7);

// Seven singular external accepts consume the whole portable image bound. The
// eighth call is the successful final render, exactly matching the browser host
// retry budget rather than requiring an extra hidden attempt.
loadSnapshot();
assert.equal(w.rv_render(snapshot.length), 1, errorText());
assert.equal(w.rv_render_count(), 1n);
assert.equal(w.rv_missing_external(), 0);
const frame = JSON.parse(decoder.decode(bytesAt(w.rv_frame_ptr(), w.rv_frame_len())));
assert.equal(frame.schema, 'howl.web-frame/v3');
const rgba = frame.commands.filter(command => command[0] === 2);
assert.equal(rgba.length, 8);
assert.ok(rgba.every(command => command.length === CommandV3Length.rgba));
const keys = new Map(misses.map(value => [value.imageId, qualified(value)]));
assert.deepEqual(rgba.map(command => command.slice(9, 11).map(String)), [
  keys.get(7), keys.get(7),
  keys.get(8), keys.get(9), keys.get(10), keys.get(11), keys.get(12), keys.get(13),
]);
assert.equal(frame.uploads.some(upload =>
  misses.some(value => upload.q.map(String).join(':') === qualified(value).join(':'))), false);
assert.equal(frame.residency, 7);
assert.equal(w.rv_ack(), 1);

loadSnapshot();
assert.equal(w.rv_render(snapshot.length), 1, errorText());
assert.equal(w.rv_missing_external(), 0);
assert.equal(w.rv_render_count(), 2n);
const stable = JSON.parse(decoder.decode(bytesAt(w.rv_frame_ptr(), w.rv_frame_len())));
assert.equal(stable.commands.filter(command => command[0] === 2).length, 8);
assert.equal(w.rv_ack(), 1);

console.log(JSON.stringify({
  status:'pass', images:7, placements:8, serialRefills:7, finalAttempt:8,
  retainedResidency:true, equalZGenerationOrder:true,
}));
