export class HistoryViewport {
  constructor() {
    this.targetOffset = 0;
    this.anchorTopRow = null;
    this.remainderPixels = 0;
  }
  get active() { return this.targetOffset !== 0; }
  beginGesture() { this.remainderPixels = 0; }
  endGesture() { this.remainderPixels = 0; }
  scroll({deltaY, rowHeight, historyCount, historyRowBase, alternateScreen}) {
    if (!Number.isFinite(rowHeight) || rowHeight <= 0) throw new RangeError('rowHeight');
    if (!Number.isInteger(historyCount) || historyCount < 0 ||
        !Number.isInteger(historyRowBase) || historyRowBase < 0) throw new RangeError('history counters');
    if (alternateScreen || historyCount === 0) { this.remainderPixels = 0; return false; }
    this.remainderPixels -= deltaY;
    const rows = Math.trunc(this.remainderPixels / rowHeight);
    if (rows === 0) return false;
    this.remainderPixels -= rows * rowHeight;
    const requested = this.targetOffset + rows;
    const clamped = Math.max(0, Math.min(historyCount, requested));
    if (clamped !== requested) this.remainderPixels = 0;
    if (clamped === this.targetOffset) return false;
    this.targetOffset = clamped;
    this.anchorTopRow = clamped === 0 ? null : historyRowBase + historyCount - clamped;
    return true;
  }
  followLive({historyCount, historyRowBase, alternateScreen}) {
    if (!Number.isInteger(historyCount) || historyCount < 0 ||
        !Number.isInteger(historyRowBase) || historyRowBase < 0) throw new RangeError('history counters');
    if (!this.active) return false;
    if (alternateScreen || historyCount === 0) return this.reset();
    const anchor = this.anchorTopRow;
    if (anchor == null) return this.reset();
    const end = historyRowBase + historyCount;
    const requested = end - anchor;
    const clamped = Math.max(0, Math.min(historyCount, requested));
    if (clamped === 0) return this.reset();
    const changed = clamped !== this.targetOffset;
    this.targetOffset = clamped;
    if (clamped !== requested) this.anchorTopRow = end - clamped;
    return changed;
  }
  acceptSnapshot({historyOffset, historyCount, historyRowBase, alternateScreen}) {
    for (const value of [historyOffset, historyCount, historyRowBase])
      if (!Number.isInteger(value) || value < 0) throw new RangeError('history counters');
    if (alternateScreen || historyOffset === 0 || historyCount === 0) { this.reset(); return; }
    this.targetOffset = Math.max(0, Math.min(historyCount, historyOffset));
    this.anchorTopRow = this.targetOffset === 0 ? null : historyRowBase + historyCount - this.targetOffset;
  }
  reset() {
    const changed = this.active || this.anchorTopRow != null || this.remainderPixels !== 0;
    this.targetOffset = 0; this.anchorTopRow = null; this.remainderPixels = 0;
    return changed;
  }
}
