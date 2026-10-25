// Browser lifecycle recovery gate. Initial transport attachment owns boot;
// focus/pageshow/visibility events cannot start a competing attach until boot completes.
export class LifecycleRecoveryPolicy {
  constructor() { this.ready = false; }

  activate() { this.ready = true; }

  decide({visible, observerOpen, controlOpen}) {
    if (!this.ready) return 'boot';
    if (!visible) return 'hidden';
    if (observerOpen && controlOpen) return 'healthy';
    return 'reconnect';
  }
}

/// Manual recovery may complete a boot whose first transport attach failed.
/// Automatic lifecycle recovery remains excluded from boot so it cannot race
/// the initial attach path. A hidden page never starts transport work.
export function reconnectAllowed(decision, {manual = false} = {}) {
  if (decision === 'hidden') return false;
  if (manual) return decision === 'boot' || decision === 'healthy' || decision === 'reconnect';
  return decision === 'reconnect';
}

export async function updateAndPromoteServiceWorker(registration, {
  timeoutMs = 1500,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
} = {}) {
  if (!registration) return {updated:false, promoted:false};
  let promoted = await promoteWorker(registration.waiting, {timeoutMs, setTimer, clearTimer});
  await registration.update();
  const installing = registration.installing;
  if (installing) await waitForWorkerState(installing, state => state !== 'installing', {timeoutMs, setTimer, clearTimer});
  promoted = await promoteWorker(registration.waiting, {timeoutMs, setTimer, clearTimer}) || promoted;
  return {updated:true, promoted};
}

async function promoteWorker(worker, options) {
  if (!worker) return false;
  if (worker.state === 'activated') return true;
  if (worker.state !== 'installed') return false;
  const activated = waitForWorkerState(worker, state => state === 'activated', options);
  worker.postMessage('howl.promote-waiting-v1');
  return activated;
}

function waitForWorkerState(worker, predicate, {timeoutMs, setTimer, clearTimer}) {
  if (predicate(worker.state)) return Promise.resolve(true);
  return new Promise(resolve => {
    let settled = false;
    const finish = value => {
      if (settled) return;
      settled = true;
      worker.removeEventListener('statechange', onState);
      clearTimer(timer);
      resolve(value);
    };
    const onState = () => { if (predicate(worker.state)) finish(true); };
    worker.addEventListener('statechange', onState);
    const timer = setTimer(() => finish(false), timeoutMs);
  });
}
