import assert from 'node:assert/strict';
import {scheduleDisplay} from '../web/display_schedule.mjs';

function harness(visible = true) {
  let raf, timer, cancelledFrame = null, clearedTimer = null, winner = null, draws = 0;
  const cancel = scheduleDisplay(() => { draws += 1; }, {
    requestFrame:callback => { raf = callback; return 11; },
    cancelFrame:id => { cancelledFrame = id; },
    setTimer:(callback, ms) => { assert.equal(ms, 50); timer = callback; return 22; },
    clearTimer:id => { clearedTimer = id; },
    visible:() => visible,
    maxDelayMs:50,
    onWinner:source => { winner = source; },
  });
  return {cancel, raf:()=>raf?.(), timer:()=>timer?.(), state:()=>({cancelledFrame, clearedTimer, winner, draws, timerPresent:Boolean(timer)})};
}

const rafWins = harness(true);
rafWins.raf();
rafWins.timer();
assert.deepEqual(rafWins.state(), {cancelledFrame:null, clearedTimer:22, winner:'raf', draws:1, timerPresent:true});

const timerWins = harness(true);
timerWins.timer();
timerWins.raf();
assert.deepEqual(timerWins.state(), {cancelledFrame:11, clearedTimer:null, winner:'timer', draws:1, timerPresent:true});

const hidden = harness(false);
assert.equal(hidden.state().timerPresent, false);
hidden.raf();
assert.equal(hidden.state().winner, 'raf');

const cancelled = harness(true);
cancelled.cancel();
cancelled.raf(); cancelled.timer();
assert.deepEqual(cancelled.state(), {cancelledFrame:11, clearedTimer:22, winner:null, draws:0, timerPresent:true});

assert.throws(() => scheduleDisplay(() => {}, {maxDelayMs:0, requestFrame:()=>1, cancelFrame:()=>{}, setTimer:()=>2, clearTimer:()=>{}, visible:()=>true}), /invalid display fallback bound/);
console.log(JSON.stringify({status:'pass', rafWins:true, timerWins:true, hiddenNoTimer:true, cancellation:true}));
