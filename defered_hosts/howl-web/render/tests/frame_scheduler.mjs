import assert from 'node:assert/strict';
import {LatestFrameScheduler} from '../web/frame_scheduler.mjs';

const callbacks = [];
const painted = [];
const scheduler = new LatestFrameScheduler({schedule:callback => callbacks.push(callback), draw:frame => painted.push(frame)});
scheduler.push({revision:1});
scheduler.push({revision:2});
scheduler.push({revision:3});
assert.equal(callbacks.length, 1);
assert.equal(scheduler.pending, true);
callbacks.shift()();
assert.deepEqual(painted, [{revision:3}]);
assert.equal(scheduler.pending, false);
scheduler.push({revision:4});
assert.equal(callbacks.length, 1);
callbacks.shift()();
assert.deepEqual(painted, [{revision:3},{revision:4}]);

const resumableCallbacks = [];
let cancelled = 0;
const resumedPaints = [];
const resumable = new LatestFrameScheduler({
  schedule:callback => {
    let active = true;
    resumableCallbacks.push(() => { if (active) callback(); });
    return () => { active = false; cancelled += 1; };
  },
  draw:frame => resumedPaints.push(frame),
});
resumable.push({revision:5});
resumable.push({revision:6});
assert.equal(resumable.resume(), true);
assert.equal(cancelled, 1);
assert.equal(resumableCallbacks.length, 2);
resumableCallbacks[0]();
assert.deepEqual(resumedPaints, []);
resumableCallbacks[1]();
assert.deepEqual(resumedPaints, [{revision:6}]);
assert.equal(resumable.resume(), false);

const resetCallbacks = [];
let resetCancelled = 0;
const resetPaints = [];
const resettable = new LatestFrameScheduler({
  schedule:callback => {
    let active = true;
    resetCallbacks.push(() => { if (active) callback(); });
    return () => { active = false; resetCancelled += 1; };
  },
  draw:frame => resetPaints.push(frame),
});
resettable.push({revision:7});
resettable.reset();
assert.equal(resettable.pending, false);
assert.equal(resettable.latest, null);
assert.equal(resetCancelled, 1);
resettable.push({revision:1});
assert.equal(resetCallbacks.length, 2);
resetCallbacks[0]();
assert.deepEqual(resetPaints, []);
resetCallbacks[1]();
assert.deepEqual(resetPaints, [{revision:1}]);

const asyncCallbacks = [];
const asyncPaints = [];
let releaseAsync;
const asyncDraw = new Promise(resolve => { releaseAsync = resolve; });
const asynchronous = new LatestFrameScheduler({
  schedule:callback => asyncCallbacks.push(callback),
  draw:async frame => {
    asyncPaints.push(frame);
    await asyncDraw;
  },
});
asynchronous.push({revision:8});
asyncCallbacks.shift()();
assert.equal(asynchronous.drawing, true);
asynchronous.push({revision:9});
asynchronous.push({revision:10});
assert.equal(asyncCallbacks.length, 0);
releaseAsync();
await new Promise(resolve => setTimeout(resolve, 0));
assert.equal(asynchronous.drawing, false);
assert.equal(asyncCallbacks.length, 1);
asyncCallbacks.shift()();
await new Promise(resolve => setTimeout(resolve, 0));
assert.deepEqual(asyncPaints, [{revision:8},{revision:10}]);

console.log(JSON.stringify({status:'pass', latestWins:true, oneScheduled:true, visibleResume:true, reconnectReset:true, asyncCoalescing:true}));
