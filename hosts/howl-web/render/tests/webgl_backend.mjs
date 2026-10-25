import assert from 'node:assert/strict';
import {clippedSprite, webglFrameEligible} from '../web/webgl_backend_v3.mjs';

const solid = color => [0, 0, 0, 10, 10, ...color];
const alpha = (destination, clip = destination, source = [0, 0, 10, 10]) => [
  1, ...destination, ...clip, 1, 1, 0, 16, 16, ...source, 240, 220, 30, 255, 0,
];
const image = () => [
  2, 0, 0, 10, 10, 0, 0, 10, 10, 2, 1, 1, 10, 10, 0, 0, 10, 10,
];

assert.equal(webglFrameEligible({commands:[solid([0, 0, 0, 255])]}), true);
assert.equal(webglFrameEligible({commands:[alpha([0, 0, 10, 10])]}), true);
assert.equal(webglFrameEligible({commands:[alpha([0, 0, 20, 20])]}), true);
assert.equal(
  webglFrameEligible({commands:[alpha([0, 0, 20, 20], [4, 6, 10, 8])]}),
  true,
  'clipping must preserve an integral source/destination scale',
);
assert.equal(
  webglFrameEligible({commands:[alpha([0, 0, 15, 15])]}),
  false,
  'non-integral alpha scaling stays on exact Canvas2D',
);
assert.equal(
  webglFrameEligible({commands:[alpha([0, 0, 1001, 1001], [0, 0, 1001, 1001], [0, 0, 1000, 1000])]}),
  false,
  'near-integer 1001/1000 scaling is still non-integral and must fall back',
);
assert.equal(webglFrameEligible({commands:[image()]}), false, 'RGBA images stay on Canvas2D');
assert.equal(
  webglFrameEligible({commands:[solid([1, 2, 3, 255]), alpha([0, 0, 20, 20]), image()]}),
  false,
);
assert.equal(
  webglFrameEligible({commands:[alpha([0, 0, 20, 20], [30, 30, 2, 2])]}),
  true,
  'fully clipped commands do not constrain backend admission',
);

assert.deepEqual(
  clippedSprite([0, 0, 20, 20], [4, 6, 10, 8], [0, 0, 10, 10]),
  {destination:[4, 6, 10, 8], source:[2, 3, 5, 4]},
);

console.log(JSON.stringify({status:'pass', backend:'webgl2', fallback:'canvas2d'}));
