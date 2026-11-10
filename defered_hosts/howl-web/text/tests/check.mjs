import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { assertTextImports, createTextRuntime, textImports } from '../web/runtime.mjs';

const [wasmPath, fontPath, referencePath] = process.argv.slice(2);
if (!wasmPath || !fontPath || !referencePath) throw new Error('usage: check.mjs WASM FONT REFERENCE_DIRECTORY');

// The same host implementation is tested here and imported by the browser.
const messages = [];
const testMemory = new WebAssembly.Memory({ initial: 1, maximum: 2 });
const testRuntime = createTextRuntime({ output: (fd, text) => messages.push([fd, text]) });
const host = testRuntime.imports.wasi_snapshot_preview1;
testRuntime.bind(testMemory);
assert.throws(() => testRuntime.bind(testMemory));
assert.throws(() => createTextRuntime({ entropy: null }));
assert.equal(host.fd_seek(1), 70);
assert.equal(host.fd_seek(123), 8);
assert.equal(host.fd_write(123, 0, 0, 32), 8);
assert.equal(host.fd_write(1, 0, 129, 32), 28);
assert.equal(host.fd_write(1, 0xfffffff0, 4, 32), 21);
const view = new DataView(testMemory.buffer);
view.setUint32(0, 100, true); view.setUint32(4, 1, true);
view.setUint32(8, 0xfffffff0, true); view.setUint32(12, 64, true);
assert.equal(host.fd_write(1, 0, 2, 32), 21);
assert.equal(messages.length, 0, 'invalid vectors emitted partial console output');
view.setUint32(8, 101, true); view.setUint32(12, 1, true);
new Uint8Array(testMemory.buffer).set([0xc3, 0xa9], 100);
assert.equal(host.fd_write(1, 0, 2, 32), 0);
assert.deepEqual(messages, [[1, 'é']]);
assert.equal(view.getUint32(32, true), 2);
assert.equal(host.random_get(0xfffffff0, 100), 21);
assert.equal(host.random_get(0, 1048577), 28);
testMemory.grow(1);
assert.equal(host.random_get(65536, 32), 0, 'runtime retained a stale memory view');
assert.equal(host.fd_close(1), 0);
assert.equal(host.fd_close(1), 8);
assert.equal(host.fd_write(1, 0, 0, 32), 8);

const cappedRuntime = createTextRuntime({ output: () => {} });
cappedRuntime.bind(testMemory);
const cappedHost = cappedRuntime.imports.wasi_snapshot_preview1;
const largeView = new DataView(testMemory.buffer);
largeView.setUint32(0, 4096, true);
largeView.setUint32(4, 65536, true);
for (let i = 0; i < 16; i += 1) assert.equal(cappedHost.fd_write(1, 0, 1, 32), 0);
assert.equal(cappedHost.fd_write(1, 0, 1, 32), 28, 'console budget did not stop at one MiB');
assert.equal(largeView.getUint32(32, true), 65536, 'rejected write changed its output count');

const binary = await readFile(wasmPath);
const module = await WebAssembly.compile(binary);
assertTextImports(module);
assert.deepEqual(WebAssembly.Module.exports(module).map(item => [item.name, item.kind]).sort(), [
  ['memory', 'memory'], ...[
    '_initialize', 'font_input', 'font_capacity', 'run', 'jump_probe',
    'result_ptr', 'result_len', 'raster_ptr', 'raster_len', 'error_ptr', 'error_len',
  ].map(name => [name, 'function']),
].sort(), 'text canary export contract changed');
const runtime = createTextRuntime();
const instance = await WebAssembly.instantiate(module, runtime.imports);
const x = instance.exports;
runtime.bind(x.memory);
assert.equal(x.memory.buffer.byteLength, 64 * 1024 * 1024);
x._initialize();
assert.equal(x.jump_probe(), 1, 'real C nonlocal jumps failed');
const font = await readFile(fontPath);
assert(font.length <= x.font_capacity());
const bytes = () => new Uint8Array(x.memory.buffer);
const read = (ptr, len) => Buffer.from(bytes().subarray(ptr, ptr + len));
const error = () => read(x.error_ptr(), x.error_len()).toString('utf8');
function runFont() {
  bytes().set(font, x.font_input());
  const result = x.run(font.length);
  assert.equal(result, 1, error());
}
runFont();
const report = JSON.parse(read(x.result_ptr(), x.result_len()).toString('utf8'));
const masks = read(x.raster_ptr(), x.raster_len());
const reference = JSON.parse(await readFile(join(referencePath, 'expected.json'), 'utf8'));
const nativeMasks = await readFile(join(referencePath, 'masks.bin'));
assert.deepEqual(report, reference.report, 'native/Wasm metadata differs');
assert.deepEqual(masks, nativeMasks, 'native/Wasm alpha bytes differ');
assert(bytes().subarray(x.font_input(), x.font_input() + font.length).every(value => value === 0xa5));
assert.equal(x.run(0), 0); assert.equal(error(), 'InvalidConfig');
assert.equal(x.result_len(), 0, 'rejected input retained a stale report');
assert.equal(x.run(x.font_capacity() + 1), 0); assert.equal(error(), 'InputTooLarge');
bytes().set(new TextEncoder().encode('not a font'), x.font_input());
assert.equal(x.run(10), 0); assert.equal(error(), 'FontOpen');
const warmMemory = x.memory.buffer.byteLength;
for (let i = 0; i < 50; i += 1) {
  runFont();
  assert.deepEqual(read(x.raster_ptr(), x.raster_len()), masks);
  assert.deepEqual(JSON.parse(read(x.result_ptr(), x.result_len())), report);
  assert.equal(x.memory.buffer.byteLength, warmMemory, 'repeated construction kept growing memory');
}
const beyondMaximum = (96 * 1024 * 1024 - x.memory.buffer.byteLength) / 65536 + 1;
assert.throws(() => x.memory.grow(beyondMaximum), RangeError);
const digest = createHash('sha256').update(masks).digest('hex');
assert.equal(digest, reference.mask_sha256);
console.log(JSON.stringify({
  status: 'pass', wasm_bytes: binary.length, memory_bytes: x.memory.buffer.byteLength,
  maximum_memory_bytes: 96 * 1024 * 1024, host_imports: textImports, host_calls: runtime.calls,
  native_wasm_metadata_equal: true, native_wasm_bytes_equal: true,
  glyphs: report.glyphs.length, mask_bytes: masks.length, mask_sha256: digest,
  real_nonlocal_jumps: true, caller_buffer_overwritten: true,
  repeated_runs_without_growth: 50, invalid_input_recovery: true,
  restricted_host_negative_tests: true,
}));
