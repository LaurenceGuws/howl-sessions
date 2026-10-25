import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {assertTextImports, createTextRuntime} from '../../text/web/runtime.mjs';

const [wasmPath, fontPath] = process.argv.slice(2);
const binary = await readFile(wasmPath);
const module = await WebAssembly.compile(binary);
assertTextImports(module);
const runtime = createTextRuntime({output:()=>{}});
const instance = await WebAssembly.instantiate(module, runtime.imports);
runtime.bind(instance.exports.memory);
instance.exports._initialize?.();
const w = instance.exports;
const font = await readFile(fontPath);
assert.ok(font.length <= w.font_capacity());
new Uint8Array(w.memory.buffer, w.font_ptr(), font.length).set(font);
assert.equal(w.run(font.length), 1,
  new TextDecoder().decode(new Uint8Array(w.memory.buffer, w.error_ptr(), w.error_len())));
const report = JSON.parse(new TextDecoder().decode(
  new Uint8Array(w.memory.buffer, w.report_ptr(), w.report_len())));
const pixels = Buffer.from(new Uint8Array(w.memory.buffer, w.pixels_ptr(), w.pixels_len()));
assert.equal(report.schema, 'howl.web-render-proof/v1');
assert.equal(report.uploads, 1);
assert.ok(report.commands > 0);
assert.ok(report.alpha_commands > 0);
assert.ok(report.solid_commands > 0);
assert.equal(report.shape_entries, 4);
assert.equal(report.atlas_entries, 5);
assert.equal(report.pixel_bytes, pixels.length);
assert.ok(pixels.some(value => value !== 0));
assert.equal(report.caller_font_overwritten, true);
console.log(JSON.stringify({status:'pass', wasm_bytes:binary.length, ...report,
  pixel_sha256:createHash('sha256').update(pixels).digest('hex'), host_calls:runtime.calls}));
