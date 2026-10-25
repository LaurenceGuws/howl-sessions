import {MouseButton, MouseKind} from './input.mjs';

export class TerminalPointerGeometry {
  constructor({left, top, width, height, surfaceWidth, surfaceHeight, cellWidth, cellHeight}) {
    Object.assign(this, {left, top, width, height, surfaceWidth, surfaceHeight, cellWidth, cellHeight});
  }

  locate({clientX, clientY}) {
    const {left, top, width, height, surfaceWidth, surfaceHeight, cellWidth, cellHeight} = this;
    if (![left, top, width, height, surfaceWidth, surfaceHeight, cellWidth, cellHeight].every(Number.isFinite) ||
        width <= 0 || height <= 0 || surfaceWidth <= 0 || surfaceHeight <= 0 || cellWidth <= 0 || cellHeight <= 0 ||
        surfaceWidth % cellWidth !== 0 || surfaceHeight % cellHeight !== 0) return null;
    const cssX = clientX - left, cssY = clientY - top;
    if (cssX < 0 || cssY < 0 || cssX >= width || cssY >= height) return null;
    const pixelX = Math.floor(cssX * surfaceWidth / width);
    const pixelY = Math.floor(cssY * surfaceHeight / height);
    if (pixelX < 0 || pixelY < 0 || pixelX >= surfaceWidth || pixelY >= surfaceHeight) return null;
    return {
      row:Math.floor(pixelY / cellHeight), column:Math.floor(pixelX / cellWidth),
      pixelX, pixelY,
    };
  }
}

export class TerminalPointerAdapter {
  constructor() { this.states = new Map(); }
  clear() { this.states.clear(); }

  translate(event, {geometry, modifiers = 0}) {
    if (!supportedPointerType(event.pointerType) || !geometry) return [];
    const pointerId = event.pointerId ?? 0;
    const previous = this.states.get(pointerId);
    const mapped = geometry.locate(event);
    const location = mapped ?? previous?.location;
    const current = howlButtons(event.buttons ?? 0);
    const before = previous?.buttons ?? 0;

    if (event.type === 'pointercancel') {
      this.states.delete(pointerId);
      return location == null ? [] : releaseTransitions(before, 0, location, modifiers);
    }

    if (mapped != null || previous != null) {
      if (current === 0 && event.type === 'pointerup') this.states.delete(pointerId);
      else this.states.set(pointerId, {buttons:current, location:mapped ?? previous.location});
    }
    if (location == null) return [];
    if (event.type === 'pointerdown') return pressTransitions(before, current, location, modifiers);
    if (event.type === 'pointerup') return releaseTransitions(before, current, location, modifiers);
    if (event.type === 'pointermove') return mapped == null ? [] : [mouseInput(MouseKind.move, MouseButton.none, current, location, modifiers)];
    return [];
  }

  wheel(event, {geometry, modifiers = 0}) {
    if (!geometry || !Number.isFinite(event.deltaY) || event.deltaY === 0) return null;
    const location = geometry.locate(event);
    if (location == null) return null;
    return mouseInput(
      MouseKind.wheel,
      event.deltaY < 0 ? MouseButton.wheelUp : MouseButton.wheelDown,
      0,
      location,
      modifiers,
    );
  }
}

// One mouse move may be on the wire while one newer move is retained locally.
// Button transitions stay outside this scheduler as ordered control barriers.
export class LatestPointerMoveScheduler {
  constructor({send, onError = () => {}}) {
    if (typeof send !== 'function') throw new Error('pointer move scheduler requires send');
    this.send = send; this.onError = onError; this.latest = null; this.running = false;
  }
  push(input) { this.latest = input; if (!this.running) void this.#drain(); }
  clear() { this.latest = null; }
  async #drain() {
    this.running = true;
    try {
      while (this.latest != null) {
        const input = this.latest; this.latest = null;
        await this.send(input);
      }
    } catch (error) {
      this.latest = null;
      this.onError(error);
    } finally {
      this.running = false;
      if (this.latest != null) void this.#drain();
    }
  }
}

function supportedPointerType(value) { return value === 'mouse' || value === 'pen'; }
function howlButtons(value) {
  let out = 0;
  if (value & 1) out |= 1; // DOM primary -> Howl left.
  if (value & 4) out |= 2; // DOM auxiliary -> Howl middle.
  if (value & 2) out |= 4; // DOM secondary -> Howl right.
  return out;
}
function buttonForBit(bit) { return bit === 1 ? MouseButton.left : bit === 2 ? MouseButton.middle : bit === 4 ? MouseButton.right : MouseButton.none; }
function mouseInput(kind, button, buttonsDown, location, modifiers) { return {kind, button, buttonsDown, modifiers, ...location}; }
function pressTransitions(before, after, location, modifiers) {
  const changed = after & ~before, out = []; let held = before;
  for (const bit of [1,2,4]) if (changed & bit) { held |= bit; out.push(mouseInput(MouseKind.press, buttonForBit(bit), held, location, modifiers)); }
  return out;
}
function releaseTransitions(before, after, location, modifiers) {
  const changed = before & ~after, out = []; let held = before;
  for (const bit of [1,2,4]) if (changed & bit) { held &= ~bit; out.push(mouseInput(MouseKind.release, buttonForBit(bit), held, location, modifiers)); }
  return out;
}
