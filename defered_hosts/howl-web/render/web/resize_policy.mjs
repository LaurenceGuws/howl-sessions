// Client-local geometry ownership policy. The Instance remains the authority:
// Web only remembers whether its current control connection successfully claimed
// that authority, and followers never steal it merely because their viewport differs.
export class ResizePolicy {
  constructor() {
    this.controlId = null;
  }

  reset() {
    this.controlId = null;
  }

  owns(controlId) {
    return controlId != null && this.controlId === String(controlId);
  }

  decide({leaderPresent, controlId}) {
    if (controlId == null) return 'wait';
    if (this.owns(controlId)) return 'resize';
    return leaderPresent ? 'follow' : 'claim';
  }

  accepted(controlId) {
    if (controlId == null) throw new Error('resize ownership requires control identity');
    this.controlId = String(controlId);
  }

  rejected(controlId) {
    if (this.owns(controlId)) this.controlId = null;
  }

  settle({decision, controlId, code}) {
    if (code === 0) {
      if (decision === 'claim') this.accepted(controlId);
      return 'ok';
    }
    if (code === 4) {
      this.rejected(controlId);
      return 'not_leader';
    }
    return 'error';
  }
}
