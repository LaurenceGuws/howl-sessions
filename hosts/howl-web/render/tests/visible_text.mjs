import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {assertTextImports, createTextRuntime} from '../../text/web/runtime.mjs';
import {CommandV3Length, selectRendererFrameV3} from '../web/frame_v3.mjs';

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
selectRendererFrameV3(w);
assert.equal(w.rv_text_len(), 0);
assert.equal(w.rv_text_truncated(), 0);

const corpus = JSON.parse(await readFile(vectorsPath, 'utf8'));
const vector = corpus.cases.find(value => value.id === 'snapshot_text_v1_complete');
assert.ok(vector?.hex);
const snapshot = Buffer.from(vector.hex, 'hex');
assert.ok(snapshot.length <= w.rv_snapshot_capacity());
bytesAt(w.rv_snapshot_ptr(), snapshot.length).set(snapshot);
assert.equal(w.rv_render(snapshot.length), 1, errorText());
const frame = JSON.parse(decoder.decode(bytesAt(w.rv_frame_ptr(), w.rv_frame_len())));
assert.equal(frame.schema, 'howl.web-frame/v3');
const commandLengths = new Map([[0, CommandV3Length.solid], [1, CommandV3Length.alpha], [2, CommandV3Length.rgba]]);
for (const command of frame.commands) {
  assert.ok(Array.isArray(command));
  assert.ok(commandLengths.has(command[0]));
  assert.equal(command.length, commandLengths.get(command[0]));
}
assert.ok(frame.commands.some(command => command[0] === 0));
assert.ok(frame.commands.some(command => command[0] === 1));
assert.equal(w.rv_text_len(), 0); // A is staged until the browser acknowledges its draw.
assert.equal(w.rv_ack(), 1);
assert.equal(decoder.decode(bytesAt(w.rv_text_ptr(), w.rv_text_len())), 'é中');
assert.equal(w.rv_text_truncated(), 0);

const rawVector = corpus.cases.find(value => value.id === 'snapshot_text_v1_raw_complete');
assert.ok(rawVector?.hex);
const nextSnapshot = Buffer.from(rawVector.hex, 'hex');
const firstScalar = Buffer.from([0, 0, 0, 0x65]);
const scalarAt = nextSnapshot.indexOf(firstScalar);
assert.ok(scalarAt >= 0);
assert.equal(nextSnapshot.indexOf(firstScalar, scalarAt + 1), -1);
nextSnapshot[scalarAt + 3] = 0x41;
assert.ok(nextSnapshot.length <= w.rv_snapshot_capacity());
bytesAt(w.rv_snapshot_ptr(), nextSnapshot.length).set(nextSnapshot);
assert.equal(w.rv_render(nextSnapshot.length), 1, errorText());
assert.equal(decoder.decode(bytesAt(w.rv_text_ptr(), w.rv_text_len())), 'é中'); // A remains published.
assert.equal(w.rv_ack(), 1);
assert.equal(decoder.decode(bytesAt(w.rv_text_ptr(), w.rv_text_len())), 'Á中'); // B publishes only with ack.
assert.equal(w.rv_text_truncated(), 0);
assert.equal(w.rv_reset(), 1);
assert.equal(w.rv_text_len(), 0);
assert.equal(w.rv_text_truncated(), 0);

console.log(JSON.stringify({status:'pass', visible:'Á中', ackPublication:true, rendered:true, reset:true}));
