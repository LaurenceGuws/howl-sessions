// Browser presentation gate: at most one callback is scheduled, and if several
// complete canonical snapshots arrive before that callback, only the newest is
// painted. Canonical observation remains outside this client-local presentation seam.
export class LatestFrameScheduler {
  constructor({schedule, draw, onError = error => { throw error; }}) {
    if (typeof schedule !== 'function' || typeof draw !== 'function') throw new Error('frame scheduler requires callbacks');
    if (typeof onError !== 'function') throw new Error('frame scheduler error handler must be callable');
    this.schedule = schedule;
    this.draw = draw;
    this.onError = onError;
    this.pending = false;
    this.drawing = false;
    this.latest = null;
    this.cancelScheduled = null;
  }

  push(frame) {
    this.latest = frame;
    if (this.pending || this.drawing) return;
    this.#arm();
  }

  // Hidden browsers may suspend an already-requested animation frame forever.
  // On visible resume, re-arm presentation for the same coalesced newest frame
  // instead of waiting for that stale platform callback to wake up.
  resume() {
    if (!this.pending || this.latest == null) return false;
    this.cancelScheduled?.();
    this.pending = false;
    this.cancelScheduled = null;
    this.#arm();
    return true;
  }

  reset() {
    this.cancelScheduled?.();
    this.pending = false;
    this.cancelScheduled = null;
    this.latest = null;
  }

  #arm() {
    this.pending = true;
    this.cancelScheduled = this.schedule(() => {
      this.pending = false;
      this.cancelScheduled = null;
      const latest = this.latest;
      this.latest = null;
      if (latest == null) return;
      const result = this.draw(latest);
      if (result == null || typeof result.then !== 'function') return;
      this.drawing = true;
      Promise.resolve(result)
        .catch(error => this.onError(error))
        .finally(() => {
          this.drawing = false;
          if (this.latest != null && !this.pending) this.#arm();
        });
    });
  }
}
