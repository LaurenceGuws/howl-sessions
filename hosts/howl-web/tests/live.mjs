// Run only against the disposable echo fixture documented in README.md.
// Node hosts the real Wasm client here; this is not Safari/browser acceptance.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import net from 'node:net';

const [wasmPath, portText, serverText, sessionText, instanceText] = process.argv.slice(2);
if (!/^\d+$/.test(portText ?? '') || Number(portText) < 1 || Number(portText) > 65535)
  throw new Error('usage: zig build live -- SERVER_LOOPBACK_PORT SERVER_ID SESSION_ID INSTANCE_ID');
const ids = [serverText, sessionText, instanceText].map(value => {
  if (!/^[1-9][0-9]*$/.test(value ?? '')) throw new Error('exact nonzero Server/Session/Instance IDs required');
  const id = BigInt(value);
  if (id > 0xffffffffffffffffn) throw new Error('Instance identity exceeds u64');
  return id;
});
function serverFrame(kind, payload = Buffer.alloc(0)) {
  const frame = Buffer.alloc(12 + payload.length);
  frame.write('SRVR'); frame[4] = 2; frame[5] = kind;
  frame.writeUInt32BE(payload.length, 8); payload.copy(frame, 12);
  return frame;
}
const module = await WebAssembly.compile(await readFile(wasmPath));
const w = (await WebAssembly.instantiate(module)).exports;
const text = () => new TextDecoder().decode(new Uint8Array(w.memory.buffer, w.hw_text_ptr(), w.hw_text_len()));
const error = () => new TextDecoder().decode(new Uint8Array(w.memory.buffer, w.hw_error_ptr(), w.hw_error_len()));
let socket;
let pending;
let failure;
function waitFor(phase) {
  if (failure) return Promise.reject(failure);
  if (w.hw_phase() === phase) return Promise.resolve();
  assert.equal(pending, undefined);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending = undefined;
      reject(new Error(`timeout waiting for phase ${phase}, current ${w.hw_phase()}`));
    }, 5000);
    pending = {phase, resolve:() => {clearTimeout(timer); pending=undefined; resolve();},
      reject:e => {clearTimeout(timer); pending=undefined; reject(e);}};
  });
}
function fault(e) { failure = e; pending?.reject(e); }
function send() {
  socket.write(new Uint8Array(w.memory.buffer, w.hw_output_ptr(), w.hw_output_len()));
}
async function attach() {
  assert.equal(w.hw_reset(), 1);
  failure = undefined;
  socket = net.createConnection({host:'127.0.0.1', port:Number(portText)});
  socket.on('error', fault);
  let welcome = Buffer.alloc(0);
  socket.on('data', bytes => {
    try {
      if (welcome !== undefined) {
        // Only the 44-byte Server welcome is intercepted. The common ready
        // response and every terminal frame go directly into the real Wasm.
        const needed = 44 - welcome.length;
        const copied = Math.min(needed, bytes.length);
        welcome = Buffer.concat([welcome, bytes.subarray(0, copied)]);
        bytes = bytes.subarray(copied);
        if (welcome.length < 44) return;
        assert.equal(welcome.subarray(0, 4).toString(), 'SRVR');
        assert.equal(welcome[4], 2); assert.equal(welcome[5], 2);
        assert.equal(welcome.readUInt16BE(6), 0);
        assert.equal(welcome.readUInt32BE(8), 32);
        assert.equal(welcome.readBigUInt64BE(12), ids[0], 'stale Server incarnation');
        const identity = Buffer.alloc(16);
        identity.writeBigUInt64BE(ids[1]); identity.writeBigUInt64BE(ids[2], 8);
        welcome = undefined;
        socket.write(serverFrame(11, identity));
      }
      // Deliberate single-byte deliveries pressure header and snapshot boundaries.
      for (const byte of bytes) {
        new Uint8Array(w.memory.buffer, w.hw_input_ptr(), 1)[0] = byte;
        const accepted = w.hw_feed(1);
        assert.ok(accepted === 1 || accepted === 2, error());
        if (accepted === 2) send();
      }
      if (pending && w.hw_phase() === pending.phase) pending.resolve();
    } catch (e) { fault(e); }
  });
  await new Promise((resolve, reject) => {socket.once('connect', resolve); socket.once('error', reject);});
  socket.write(serverFrame(1)); await waitFor(2);
  return w.hw_identity();
}
async function observe(immediate) {
  assert.equal(w.hw_observe(immediate, 0), 1);
  send(); await waitFor(4);
}
async function untilContains(marker) {
  for (let attempt = 0; attempt < 10; attempt++) {
    await observe(attempt === 0 ? 1 : 0);
    if (text().includes(marker)) return;
  }
  throw new Error(`canonical snapshot lacks ${marker}`);
}
async function control(begin) {
  assert.equal(w.hw_control_ready(), 1);
  assert.equal(begin(), 1);
  send(); await waitFor(6);
}
function stageText(value) {
  const encoded = new TextEncoder().encode(value);
  assert.ok(encoded.length > 0 && encoded.length <= w.hw_input_capacity());
  new Uint8Array(w.memory.buffer, w.hw_input_ptr(), encoded.length).set(encoded);
  return encoded.length;
}
async function committed(value) {
  const length = stageText(value);
  await control(() => w.hw_send_text(length));
}
async function paste(value) {
  const length = stageText(value);
  await control(() => w.hw_send_paste(length));
}
async function named(key, modifiers = 0) {
  await control(() => w.hw_send_named_key(key, 1, modifiers));
}
async function focus(value) {
  await control(() => w.hw_send_focus(value));
}
async function resize(rows, columns) {
  await control(() => w.hw_send_resize(rows, columns));
}

