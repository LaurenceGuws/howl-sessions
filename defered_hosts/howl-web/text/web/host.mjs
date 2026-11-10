import { assertTextImports, createTextRuntime, textImports } from './runtime.mjs';

const status = document.querySelector('#status');
const output = document.querySelector('#proof');
const repeat = document.querySelector('#repeat');
const decoder = new TextDecoder();
let x, font, reference, runtime, binary;
let runs = 0;
const read = (pointer, length) => new Uint8Array(x.memory.buffer, pointer, length);

async function fetchBytes(path) {
  const response = await fetch(path);
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}
function fault(error) {
  status.textContent = `FAIL: ${error.message}`;
  output.textContent = error.stack;
  repeat.disabled = true;
  console.error(error);
}
function displayMasks(report, masks) {
  const canvas = document.querySelector('#glyphs');
  const context = canvas.getContext('2d');
  const image = context.createImageData(canvas.width, canvas.height);
  for (let i = 0; i < image.data.length; i += 4) {
    image.data.set([12, 18, 24, 255], i);
  }
  let pen = 20;
  for (const item of report.glyphs) {
    const left = Math.round(pen + item.glyph.x_offset / 64) + item.left;
    const top = 60 - item.top - Math.round(item.glyph.y_offset / 64);
    for (let y = 0; y < item.height; y += 1) {
      for (let column = 0; column < item.width; column += 1) {
        const xx = left + column, yy = top + y;
        if (xx < 0 || xx >= canvas.width || yy < 0 || yy >= canvas.height) continue;
        const alpha = masks[item.offset + y * item.width + column] / 255;
        const at = (yy * canvas.width + xx) * 4;
        for (let channel = 0; channel < 3; channel += 1) {
          image.data[at + channel] = Math.round(image.data[at + channel] * (1 - alpha) + [175, 245, 220][channel] * alpha);
        }
      }
    }
    pen += item.glyph.x_advance / 64;
  }
  context.putImageData(image, 0, 0);
}
async function run() {
  repeat.disabled = true;
  if (font.length > x.font_capacity()) throw new Error('Font exceeds test input capacity');
  read(x.font_input(), font.length).set(font);
  if (x.run(font.length) !== 1) throw new Error(decoder.decode(read(x.error_ptr(), x.error_len())));
  const report = JSON.parse(decoder.decode(read(x.result_ptr(), x.result_len())));
  const masks = read(x.raster_ptr(), x.raster_len()).slice();
  if (!read(x.font_input(), font.length).every(byte => byte === 0xa5)) throw new Error('Caller font buffer was not overwritten');
  const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', masks))].map(byte => byte.toString(16).padStart(2, '0')).join('');
  if (JSON.stringify(report) !== JSON.stringify(reference.report)) throw new Error('Native/Wasm metadata differs');
  if (digest !== reference.mask_sha256) throw new Error('Native/Wasm alpha bytes differ');
  displayMasks(report, masks);
  runs += 1;
  status.textContent = 'PASS: shared Howl text engine in the browser';
  output.textContent = JSON.stringify({
    runs, native_metadata_equal: true, native_masks_equal: true,
    glyphs: report.glyphs.length, mask_bytes: masks.length, sha256: digest,
    wasm_bytes: binary.length, memory_bytes: x.memory.buffer.byteLength,
    real_C_nonlocal_jumps: true, caller_buffer_overwritten: true,
    host_imports: textImports, host_calls: runtime.calls,
    full_terminal_renderer: false,
  }, null, 2);
  repeat.disabled = false;
}
repeat.addEventListener('click', () => run().catch(fault));
try {
  binary = await fetchBytes('text-proof.wasm');
  const module = await WebAssembly.compile(binary);
  assertTextImports(module);
  runtime = createTextRuntime();
  x = (await WebAssembly.instantiate(module, runtime.imports)).exports;
  runtime.bind(x.memory);
  x._initialize();
  if (x.jump_probe() !== 1) throw new Error('C nonlocal jump proof failed');
  font = await fetchBytes('font.bin');
  reference = JSON.parse(decoder.decode(await fetchBytes('expected.json')));
  await run();
} catch (error) { fault(error); }
