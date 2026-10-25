import assert from 'node:assert/strict';
import {HistoryViewport} from '../web/history.mjs';

let v = new HistoryViewport(); v.beginGesture();
assert.equal(v.scroll({deltaY:-9,rowHeight:20,historyCount:50,historyRowBase:100,alternateScreen:false}), false);
assert.equal(v.targetOffset,0);
assert.equal(v.scroll({deltaY:-32,rowHeight:20,historyCount:50,historyRowBase:100,alternateScreen:false}), true);
assert.equal(v.targetOffset,2); assert.equal(v.anchorTopRow,148);
assert.equal(v.scroll({deltaY:21,rowHeight:20,historyCount:50,historyRowBase:100,alternateScreen:false}), true);
assert.equal(v.targetOffset,1); assert.equal(v.anchorTopRow,149);

v = new HistoryViewport(); v.beginGesture();
v.scroll({deltaY:-400,rowHeight:20,historyCount:3,historyRowBase:40,alternateScreen:false});
assert.equal(v.targetOffset,3); assert.equal(v.anchorTopRow,40);
v.scroll({deltaY:400,rowHeight:20,historyCount:3,historyRowBase:40,alternateScreen:false});
assert.equal(v.targetOffset,0); assert.equal(v.anchorTopRow,null);
assert.equal(v.scroll({deltaY:-10,rowHeight:20,historyCount:3,historyRowBase:40,alternateScreen:false}), false);

v = new HistoryViewport(); v.acceptSnapshot({historyOffset:10,historyCount:100,historyRowBase:1000,alternateScreen:false});
assert.equal(v.anchorTopRow,1090);
assert.equal(v.followLive({historyCount:101,historyRowBase:1000,alternateScreen:false}), true);
assert.equal(v.targetOffset,11); assert.equal(v.anchorTopRow,1090);

v = new HistoryViewport(); v.acceptSnapshot({historyOffset:10,historyCount:100,historyRowBase:1000,alternateScreen:false});
v.followLive({historyCount:100,historyRowBase:1001,alternateScreen:false});
assert.equal(v.targetOffset,11); assert.equal(v.anchorTopRow,1090);
v.followLive({historyCount:100,historyRowBase:1100,alternateScreen:false});
assert.equal(v.targetOffset,100); assert.equal(v.anchorTopRow,1100);

v = new HistoryViewport(); v.beginGesture();
assert.equal(v.scroll({deltaY:-80,rowHeight:20,historyCount:20,historyRowBase:0,alternateScreen:true}), false);
assert.equal(v.active,false);
assert.equal(v.scroll({deltaY:-80,rowHeight:20,historyCount:0,historyRowBase:0,alternateScreen:false}), false);

v = new HistoryViewport(); v.acceptSnapshot({historyOffset:7,historyCount:7,historyRowBase:20,alternateScreen:false});
assert.equal(v.targetOffset,7); assert.equal(v.anchorTopRow,20);
v.acceptSnapshot({historyOffset:0,historyCount:0,historyRowBase:0,alternateScreen:true});
assert.equal(v.active,false);
console.log(JSON.stringify({status:'pass', anchor:true, clamping:true, rotation:true, alternateScreen:true}));
