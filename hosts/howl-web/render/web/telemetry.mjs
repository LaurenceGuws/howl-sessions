// Bounded client-local flight recorder for browser canaries. Callers pass only
// metadata; raw terminal/input text and error strings are mechanically refused.
const forbiddenDataKeys = new Set(['text', 'value', 'content', 'message', 'label', 'payload']);

export class Telemetry {
  constructor({capacity = 768, now = () => performance.now()} = {}) {
    if (!Number.isInteger(capacity) || capacity < 32 || capacity > 4096) throw new Error('invalid telemetry capacity');
    this.capacity = capacity;
    this.now = now;
    this.started = now();
    this.buffer = new Array(capacity);
    this.head = 0;
    this.size = 0;
    this.sequence = 0;
    this.listeners = new Set();
  }

  get retained() { return this.size; }
  get events() { return this.#ordered(); }

  record(kind, data = {}) {
    for (const key of Object.keys(data)) {
      if (forbiddenDataKeys.has(key)) throw new Error(`telemetry data key ${key} is forbidden`);
    }
    const event = {
      n: ++this.sequence,
      t: Math.round((this.now() - this.started) * 10) / 10,
      k: kind,
      ...data,
    };
    if (this.size < this.capacity) {
      this.buffer[(this.head + this.size) % this.capacity] = event;
      this.size += 1;
    } else {
      this.buffer[this.head] = event;
      this.head = (this.head + 1) % this.capacity;
    }
    for (const listener of this.listeners) listener(event);
    return event;
  }

  clear() {
    this.buffer = new Array(this.capacity);
    this.head = 0;
    this.size = 0;
    this.started = this.now();
    this.sequence = 0;
    this.record('telemetry_clear');
  }

  subscribe(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  export(extra = {}) {
    return {
      schema: 'howl.web-telemetry/v1',
      capacity: this.capacity,
      retained: this.size,
      ...extra,
      events: this.#ordered(),
    };
  }

  compact(extra = {}) { return JSON.stringify(this.export(extra)); }

  summary(extra = {}) {
    const events = this.#ordered();
    const counts = {};
    for (const event of events) counts[event.k] = (counts[event.k] ?? 0) + 1;
    const metric = (kind, key) => summarizeNumbers(events
      .filter(event => event.k === kind && Number.isFinite(event[key]))
      .map(event => event[key]));
    const top = (kind, key, limit = 5) => events
      .filter(event => event.k === kind && Number.isFinite(event[key]))
      .sort((left, right) => right[key] - left[key])
      .slice(0, limit);
    const diagnosticKinds = new Set([
      'viewport_resize', 'viewport_scroll', 'resize_request', 'resize_ack',
      'resize_leader_acquired', 'resize_not_leader', 'lifecycle', 'transport_close',
      'ws_error', 'ws_close', 'reconnect_start', 'reconnect_ready', 'failure',
    ]);
    return {
      schema: 'howl.web-telemetry-summary/v1',
      retained: this.size,
      ...extra,
      counts,
      metrics: {
        render_ms: metric('render', 'ms'),
        canvas_ms: metric('render', 'canvas_ms'),
        upload_ms: metric('render', 'upload_ms'),
        draw_commands_ms: metric('render', 'draw_commands_ms'),
        render_gap_ms: metric('render', 'gap_ms'),
        render_commands: metric('render', 'commands'),
        control_ack_ms: metric('control_ack', 'ms'),
        event_loop_lag_ms: metric('event_loop_lag', 'ms'),
      },
      slow: {
        renders: top('render', 'ms'),
        control_acks: top('control_ack', 'ms'),
        event_loop_lags: top('event_loop_lag', 'ms'),
      },
      incidents: incidentWindows(events),
      recent_edges: events.filter(event => diagnosticKinds.has(event.k)).slice(-24),
    };
  }

  summaryCompact(extra = {}) { return JSON.stringify(this.summary(extra)); }

  visibleLines(limit = 80) {
    return this.#ordered(Math.max(0, Math.min(limit, this.size))).map(event => JSON.stringify(event)).join('\n');
  }

  #ordered(limit = this.size) {
    const count = Math.min(limit, this.size);
    const start = this.size - count;
    const out = new Array(count);
    for (let index = 0; index < count; index++) {
      out[index] = {...this.buffer[(this.head + start + index) % this.capacity]};
    }
    return out;
  }
}

export function startEventLoopProbe(telemetry, {
  intervalMs = 250,
  reportLagMs = 80,
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval,
  now = () => performance.now(),
  isActive = () => true,
} = {}) {
  let expected = now() + intervalMs;
  const reset = () => { expected = now() + intervalMs; };
  const timer = setIntervalFn(() => {
    const current = now();
    if (!isActive()) {
      // Hidden browser tabs deliberately throttle timers. That is platform
      // scheduling policy, not evidence that Howl blocked the event loop.
      expected = current + intervalMs;
      return;
    }
    const lag = current - expected;
    expected = current + intervalMs;
    if (lag >= reportLagMs) telemetry.record('event_loop_lag', {ms:Math.round(lag * 10) / 10});
  }, intervalMs);
  return {
    reset,
    stop:() => clearIntervalFn(timer),
  };
}

function summarizeNumbers(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const p95Index = Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1);
  const sum = sorted.reduce((total, value) => total + value, 0);
  return {
    count: sorted.length,
    mean: Math.round((sum / sorted.length) * 10) / 10,
    p95: sorted[p95Index],
    max: sorted.at(-1),
  };
}


function incidentWindows(events) {
  const candidates = events
    .filter(event => (event.k === 'render' && Number.isFinite(event.ms)) ||
      (event.k === 'event_loop_lag' && Number.isFinite(event.ms)))
    .sort((left, right) => right.ms - left.ms)
    .slice(0, 2);
  return candidates.map(trigger => {
    const index = events.findIndex(event => event.n === trigger.n);
    return {
      trigger:compactIncidentEvent(trigger),
      window:events.slice(Math.max(0, index - 3), index + 4).map(compactIncidentEvent),
    };
  });
}

function compactIncidentEvent(event) {
  const out = {n:event.n, t:event.t, k:event.k};
  for (const key of [
    'ms', 'canvas_ms', 'upload_ms', 'draw_commands_ms', 'gap_ms', 'commands', 'uploads',
    'upload_bytes', 'upload_pixels', 'max_upload_pixels', 'surface_resized',
    'solid_commands', 'alpha_commands', 'image_commands', 'pending', 'kind',
    'source', 'viewport', 'rows', 'columns', 'leader_present', 'owned', 'decision', 'code',
  ]) if (event[key] != null) out[key] = event[key];
  return out;
}
