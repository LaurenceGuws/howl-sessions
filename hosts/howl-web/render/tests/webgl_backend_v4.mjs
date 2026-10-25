import assert from 'node:assert/strict';
import {BinaryCommands} from '../web/frame_v4.mjs';
import {WebGLTerminalBackend, clippedSprite, webglFrameEligible} from '../web/webgl_backend_v4.mjs';

const solid = color => [0, 0, 0, 10, 10, ...color];
const alpha = (destination, clip = destination, source = [0, 0, 10, 10], qualified = [1, 1]) => [
  1, ...destination, ...clip, ...qualified, 0, 16, 16, ...source, 240, 220, 30, 255, 0,
];
const image = () => [
  2, 0, 0, 10, 10, 0, 0, 10, 10, 2, 1, 1, 10, 10, 0, 0, 10, 10,
];

function binary(list) {
  const bytes = new Uint8Array(list.length * 64);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < list.length; i += 1) {
    const command = list[i], base = i * 64, kind = command[0];
    bytes[base] = kind;
    view.setInt32(base + 4, command[1], true);
    view.setInt32(base + 8, command[2], true);
    view.setUint16(base + 12, command[3], true);
    view.setUint16(base + 14, command[4], true);
    if (kind === 0) {
      bytes.set(command.slice(5, 9), base + 60);
      continue;
    }
    view.setInt32(base + 16, command[5], true);
    view.setInt32(base + 20, command[6], true);
    view.setUint16(base + 24, command[7], true);
    view.setUint16(base + 26, command[8], true);
    view.setBigUint64(base + 32, BigInt(command[9]), true);
    view.setBigUint64(base + 40, BigInt(command[10]), true);
    bytes[base + 1] = command[11];
    view.setUint16(base + 48, command[12], true);
    view.setUint16(base + 50, command[13], true);
    view.setUint16(base + 52, command[14], true);
    view.setUint16(base + 54, command[15], true);
    view.setUint16(base + 56, command[16], true);
    view.setUint16(base + 58, command[17], true);
    if (kind === 1) {
      bytes[base + 2] = command[22] ? 1 : 0;
      bytes.set(command.slice(18, 22), base + 60);
    }
  }
  return new BinaryCommands({buffer:bytes.buffer}, 0, list.length, 64);
}
const frame = commands => ({commands:binary(commands)});

assert.equal(webglFrameEligible(frame([solid([0, 0, 0, 255])])), true);
assert.equal(webglFrameEligible(frame([alpha([0, 0, 10, 10])])), true);
assert.equal(webglFrameEligible(frame([alpha([0, 0, 20, 20])])), true);
assert.equal(webglFrameEligible(frame([alpha([0, 0, 20, 20], [4, 6, 10, 8])])), true);
assert.equal(webglFrameEligible(frame([alpha([0, 0, 15, 15])])), false);
assert.equal(webglFrameEligible(frame([alpha([0, 0, 1001, 1001], [0, 0, 1001, 1001], [0, 0, 1000, 1000])])), false);
assert.equal(webglFrameEligible(frame([image()])), false);
assert.equal(webglFrameEligible(frame([solid([1, 2, 3, 255]), alpha([0, 0, 20, 20]), image()])), false);
assert.equal(webglFrameEligible(frame([alpha([0, 0, 20, 20], [30, 30, 2, 2])])), true);

const admissionFixtures = [
  {destination:[0, 0, 20, 20], clip:[4, 6, 10, 8], source:[0, 0, 10, 10]},
  {destination:[-10, -10, 20, 20], clip:[0, 0, 10, 10], source:[0, 0, 10, 10]},
  {destination:[0, 0, 10, 10], clip:[10, 0, 10, 10], source:[0, 0, 10, 10]},
  {destination:[0, 0, 10, 10], clip:[0, 0, 0, 10], source:[0, 0, 10, 10]},
  {destination:[0, 0, 10, 10], clip:[0, 0, 10, 10], source:[0, 0, 0, 10]},
  {destination:[0, 0, 15, 15], clip:[0, 0, 15, 15], source:[0, 0, 10, 10]},
  {destination:[0, 0, 15, 15], clip:[30, 30, 2, 2], source:[0, 0, 10, 10]},
];
for (const {destination, clip, source} of admissionFixtures) {
  const visible = clippedSprite(destination, clip, source) !== null;
  const integral = Number.isInteger(destination[2]) && Number.isInteger(destination[3]) &&
    Number.isInteger(source[2]) && Number.isInteger(source[3]) &&
    source[2] > 0 && source[3] > 0 &&
    destination[2] >= source[2] && destination[3] >= source[3] &&
    destination[2] % source[2] === 0 && destination[3] % source[3] === 0;
  assert.equal(
    webglFrameEligible(frame([alpha(destination, clip, source)])),
    !visible || integral,
  );
}

