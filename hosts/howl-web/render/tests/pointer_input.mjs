import assert from 'node:assert/strict';
import {TerminalPointerAdapter, TerminalPointerGeometry, LatestPointerMoveScheduler} from '../web/pointer_input.mjs';

const geometry = new TerminalPointerGeometry({left:100, top:50, width:400, height:200, surfaceWidth:800, surfaceHeight:400, cellWidth:10, cellHeight:20});
assert.deepEqual(geometry.locate({clientX:302.5, clientY:155}), {row:10,column:40,pixelX:405,pixelY:210});
assert.equal(geometry.locate({clientX:99, clientY:155}), null);
assert.equal(new TerminalPointerGeometry({left:0,top:0,width:10,height:10,surfaceWidth:11,surfaceHeight:20,cellWidth:10,cellHeight:20}).locate({clientX:1,clientY:1}), null);

const adapter = new TerminalPointerAdapter();
const press = adapter.translate({type:'pointerdown',pointerId:7,pointerType:'mouse',clientX:302.5,clientY:155,buttons:2}, {geometry,modifiers:5});
assert.deepEqual(press, [{kind:1,button:3,buttonsDown:4,modifiers:5,row:10,column:40,pixelX:405,pixelY:210}]);
const move = adapter.translate({type:'pointermove',pointerId:7,pointerType:'mouse',clientX:307.5,clientY:165,buttons:2}, {geometry,modifiers:0});
assert.equal(move[0].kind,3); assert.equal(move[0].buttonsDown,4); assert.equal(move[0].row,11); assert.equal(move[0].column,41);
const release = adapter.translate({type:'pointerup',pointerId:7,pointerType:'mouse',clientX:900,clientY:900,buttons:0}, {geometry,modifiers:0});
assert.equal(release[0].kind,2); assert.equal(release[0].button,3); assert.equal(release[0].row,11); assert.equal(release[0].column,41);
assert.deepEqual(adapter.translate({type:'pointerdown',pointerId:8,pointerType:'touch',clientX:302.5,clientY:155,buttons:1},{geometry}), []);
const wheelUp = adapter.wheel({clientX:302.5, clientY:155, deltaY:-53}, {geometry, modifiers:4});
assert.deepEqual(wheelUp, {kind:4,button:4,buttonsDown:0,modifiers:4,row:10,column:40,pixelX:405,pixelY:210});
const wheelDown = adapter.wheel({clientX:302.5, clientY:155, deltaY:53}, {geometry, modifiers:0});
assert.equal(wheelDown.kind,4); assert.equal(wheelDown.button,5);
assert.equal(adapter.wheel({clientX:99, clientY:155, deltaY:-53}, {geometry}), null);
assert.equal(adapter.wheel({clientX:302.5, clientY:155, deltaY:0}, {geometry}), null);

const sent = []; let releaseFirst;
const firstGate = new Promise(resolve => { releaseFirst = resolve; });
const scheduler = new LatestPointerMoveScheduler({send:async input => { sent.push(input); if (sent.length===1) await firstGate; }});
scheduler.push({n:1}); scheduler.push({n:2}); scheduler.push({n:3});
assert.equal(scheduler.running,true); releaseFirst();
while (scheduler.running) await new Promise(resolve=>setTimeout(resolve,0));
assert.deepEqual(sent,[{n:1},{n:3}]);

console.log(JSON.stringify({status:'pass',scaledGeometry:true,mouseButtons:true,wheel:true,touchLocal:true,latestMoveWins:true}));
