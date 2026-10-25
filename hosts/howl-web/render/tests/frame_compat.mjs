import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {assertTextImports, createTextRuntime} from '../../text/web/runtime.mjs';
import {CommandV3Length, FRAME_SCHEMA_V3, parseRendererFrameV3, requireFrameV3, selectRendererFrameV3} from '../web/frame_v3.mjs';
import {FRAME_SCHEMA_V4, parseRendererFrameV4, qualifiedKeyV4, selectRendererFrameV4} from '../web/frame_v4.mjs';

const [wasmPath, primaryPath, fallbackPath, symbolPath] = process.argv.slice(2);
const binary = await readFile(wasmPath);
const module = await WebAssembly.compile(binary);
assertTextImports(module);
const [primary, fallback, symbol] = await Promise.all([
  readFile(primaryPath), readFile(fallbackPath), readFile(symbolPath),
]);
const corpus = JSON.parse(await readFile('../../../mods/server/protocol/vectors.json', 'utf8'));
const vector = corpus.cases.find(value => value.id === 'snapshot_text_v1_complete');
assert.ok(vector?.hex);
const snapshot = Buffer.from(vector.hex, 'hex');
const decoder = new TextDecoder();

async function renderer() {
  const runtime = createTextRuntime({output:()=>{}});
  const instance = await WebAssembly.instantiate(module, runtime.imports);
  runtime.bind(instance.exports.memory);
  instance.exports._initialize?.();
  const w = instance.exports;
  const bytesAt = (pointer, length) => new Uint8Array(w.memory.buffer, Number(pointer), Number(length));
  for (const [font, pointer, capacity] of [
    [primary, w.rv_font_ptr(), w.rv_font_capacity()],
    [fallback, w.rv_fallback_font_ptr(), w.rv_fallback_font_capacity()],
    [symbol, w.rv_symbol_font_ptr(), w.rv_symbol_font_capacity()],
  ]) {
    assert.ok(font.length > 0 && font.length <= capacity);
    bytesAt(pointer, font.length).set(font);
  }
  assert.equal(w.rv_init(primary.length, fallback.length, symbol.length, 18), 1);
  assert.ok(snapshot.length <= w.rv_snapshot_capacity());
  return {w, bytesAt};
}

// A new renderer is deliberately backward-compatible until a new host opts in.
const legacy = await renderer();
assert.equal(legacy.w.rv_frame_format(), 2);
legacy.bytesAt(legacy.w.rv_snapshot_ptr(), snapshot.length).set(snapshot);
assert.equal(legacy.w.rv_render(snapshot.length), 1);
const v2 = JSON.parse(decoder.decode(legacy.bytesAt(legacy.w.rv_frame_ptr(), legacy.w.rv_frame_len())));
assert.equal(v2.schema, 'howl.web-frame/v2');
assert.ok(v2.commands.length > 0);
assert.ok(v2.commands.every(command => !Array.isArray(command) && Number.isInteger(command.k)));
assert.equal(legacy.w.rv_ack(), 1);
assert.equal(legacy.w.rv_set_frame_format(3), 0, 'format cannot change after the first rendered frame');
assert.equal(legacy.w.rv_set_frame_format(4), 0, 'newer format cannot change after the first rendered frame');

// A v44 host may still opt into the accepted compact JSON v3 vocabulary.
const previous = await renderer();
assert.equal(previous.w.rv_frame_format(), 2);
selectRendererFrameV3(previous.w);
previous.bytesAt(previous.w.rv_snapshot_ptr(), snapshot.length).set(snapshot);
assert.equal(previous.w.rv_render(snapshot.length), 1);
const v3 = requireFrameV3(JSON.parse(decoder.decode(previous.bytesAt(previous.w.rv_frame_ptr(), previous.w.rv_frame_len()))));
assert.equal(v3.schema, FRAME_SCHEMA_V3);
const widths = new Map([[0, CommandV3Length.solid], [1, CommandV3Length.alpha], [2, CommandV3Length.rgba]]);
assert.ok(v3.commands.length > 0);
for (const command of v3.commands) assert.equal(command.length, widths.get(command[0]));
// Both JSON vocabularies project the same complete owner commands.
assert.equal(v2.commands.length, v3.commands.length);
for (const field of ['render','observation','terminal','surface','cell','selection_rows','uploads','removals','pixels','residency']) {
  assert.deepEqual(v2[field], v3[field], field);
}
assert.ok(v3.commands.some(command => command[0] === 0));
assert.ok(v3.commands.some(command => command[0] === 1 && command[22] === 0));
assert.ok(v3.commands.some(command => command[0] === 1 && command[22] === 1));
for (const [index, command] of v3.commands.entries()) {
  const kind = command[0];
  let expected;
  if (kind === 0) expected = {k:0,r:command.slice(1,5),color:command.slice(5,9)};
  else {
    expected = {k:kind,d:command.slice(1,5),c:command.slice(5,9),q:command.slice(9,11),
      f:command[11],z:command.slice(12,14),s:command.slice(14,18)};
    if (kind === 1) Object.assign(expected,{color:command.slice(18,22),cc:command[22] !== 0});
  }
  assert.deepEqual(v2.commands[index], expected, 'v2/v3 command '+index);
}
assert.equal(previous.w.rv_ack(), 1);
assert.equal(previous.w.rv_reset(), 1);
assert.equal(previous.w.rv_frame_format(), 3, 'presentation reset preserves the negotiated v3 vocabulary');