const backendState = {admittedCommands:null};
const admitted = frame([alpha([0, 0, 20, 20])]);
const rejected = frame([image()]);
assert.equal(WebGLTerminalBackend.prototype.admit.call(backendState, admitted), true);
assert.equal(backendState.admittedCommands, admitted.commands);
assert.equal(WebGLTerminalBackend.prototype.admit.call(backendState, rejected), false);
assert.equal(backendState.admittedCommands, null);
backendState.admittedCommands = admitted.commands;
assert.throws(
  () => WebGLTerminalBackend.prototype.admit.call(backendState, {commands:{count:1, kind() { throw new Error('broken command view'); }}}),
  /broken command view/,
);
assert.equal(backendState.admittedCommands, null);
backendState.admittedCommands = admitted.commands;
assert.throws(
  () => WebGLTerminalBackend.prototype.draw.call(backendState, rejected, () => ''),
  /outside WebGL terminal admission/,
);
assert.equal(backendState.admittedCommands, null);

const runCommands = binary([
  solid([0, 0, 0, 255]),
  alpha([0, 0, 20, 20], undefined, undefined, [1, 1]),
  alpha([20, 0, 20, 20], undefined, undefined, [1, 1]),
  alpha([40, 0, 20, 20], [100, 100, 1, 1], undefined, [99, 99]),
  alpha([0, 20, 20, 20], undefined, undefined, [1, 2]),
  alpha([20, 20, 20, 20], undefined, undefined, [1, 2]),
  alpha([40, 20, 20, 20], undefined, undefined, [1, 1]),
]);
const lookupKeys = [];
const resourceMap = new Map([['1:1', {id:'one'}], ['1:2', {id:'two'}]]);
const drawState = {
  admittedCommands:runCommands,
  resources:{get(key) { lookupKeys.push(key); return resourceMap.get(key); }},
  canvas:{width:0, height:0},
  gl:{
    COLOR_BUFFER_BIT:1, NO_ERROR:0,
    viewport() {}, clearColor() {}, clear() {},
    isContextLost() { return false; }, getError() { return 0; },
  },
  count:0, batchKey:null, drawCalls:0,
  flush() { if (this.count !== 0) { this.drawCalls += 1; this.count = 0; } },
  beginBatch(key, mode, resource) {
    this.batchKey = key; this.batchMode = mode; this.batchResource = resource; this.count = 0;
  },
  appendValues() { this.count += 1; },
};
assert.deepEqual(
  WebGLTerminalBackend.prototype.draw.call(drawState, {surface:[64, 64], commands:runCommands}, () => ''),
  {draw_calls:4},
);
assert.deepEqual(lookupKeys, ['1:1', '1:2', '1:1']);
const missingCommands = binary([alpha([0, 0, 20, 20], undefined, undefined, [7, 3])]);
drawState.admittedCommands = missingCommands;
assert.throws(
  () => WebGLTerminalBackend.prototype.draw.call(
    drawState, {surface:[64, 64], commands:missingCommands}, () => '',
  ),
  /missing WebGL alpha resource 7:3/,
);

assert.deepEqual(
  clippedSprite([0, 0, 20, 20], [4, 6, 10, 8], [0, 0, 10, 10]),
  {destination:[4, 6, 10, 8], source:[2, 3, 5, 4]},
);

console.log(JSON.stringify({status:'pass', backend:'webgl2', frame:'v4', fallback:'canvas2d'}));
