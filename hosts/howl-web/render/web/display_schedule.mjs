// Visible-page display scheduler. Prefer requestAnimationFrame, but if a mobile
// browser delays it beyond maxDelayMs, one timer may present the newest frame.
// The first callback wins and cancels the other; callers still own frame coalescing.
export function scheduleDisplay(callback, {
  requestFrame = requestAnimationFrame,
  cancelFrame = cancelAnimationFrame,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  visible = () => document.visibilityState === 'visible',
  maxDelayMs = 50,
  onWinner = () => {},
} = {}) {
  if (typeof callback !== 'function') throw new Error('display callback required');
  if (!Number.isFinite(maxDelayMs) || maxDelayMs < 1 || maxDelayMs > 1000) throw new Error('invalid display fallback bound');
  let done = false;
  let frameId = null;
  let timerId = null;
  const finish = source => {
    if (done) return;
    done = true;
    if (frameId != null && source !== 'raf') cancelFrame(frameId);
    if (timerId != null && source !== 'timer') clearTimer(timerId);
    onWinner(source);
    callback();
  };
  frameId = requestFrame(() => finish('raf'));
  if (visible()) timerId = setTimer(() => finish('timer'), maxDelayMs);
  return () => {
    if (done) return;
    done = true;
    if (frameId != null) cancelFrame(frameId);
    if (timerId != null) clearTimer(timerId);
  };
}