// A v45 host opts into v4 before observation and receives the same commands in
// one explicit fixed-width record lane rather than JSON arrays.
const current = await renderer();
assert.equal(current.w.rv_frame_format(), 2);
selectRendererFrameV4(current.w);
current.bytesAt(current.w.rv_snapshot_ptr(), snapshot.length).set(snapshot);
assert.equal(current.w.rv_render(snapshot.length), 1);
const v4 = parseRendererFrameV4(current.w, decoder.decode(current.bytesAt(current.w.rv_frame_ptr(), current.w.rv_frame_len())));
assert.equal(v4.schema, FRAME_SCHEMA_V4);
assert.equal(v4.commands.count, v3.commands.length);
for (let i = 0; i < v3.commands.length; i += 1) {
  const command = v3.commands[i];
  const kind = command[0];
  assert.equal(v4.commands.kind(i), kind);
  assert.deepEqual([v4.commands.x(i), v4.commands.y(i), v4.commands.width(i), v4.commands.height(i)], command.slice(1, 5));
  if (kind === 0) {
    assert.deepEqual([v4.commands.red(i), v4.commands.green(i), v4.commands.blue(i), v4.commands.alpha(i)], command.slice(5, 9));
    continue;
  }
  assert.deepEqual([v4.commands.clipX(i), v4.commands.clipY(i), v4.commands.clipWidth(i), v4.commands.clipHeight(i)], command.slice(5, 9));
  assert.equal(v4.commands.resource(i), BigInt(command[9]));
  assert.equal(v4.commands.generation(i), BigInt(command[10]));
  assert.equal(v4.commands.format(i), command[11]);
  assert.deepEqual([v4.commands.resourceWidth(i), v4.commands.resourceHeight(i)], command.slice(12, 14));
  assert.deepEqual([v4.commands.sourceX(i), v4.commands.sourceY(i), v4.commands.sourceWidth(i), v4.commands.sourceHeight(i)], command.slice(14, 18));
  if (kind === 1) {
    assert.deepEqual([v4.commands.red(i), v4.commands.green(i), v4.commands.blue(i), v4.commands.alpha(i)], command.slice(18, 22));
    assert.equal(v4.commands.cursor(i), command[22] !== 0);
  }
}
// V4 remains its private layout, including unused bytes; it is not the
// same-size Render-native C struct reinterpreted in Wasm memory.
const records = current.bytesAt(current.w.rv_commands_ptr(), current.w.rv_commands_count() * 64);
for (let i = 0; i < current.w.rv_commands_count(); i += 1) {
  const record = records.subarray(i * 64, (i + 1) * 64);
  assert.equal(record[3], 0);
  assert.ok(record.subarray(28, 32).every(byte => byte === 0));
  if (record[0] === 0) {
    assert.equal(record[1], 0);
    assert.equal(record[2], 0);
    assert.ok(record.subarray(16, 60).every(byte => byte === 0));
  }
  if (record[0] === 2) assert.ok(record.subarray(60, 64).every(byte => byte === 0));
}
assert.equal(current.w.rv_ack(), 1);
assert.equal(current.w.rv_reset(), 1);
assert.equal(current.w.rv_frame_format(), 4, 'presentation reset preserves the negotiated v4 vocabulary');

// V4 resource leases remain exact across JavaScript's unsafe-number boundary.
// Metadata carries decimal strings while the command lane carries native u64.
const highResource = 9007199254740993n;
const highGeneration = 9007199254740995n;
const highMemory = new WebAssembly.Memory({initial:1});
const highView = new DataView(highMemory.buffer);
highView.setUint8(0, 1);
highView.setBigUint64(32, highResource, true);
highView.setBigUint64(40, highGeneration, true);
let highResetCount = 0;
const highExports = {
  memory:highMemory,
  rv_commands_ptr:()=>0,
  rv_commands_count:()=>1,
  rv_commands_stride:()=>64,
  rv_reset() { highResetCount += 1; return 1; },
};
const highMetadata = JSON.stringify({
  schema:FRAME_SCHEMA_V4,
  command_count:1,
  command_stride:64,
  uploads:[{q:[String(highResource), String(highGeneration)]}],
  removals:[[String(highResource), String(highGeneration)]],
});
const highFrame = parseRendererFrameV4(highExports, highMetadata);
assert.equal(qualifiedKeyV4(highFrame.uploads[0].q), highFrame.commands.key(0));
assert.equal(qualifiedKeyV4(highFrame.removals[0]), highFrame.commands.key(0));
assert.equal(highResetCount, 0);
assert.throws(
  () => qualifiedKeyV4([Number(highResource), Number(highGeneration)]),
  /invalid Web frame v4 resource identity/,
  'v4 metadata must never reintroduce lossy JS-number identities',
);

// A v45 host paired with an old renderer refuses it before any render can occur.
let oldRenderCalls = 0;
assert.throws(() => selectRendererFrameV4({
  rv_render() { oldRenderCalls += 1; return 1; },
}), /does not support Web frame v4 negotiation/);
assert.equal(oldRenderCalls, 0);
assert.throws(() => requireFrameV3(v2), /incompatible Web frame schema/);
let mismatchResets = 0;
assert.throws(() => parseRendererFrameV4({rv_reset() { mismatchResets += 1; return 1; }}, JSON.stringify(v3)), /incompatible Web frame v4 schema/);
assert.equal(mismatchResets, 1, 'schema mismatch must clear a staged renderer frame before failing');

console.log(JSON.stringify({
  status:'pass', legacyDefaultV2:true, previousHostV3:true, currentHostV4:true,
  v2V3CommandsEquivalent:true, v3V4CommandsEquivalent:true, resetPreservesV3:true, resetPreservesV4:true,
  losslessU64Lease:true, oldRendererRejectedBeforeRender:true, mismatchResets:true,
}));
