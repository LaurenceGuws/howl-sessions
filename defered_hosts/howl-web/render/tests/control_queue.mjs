import assert from 'node:assert/strict';
import {ControlQueue} from '../web/control_queue.mjs';

const log = [];
let releaseFirst;
const firstGate = new Promise(resolve => { releaseFirst = resolve; });
const queue = new ControlQueue({maximumPending:8, maximumTextBytes:8, onError:error => log.push(`error:${error.message}`)});

const first = queue.operation(async () => { log.push('first:start'); await firstGate; log.push('first:end'); });
queue.text('a', 1, async value => { log.push(`text:${value}`); });
queue.text('b', 1, async value => { log.push(`text:${value}`); });
queue.text('é', 2, async value => { log.push(`text:${value}`); });
queue.operation(async () => { log.push('backspace'); });
queue.text('c', 1, async value => { log.push(`text:${value}`); });
queue.text('d', 1, async value => { log.push(`text:${value}`); });
assert.equal(queue.pending, 4);
releaseFirst();
await first;
await queue.tail;
assert.deepEqual(log, ['first:start','first:end','text:abé','backspace','text:cd']);
assert.equal(queue.pending, 0);

const returnQueue = new ControlQueue();
assert.equal(await returnQueue.operation(async () => 17), 17);

const chunks = [];
let releaseChunkGate;
const chunkGate = new Promise(resolve => { releaseChunkGate = resolve; });
const chunkQueue = new ControlQueue({maximumPending:8, maximumTextBytes:4});
chunkQueue.operation(async () => { await chunkGate; });
chunkQueue.text('ab', 2, async value => chunks.push(value));
chunkQueue.text('cd', 2, async value => chunks.push(value));
chunkQueue.text('e', 1, async value => chunks.push(value));
assert.equal(chunkQueue.pending, 3);
releaseChunkGate();
await chunkQueue.tail;
assert.deepEqual(chunks, ['abcd','e']);

const burst = [];
let releaseBurst;
const burstGate = new Promise(resolve => { releaseBurst = resolve; });
const burstQueue = new ControlQueue({maximumPending:256, maximumTextBytes:4096});
burstQueue.operation(async () => { await burstGate; });
for (let index = 0; index < 1000; index += 1) {
  burstQueue.text('x', 1, async value => burst.push(value));
}
assert.equal(burstQueue.pending, 2); // one in flight plus one coalesced text request
releaseBurst();
await burstQueue.tail;
assert.equal(burst.length, 1);
assert.equal(burst[0].length, 1000);

const errors = [];
let releaseBound;
const boundGate = new Promise(resolve => { releaseBound = resolve; });
const bounded = new ControlQueue({maximumPending:2, onError:error => errors.push(error.message)});
bounded.operation(async () => { await boundGate; });
bounded.operation(async () => {});
await assert.rejects(bounded.operation(async () => {}), /exceeds 2 pending operations/);
assert.deepEqual(errors, ['control queue exceeds 2 pending operations']);
releaseBound();
await bounded.tail;
assert.equal(bounded.pending, 0);

console.log(JSON.stringify({status:'pass', coalescing:true, barriers:true, returnValue:true, utf8Bytes:true, chunkBound:true, queueBound:true, burst1000:true}));
