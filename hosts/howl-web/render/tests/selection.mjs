import assert from 'node:assert/strict';
import {DesktopSelectionController, TerminalSelectionRange, TerminalSelectionViewport, routeDesktopPrimaryPointer, routeDesktopWheel, snappedSelectionRect} from '../web/selection.mjs';

const live = new TerminalSelectionViewport({historyOffset:0,historyCount:30,historyRowBase:100,rows:10,columns:20,alternateScreen:false});
assert.deepEqual(live.pointAt(0, 3), {row:130,column:3});
assert.deepEqual(live.pointAt(9, 19), {row:139,column:19});
const range = new TerminalSelectionRange({anchor:{row:132,column:5},focus:{row:134,column:2},columns:20,alternateScreen:false});
assert.equal(live.validity(range), 'valid');
assert.deepEqual(range.spanFor(live, 2), {row:2,startColumn:5,endColumn:19});
assert.deepEqual(range.spanFor(live, 3), {row:3,startColumn:0,endColumn:19});
assert.deepEqual(range.spanFor(live, 4), {row:4,startColumn:0,endColumn:2});
assert.equal(range.spanFor(live, 1), null);
const history = new TerminalSelectionViewport({historyOffset:8,historyCount:38,historyRowBase:100,rows:10,columns:20,alternateScreen:false});
assert.deepEqual(history.pointAt(0, 0), {row:130,column:0});
assert.equal(history.validity(range), 'valid');
const reversed = new TerminalSelectionRange({anchor:{row:134,column:2},focus:{row:132,column:5},columns:20,alternateScreen:false});
assert.deepEqual(reversed.ordered, range.ordered);
const rotated = new TerminalSelectionViewport({historyOffset:8,historyCount:38,historyRowBase:133,rows:10,columns:20,alternateScreen:false});
assert.equal(rotated.validity(range), 'evicted');
const alternate = new TerminalSelectionViewport({historyOffset:0,historyCount:0,historyRowBase:0,rows:5,columns:20,alternateScreen:true});
assert.deepEqual(alternate.pointAt(2,4), {row:2,column:4});
assert.equal(alternate.validity(new TerminalSelectionRange({anchor:{row:1,column:0},focus:{row:3,column:2},columns:20,alternateScreen:true})), 'valid');

const shaped = new TerminalSelectionViewport({
  historyOffset:0,historyCount:0,historyRowBase:0,rows:4,columns:8,alternateScreen:false,
  selectionRows:[4, 0, 0x8008, 3],
});
const shapedRange = new TerminalSelectionRange({anchor:{row:0,column:2},focus:{row:3,column:6},columns:8,alternateScreen:false});
assert.deepEqual(shapedRange.spanFor(shaped, 0), {row:0,startColumn:2,endColumn:4});
assert.deepEqual(shapedRange.spanFor(shaped, 1), {row:1,startColumn:0,endColumn:0});
assert.deepEqual(shapedRange.spanFor(shaped, 2), {row:2,startColumn:0,endColumn:7});
assert.deepEqual(shapedRange.spanFor(shaped, 3), {row:3,startColumn:0,endColumn:2});
const tailRange = new TerminalSelectionRange({anchor:{row:0,column:7},focus:{row:1,column:3},columns:8,alternateScreen:false});
assert.deepEqual(tailRange.spanFor(shaped, 0), {row:0,startColumn:4,endColumn:4});
assert.equal(tailRange.spanFor(shaped, 1), null);

const firstRect = snappedSelectionRect({left:10,top:70,cellWidth:5.885,rowHeight:11.773,row:20,startColumn:0,endColumn:7,dpr:1.25});
const secondRect = snappedSelectionRect({left:10,top:70,cellWidth:5.885,rowHeight:11.773,row:21,startColumn:0,endColumn:7,dpr:1.25});
assert.equal(firstRect.top + firstRect.height, secondRect.top);
console.log(JSON.stringify({status:'pass', absoluteRows:true, spans:true, textShaped:true, pixelSnapped:true, reversal:true, eviction:true, alternate:true}));

const controller = new DesktopSelectionController();
controller.start({pointer:7,point:{row:10,column:2},columns:20,alternateScreen:false});
assert.equal(controller.finish(7).keep, false);
assert.equal(controller.range, null);
controller.start({pointer:9,point:{row:10,column:2},columns:20,alternateScreen:true});
assert.equal(controller.update(8,{row:11,column:3}), null);
assert.deepEqual(controller.update(9,{row:11,column:3}).focus,{row:11,column:3});
assert.equal(controller.finish(9).keep, true);
assert.deepEqual(controller.range.focus,{row:11,column:3});
controller.clear();
assert.equal(controller.range, null);

assert.equal(routeDesktopPrimaryPointer({historyActive:true,forceSelection:false,mouseTrackingEnabled:true}), 'local_selection');
assert.equal(routeDesktopPrimaryPointer({historyActive:false,forceSelection:true,mouseTrackingEnabled:true}), 'local_selection');
assert.equal(routeDesktopPrimaryPointer({historyActive:false,forceSelection:false,mouseTrackingEnabled:null}), 'interaction_state');
assert.equal(routeDesktopPrimaryPointer({historyActive:false,forceSelection:false,mouseTrackingEnabled:true}), 'terminal_mouse');
assert.equal(routeDesktopPrimaryPointer({historyActive:false,forceSelection:false,mouseTrackingEnabled:false}), 'local_selection');
assert.equal(routeDesktopWheel({historyActive:true,mouseTrackingEnabled:true,alternateScreen:true,alternateScroll:true}), 'history');
assert.equal(routeDesktopWheel({historyActive:false,mouseTrackingEnabled:null,alternateScreen:false,alternateScroll:null}), 'interaction_state');
assert.equal(routeDesktopWheel({historyActive:false,mouseTrackingEnabled:true,alternateScreen:true,alternateScroll:false}), 'terminal_mouse');
assert.equal(routeDesktopWheel({historyActive:false,mouseTrackingEnabled:false,alternateScreen:false,alternateScroll:false}), 'history');
assert.equal(routeDesktopWheel({historyActive:false,mouseTrackingEnabled:false,alternateScreen:true,alternateScroll:true}), 'alternate_scroll');
assert.equal(routeDesktopWheel({historyActive:false,mouseTrackingEnabled:false,alternateScreen:true,alternateScroll:false}), 'ignore');
