import assert from 'node:assert/strict';
import {Telemetry, startEventLoopProbe} from '../web/telemetry.mjs';

let now = 1000;
const telemetry = new Telemetry({capacity:32, now:() => now});
telemetry.record('input', {bytes:1});
now += 12.34;
telemetry.record('queue', {pending:2});
assert.equal(telemetry.events.length, 2);
assert.equal(telemetry.events[1].t, 12.3);
for (let index = 0; index < 40; index++) { now += 1; telemetry.record('burst', {index}); }
assert.equal(telemetry.events.length, 32);
assert.equal(telemetry.events[0].index, 8);
assert.equal(telemetry.events.at(-1).index, 39);
const exported = telemetry.export({version:'test'});
assert.equal(exported.schema, 'howl.web-telemetry/v1');
assert.equal(exported.capacity, 32);
assert.equal(exported.retained, 32);
assert.equal(exported.version, 'test');
assert.throws(() => telemetry.record('bad', {text:'secret terminal text'}), /forbidden/);
assert.throws(() => telemetry.record('bad', {message:'secret error text'}), /forbidden/);
assert.ok(!telemetry.compact().includes('secret terminal text'));
telemetry.record('render', {ms:5, canvas_ms:2, upload_ms:0, draw_commands_ms:2, gap_ms:40, commands:20});
telemetry.record('render', {ms:50, canvas_ms:45, upload_ms:40, draw_commands_ms:5, gap_ms:200, commands:200});
telemetry.record('control_ack', {ms:30, kind:'text'});
telemetry.record('event_loop_lag', {ms:120});
telemetry.record('viewport_resize', {source:'visual', viewport:[390, 420]});
const summary = telemetry.summary({context:{display_mode:'standalone'}});
assert.equal(summary.schema, 'howl.web-telemetry-summary/v1');
assert.equal(summary.metrics.render_ms.max, 50);
assert.equal(summary.metrics.canvas_ms.p95, 45);
assert.equal(summary.metrics.upload_ms.max, 40);
assert.equal(summary.metrics.draw_commands_ms.max, 5);
assert.equal(summary.slow.renders[0].ms, 50);
assert.equal(summary.incidents.length, 2);
assert.ok(summary.incidents[0].window.some(event => event.n === summary.incidents[0].trigger.n));
assert.equal(summary.recent_edges.at(-1).k, 'viewport_resize');
const dense = new Telemetry({capacity:768, now:() => now});
for (let index = 0; index < 768; index++) {
  now += 1;
  dense.record(index % 17 === 0 ? 'render' : 'input_event', index % 17 === 0
    ? {ms:index % 91, canvas_ms:index % 83, upload_ms:index % 23, draw_commands_ms:index % 61, commands:200 + index % 50}
    : {input_type:'insertText', composing:false, editor_bytes:1});
}
assert.ok(dense.summaryCompact().length < dense.compact().length / 4);
assert.ok(dense.summaryCompact().length < 20000);

let scheduled;
let cleared = false;
let clock = 0;
let active = true;
const probe = new Telemetry({capacity:32, now:() => clock});
const eventLoopProbe = startEventLoopProbe(probe, {
  intervalMs:250,
  reportLagMs:80,
  now:() => clock,
  isActive:() => active,
  setIntervalFn:callback => { scheduled = callback; return 7; },
  clearIntervalFn:id => { assert.equal(id, 7); cleared = true; },
});
clock = 400; scheduled();
assert.equal(probe.events.at(-1).k, 'event_loop_lag');
assert.equal(probe.events.at(-1).ms, 150);
const beforeHidden = probe.retained;
active = false; clock = 1400; scheduled();
assert.equal(probe.retained, beforeHidden);
active = true; clock = 1650; scheduled();
assert.equal(probe.retained, beforeHidden);
clock = 5000;
eventLoopProbe.reset();
clock = 5250; scheduled();
assert.equal(probe.retained, beforeHidden);
eventLoopProbe.stop(); assert.equal(cleared, true);
telemetry.clear();
assert.equal(telemetry.retained, 1);
assert.equal(telemetry.events[0].k, 'telemetry_clear');
console.log(JSON.stringify({status:'pass', boundedRing:true, exportSchema:true, summarySchema:true, rawTextRefused:true, eventLoopLag:true, hiddenTimerSuppressed:true, lifecycleReset:true, clear:true}));