async function disconnect() {
  const current = socket;
  assert.equal(w.hw_finish(), 1);
  await new Promise(resolve => {current.once('close', resolve); current.destroy();});
}
try {
  const first = await attach();
  await untilContains('HOWL_WEB_ECHO_READY');
  await committed('semantic canary: café λ');
  await named(1); // Enter is a semantic physical key, not a browser newline byte.
  await untilContains('ACK_FROM_PTY: semantic canary: café λ');

  await committed('eraseX');
  await named(3); // Canonical Backspace should erase X in the real PTY line discipline.
  await named(1);
  await untilContains('ACK_FROM_PTY: erase');

  await paste('pasted λ');
  await named(1);
  await untilContains('ACK_FROM_PTY: pasted λ');
  await focus(2);
  await focus(1);

  assert.equal(w.hw_rows(), 12); assert.equal(w.hw_columns(), 72);
  await resize(10, 60);
  await observe(0);
  assert.equal(w.hw_rows(), 10); assert.equal(w.hw_columns(), 60);
  const before = text(), revision = w.hw_revision(), terminalRevision = w.hw_terminal_revision();
  await disconnect();
  const second = await attach();
  assert.notEqual(second, first);
  await observe(1);
  assert.equal(text(), before);
  assert.equal(w.hw_terminal_revision(), terminalRevision);
  assert.ok(w.hw_revision() > revision); // Disconnect released resize leadership only.
  assert.equal(w.hw_rows(), 10); assert.equal(w.hw_columns(), 60);
  console.log(JSON.stringify({status:'pass', firstClient:String(first), reconnectedClient:String(second),
    revisionBeforeDisconnect:String(revision), revisionAfterReconnect:String(w.hw_revision()), terminalRevision:String(terminalRevision), rows:w.hw_rows(), columns:w.hw_columns(), textBytes:w.hw_text_len(), snapshotBytes:w.hw_snapshot_len(),
    realPtyEcho:true, semanticEnter:true, semanticBackspace:true, semanticPaste:true, semanticFocus:true, semanticResize:true,
    sharedRichDecoder:true, oneByteDelivery:true, reconnect:true}));
  await disconnect();
} finally {
  socket?.destroy();
}
