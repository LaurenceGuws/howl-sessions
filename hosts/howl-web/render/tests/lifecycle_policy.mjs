import assert from 'node:assert/strict';
import {LifecycleRecoveryPolicy, reconnectAllowed, updateAndPromoteServiceWorker} from '../web/lifecycle_policy.mjs';

const policy = new LifecycleRecoveryPolicy();
assert.equal(policy.decide({visible:true, observerOpen:false, controlOpen:false}), 'boot');
assert.equal(policy.decide({visible:true, observerOpen:true, controlOpen:true}), 'boot');
policy.activate();
assert.equal(policy.decide({visible:false, observerOpen:false, controlOpen:false}), 'hidden');
assert.equal(policy.decide({visible:true, observerOpen:true, controlOpen:true}), 'healthy');
assert.equal(policy.decide({visible:true, observerOpen:false, controlOpen:true}), 'reconnect');
assert.equal(policy.decide({visible:true, observerOpen:true, controlOpen:false}), 'reconnect');
assert.equal(reconnectAllowed('boot'), false);
assert.equal(reconnectAllowed('boot', {manual:true}), true);
assert.equal(reconnectAllowed('hidden', {manual:true}), false);
assert.equal(reconnectAllowed('healthy'), false);
assert.equal(reconnectAllowed('healthy', {manual:true}), true);
assert.equal(reconnectAllowed('reconnect'), true);

class FakeWorker extends EventTarget {
  constructor(state = 'installed') { super(); this.state = state; this.messages = []; }
  postMessage(value) {
    this.messages.push(value);
    this.state = 'activated';
    this.dispatchEvent(new Event('statechange'));
  }
}
const oldWaiting = new FakeWorker();
const newWaiting = new FakeWorker();
const registration = {
  waiting:oldWaiting,
  installing:null,
  async update() { this.waiting = newWaiting; },
};
const promotion = await updateAndPromoteServiceWorker(registration);
assert.deepEqual(promotion, {updated:true, promoted:true});
assert.deepEqual(oldWaiting.messages, ['howl.promote-waiting-v1']);
assert.deepEqual(newWaiting.messages, ['howl.promote-waiting-v1']);
assert.deepEqual(await updateAndPromoteServiceWorker(null), {updated:false, promoted:false});

console.log(JSON.stringify({status:'pass', bootExclusive:true, healthyStable:true, brokenReconnects:true, manualBootRecovery:true, workerPromotion:true}));
