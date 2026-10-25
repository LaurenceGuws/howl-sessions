import {assertTextImports, createTextRuntime} from './runtime.mjs';
import {
  TerminalInputStager, guardText, namedKeyForCode, NamedKey, KeyAction,
  Modifier, MouseKind, modifierBits, singleScalar, focusKeyboardCapture,
} from './input.mjs';
import {TerminalPointerAdapter, TerminalPointerGeometry, LatestPointerMoveScheduler} from './pointer_input.mjs';
import {HistoryViewport} from './history.mjs';
import {DesktopSelectionController, TerminalSelectionOverlay, TerminalSelectionViewport, routeDesktopPrimaryPointer, routeDesktopWheel} from './selection.mjs';
import {ControlQueue} from './control_queue.mjs';
import {Telemetry, startEventLoopProbe} from './telemetry.mjs';
import {LatestFrameScheduler} from './frame_scheduler.mjs';
import {scheduleDisplay} from './display_schedule.mjs';
import {ResizePolicy} from './resize_policy.mjs';
import {LifecycleRecoveryPolicy, reconnectAllowed, updateAndPromoteServiceWorker} from './lifecycle_policy.mjs';
import {parseRendererFrameV4, qualifiedKeyV4 as resourceKey, selectRendererFrameV4} from './frame_v4.mjs';
import {WebGLTerminalBackend, clippedSprite} from './webgl_backend_v4.mjs';

const CANARY_GENERATION = 'v45-web-frame-v4';
const MAX_EXTERNAL_IMAGE_RESOURCES = 7;
const MAX_RENDER_ATTEMPTS = MAX_EXTERNAL_IMAGE_RESOURCES + 1;
const main = document.querySelector('main');
const status = document.querySelector('#status');
const factsNode = document.querySelector('#facts');
const terminal = document.querySelector('#terminal');
const selectionOverlay = document.querySelector('#selection-overlay');
const desktopSelection = new DesktopSelectionController();
const selectionOverlayView = new TerminalSelectionOverlay({element:selectionOverlay, terminal});
const toolbar = document.querySelector('#toolbar');
const keyboard = document.querySelector('#keyboard');
const keyboardButton = document.querySelector('#keyboard-button');
const zoomButton = document.querySelector('#zoom-button');
const leaderButton = document.querySelector('#leader-button');
const copyButton = document.querySelector('#copy-button');
const pasteButton = document.querySelector('#paste-button');
const reconnect = document.querySelector('#reconnect');
const reload = document.querySelector('#reload');
const telemetryPanel = document.querySelector('#telemetry-panel');
const telemetryLog = document.querySelector('#telemetry-log');
const telemetrySummaryCopy = document.querySelector('#telemetry-summary-copy');
const telemetryCopy = document.querySelector('#telemetry-copy');
const telemetryClear = document.querySelector('#telemetry-clear');
const decoder = new TextDecoder();
const encoder = new TextEncoder();
const resources = new Map();
const context = terminal.getContext('2d', {alpha: false});
const alphaScratch = document.createElement('canvas');
const alphaScratchContext = alphaScratch.getContext('2d');
const alphaSpritePixelBudget = 1024 * 1024;
const glyphCoverageLut = Uint8Array.from({length:256}, (_, value) => {
  const linear = value / 255;
  const encoded = linear <= 0.0031308
    ? linear * 12.92
    : 1.055 * Math.pow(linear, 1 / 2.4) - 0.055;
  const corrected = encoded * 255;
  return Math.round(value + (corrected - value) * 0.5);
});
const stager = new TerminalInputStager();
const modifiedKeys = new Map();
const presentationPixels = [16, 12, 9];
const presentationCellWidths = [10, 8, 6];
const presentationLineHeights = [20, 15, 12];
const rasterScale = Math.max(1, Math.min(4, Math.ceil(devicePixelRatio || 1)));
let presentationIndex = 0;
let presentationChanging = false;
let renderAssets = null;
context.imageSmoothingEnabled = false;

let wireModule;
let renderer;
let observer;
let historyObserver;
let control;
let imageConnection;
let previousObserverId = null;
let lastFrame = null;
let latestLiveSnapshot = null;
let latestLiveClientId = null;
let latestLiveHistory = null;
let displayedHistory = null;
let pointerDecisionPointer = null;
const history = new HistoryViewport();
let historyGeneration = 0;
let historyRequestRunning = false;
let historyRequestPending = false;
let historyWheelTimer = null;
let lastInput = '';
const telemetry = new Telemetry({capacity:768});
let webglBackend = null;
let webglBackendFailure = null;
try {
  webglBackend = new WebGLTerminalBackend({glyphCoverageLut});
} catch (error) {
  webglBackendFailure = error instanceof Error ? error.message : String(error);
}
const liveFrameScheduler = new LatestFrameScheduler({
  schedule:callback => scheduleDisplay(callback, {onWinner:source => telemetry.record('frame_tick', {source})}),
  draw:frame => history.active || presentationChanging
    ? null
    : renderSnapshotBytes(
      frame.snapshot,
      frame.clientId,
      'live',
      () => !history.active && latestLiveSnapshot === frame.snapshot &&
        String(observer?.clientId ?? '') === String(frame.clientId),
      frame.history,
    ),
  onError:fail,
});
const resizePolicy = new ResizePolicy();
const lifecyclePolicy = new LifecycleRecoveryPolicy();
const controlQueue = new ControlQueue({
  maximumPending:256, maximumTextBytes:4096, onError:fail,
  onEvent:(kind, data) => telemetry.record(`queue_${kind}`, data),
});
const terminalPointer = new TerminalPointerAdapter();
const pointerMoveScheduler = new LatestPointerMoveScheduler({
  send:input => queueControl(connection => connection.mouse(input), 'mouse_move'),
  onError:fail,
});
let lastRenderTelemetryAt = null;
let telemetryUiTimer = null;
let modifierLatch = 0;
let compositionActive = false;
let focusState = null;
let resizeTimer = null;
let requestedGeometry = null;
let reconnectTask = null;
let lifecycleGeneration = 0;
let interactionStateCache = null;
let interactionStateCachedAt = 0;
const interactionStateFreshMs = 120;

const errorText = exports => decoder.decode(new Uint8Array(
  exports.memory.buffer, exports.hw_error_ptr?.() ?? exports.rv_error_ptr(),
  exports.hw_error_len?.() ?? exports.rv_error_len()));
const bytesAt = (memory, pointer, length) => new Uint8Array(memory.buffer, Number(pointer), Number(length));
const rgba = color => `rgba(${color[0]},${color[1]},${color[2]},${color[3] / 255})`;
const rgbaValues = (r, g, b, a) => `rgba(${r},${g},${b},${a / 255})`;
const clamp = (value, low, high) => Math.max(low, Math.min(high, value));

function telemetryContext() {
  return {
    generation: CANARY_GENERATION,
    presentation_pixels:presentationPixels[presentationIndex],
    raster_scale:rasterScale,
    display_mode: matchMedia('(display-mode: standalone)').matches ? 'standalone' : 'browser',
    visibility: document.visibilityState,
    focused: document.hasFocus(),
    viewport: [Math.round(window.visualViewport?.width ?? innerWidth), Math.round(window.visualViewport?.height ?? innerHeight)],
    dpr: devicePixelRatio,
    observer_client: observer?.clientId ? String(observer.clientId) : null,
    control_client: control?.clientId ? String(control.clientId) : null,
    image_client: imageConnection?.clientId ? String(imageConnection.clientId) : null,
  };
}

function renderTelemetryLog() {
  if (!telemetryLog || !telemetryPanel?.open) return;
  telemetryLog.textContent = telemetry.visibleLines(80);
  telemetryLog.scrollTop = telemetryLog.scrollHeight;
}
function scheduleTelemetryLog() {
  if (!telemetryPanel?.open || telemetryUiTimer != null) return;
  telemetryUiTimer = setTimeout(() => { telemetryUiTimer = null; renderTelemetryLog(); }, 120);
}
telemetry.subscribe(scheduleTelemetryLog);
const eventLoopProbe = startEventLoopProbe(telemetry, {isActive:() => document.visibilityState === 'visible'});
telemetry.record('boot', telemetryContext());

async function fetchBytes(path) {
  const response = await fetch(path, {cache: 'no-store'});
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return new Uint8Array(await response.arrayBuffer());
}

function initializeRendererPresentation(target, fontPixels, cellWidth, lineHeight) {
  if (!renderAssets) throw new Error('renderer assets are not loaded');
  const {font, fallbackFont, nerdFont} = renderAssets;
  if (font.length > target.exports.rv_font_capacity()) throw new Error('font exceeds renderer input bound');
  if (fallbackFont.length > target.exports.rv_fallback_font_capacity()) throw new Error('fallback font exceeds renderer input bound');
  if (nerdFont.length > target.exports.rv_symbol_font_capacity()) throw new Error('Nerd symbol font exceeds renderer input bound');
  bytesAt(target.exports.memory, target.exports.rv_font_ptr(), font.length).set(font);
  bytesAt(target.exports.memory, target.exports.rv_fallback_font_ptr(), fallbackFont.length).set(fallbackFont);
  bytesAt(target.exports.memory, target.exports.rv_symbol_font_ptr(), nerdFont.length).set(nerdFont);
  if (target.exports.rv_init_presentation(
    font.length, fallbackFont.length, nerdFont.length,
    fontPixels * rasterScale, cellWidth * rasterScale, lineHeight * rasterScale,
  ) !== 1)
    throw new Error(errorText(target.exports) || 'renderer init failed');
}

async function instantiateRenderer(fontPixels, cellWidth, lineHeight) {
  if (!renderAssets) throw new Error('renderer assets are not loaded');
  const {module, byteLength} = renderAssets;
  const runtime = createTextRuntime({output:()=>{}});
  const instance = await WebAssembly.instantiate(module, runtime.imports);
  runtime.bind(instance.exports.memory);
  instance.exports._initialize?.();
  const candidate = {exports:instance.exports, runtime, bytes:byteLength};
  initializeRendererPresentation(candidate, fontPixels, cellWidth, lineHeight);
  selectRendererFrameV4(candidate.exports);
  return candidate;
}

async function load() {
  const [wireBytes, renderBytes, font, fallbackFont, nerdFont] = await Promise.all([
    fetchBytes('/wire.wasm'), fetchBytes('render.wasm'), fetchBytes('font.bin'), fetchBytes('fallback-font.bin'), fetchBytes('nerd-font.bin'),
  ]);
  wireModule = await WebAssembly.compile(wireBytes);
  if (WebAssembly.Module.imports(wireModule).length !== 0) throw new Error('wire module gained host imports');
  const renderModule = await WebAssembly.compile(renderBytes);
  assertTextImports(renderModule);
  renderAssets = {module:renderModule, byteLength:renderBytes.length, font, fallbackFont, nerdFont};
  renderer = await instantiateRenderer(
    presentationPixels[presentationIndex],
    presentationCellWidths[presentationIndex],
    presentationLineHeights[presentationIndex],
  );
  observer = await WireConnection.connect('observer');
  control = await WireConnection.connect('control');
  resetEditor();
  lifecyclePolicy.activate();
  syncFocus();
  updateFacts();
  handleLifecycle();
}

class WireConnection {
  static async connect(role) {
    const instance = await WebAssembly.instantiate(wireModule);
    const connection = new WireConnection(role, instance.exports);
    await connection.open();
    return connection;
  }
  constructor(role, exports) {
    this.role = role;
    this.exports = exports;
    this.socket = null;
    this.clientId = null;
    this.closed = false;
  }
  async open() {
    const started = performance.now();
    telemetry.record('ws_connect_start', {role:this.role});
    if (this.exports.hw_reset() !== 1) throw new Error(`${this.role}: reset failed`);
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    this.socket = new WebSocket(`${scheme}//${location.host}/socket`);
    this.socket.binaryType = 'arraybuffer';
    this.socket.onmessage = event => this.onMessage(event).catch(fail);
    this.socket.onerror = () => {
      if (!this.closed) { telemetry.record('ws_error', {role:this.role}); fail(new Error(`${this.role}: websocket error`)); }
    };
    this.socket.onclose = () => {
      const unexpected = !this.closed;
      this.closed = true;
      telemetry.record('ws_close', {role:this.role, unexpected});
      updateFacts();
      if (unexpected) handleTransportClose(this.role);
    };
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`${this.role}: open timeout`)), 5000);
      this.socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, {once:true});
      this.socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error(`${this.role}: open error`)); }, {once:true});
    });
    // The gateway sends attachment-ready first; reset has no outgoing hello.
    await this.waitForPhase(2);
    this.clientId = this.exports.hw_identity();
    telemetry.record('ws_ready', {role:this.role, ms:Math.round((performance.now() - started) * 10) / 10});
    if (this.role === 'observer') this.observe(true, 0);
  }
  sendOutput() {
    const length = Number(this.exports.hw_output_len());
    if (length === 0) throw new Error(`${this.role}: empty outgoing frame`);
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error(`${this.role}: websocket is not open`);
    this.socket.send(bytesAt(this.exports.memory, this.exports.hw_output_ptr(), length).slice());
  }
  async onMessage(event) {
    const data = new Uint8Array(event.data);
    if (data.length > this.exports.hw_input_capacity()) throw new Error(`${this.role}: websocket fragment exceeds wire bound`);
    bytesAt(this.exports.memory, this.exports.hw_input_ptr(), data.length).set(data);
    const accepted = this.exports.hw_feed(data.length);
    if (accepted !== 1 && accepted !== 2) throw new Error(errorText(this.exports) || `${this.role}: wire feed failed`);
    if (accepted === 2) this.sendOutput();
    if (this.role === 'observer' && this.exports.hw_phase() === 4) {
      handleLiveSnapshot(this);
      this.observe(false, 0);
    }
    if (this.role === 'control' && this.exports.hw_phase() === 6) updateFacts();
  }
  observe(immediate, historyOffset = 0) {
    const accepted = this.role === 'observer'
      ? this.exports.hw_observe_live(immediate ? 1 : 0)
      : this.exports.hw_observe(immediate ? 1 : 0, historyOffset);
    if (accepted !== 1) throw new Error(`${this.role}: observe rejected`);
    this.sendOutput();
  }
  async image(imageId, generation) {
    if (this.closed || !this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error(`${this.role}: connection is not available`);
    try {
      if (this.exports.hw_request_image(imageId, generation) !== 1) throw new Error(`${this.role}: image request rejected`);
      this.sendOutput();
      await this.waitForPhase(8);
      const result = {
        imageId:Number(this.exports.hw_image_id()),
        generation:this.exports.hw_image_generation(),
        width:Number(this.exports.hw_image_width()),
        height:Number(this.exports.hw_image_height()),
        pixels:bytesAt(this.exports.memory, this.exports.hw_image_ptr(), this.exports.hw_image_len()).slice(),
      };
      if (this.exports.hw_release_image() !== 1) throw new Error(`${this.role}: image release failed`);
      return result;
    } catch (error) {
      this.close();
      throw error;
    }
  }
  stage(value) {
    const bytes = encoder.encode(value);
    if (bytes.length === 0 || bytes.length > 4096 || bytes.length > this.exports.hw_input_capacity())
      throw new Error(`${this.role}: semantic text exceeds 4096-byte request bound`);
    bytesAt(this.exports.memory, this.exports.hw_input_ptr(), bytes.length).set(bytes);
    return bytes.length;
  }
  async operation(begin, label, telemetryKind = 'control') {
    const started = performance.now();
    telemetry.record('control_start', {kind:telemetryKind, pending:controlQueue.pending});
    if (this.closed || !this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error(`${this.role}: connection is not available`);
    if (this.exports.hw_control_ready() !== 1) throw new Error(`${this.role}: prior control operation is still pending`);
    if (begin() !== 1) throw new Error(`${this.role}: ${label} rejected before send`);
    this.sendOutput();
    await this.waitForPhase(6);
    lastInput = label;
    telemetry.record('control_ack', {kind:telemetryKind, ms:Math.round((performance.now() - started) * 10) / 10, pending:controlQueue.pending});
    updateFacts();
  }
  committedText(value) {
    const length = this.stage(value);
    return this.operation(() => this.exports.hw_send_text(length), `commit ${JSON.stringify(value)}`, 'text');
  }
  paste(value) {
    const length = this.stage(value);
    return this.operation(() => this.exports.hw_send_paste(length), `paste ${length} bytes`, 'paste');
  }
  namedKey(key, action, modifiers) {
    return this.operation(() => this.exports.hw_send_named_key(key, action, modifiers), `key ${key}/${action} mods=${modifiers}`, 'key');
  }
  unicodeKey(scalar, action, modifiers) {
    return this.operation(() => this.exports.hw_send_unicode_key(scalar, action, modifiers), `unicode U+${scalar.toString(16)} mods=${modifiers}`, 'key');
  }
  focus(value) {
    return this.operation(() => this.exports.hw_send_focus(value), `focus ${value === 1 ? 'in' : 'out'}`, 'focus');
  }
  mouse(input) {
    return this.operation(() => this.exports.hw_send_mouse(
      input.kind, input.button, input.modifiers, input.buttonsDown,
      input.row, input.column, 1, input.pixelX, input.pixelY,
    ), `mouse ${input.kind}/${input.button} at ${input.row},${input.column}`, 'mouse');
  }
  async interactionState() {
    await this.operation(
      () => this.exports.hw_request_interaction_state(),
      'interaction state',
      'interaction',
    );
    return {
      terminalRevision:this.exports.hw_interaction_terminal_revision(),
      alternateScroll:this.exports.hw_interaction_alternate_scroll() === 1,
      mouseTracking:Number(this.exports.hw_interaction_mouse_tracking()),
      mouseProtocol:Number(this.exports.hw_interaction_mouse_protocol()),
      pointerMode:Number(this.exports.hw_interaction_pointer_mode()),
    };
  }
  async textExtract(range) {
    const {start, end} = range.ordered;
    await this.operation(
      () => this.exports.hw_request_text_extract(
        start.row, start.column, end.row, end.column,
        range.columns, range.alternateScreen ? 1 : 0,
      ),
      'selection extract',
      'selection',
    );
    const code = Number(this.exports.hw_last_result_code());
    if (code !== 0) throw new Error(`selection extract result ${code}`);
    const length = Number(this.exports.hw_selection_len());
    const value = decoder.decode(bytesAt(this.exports.memory, this.exports.hw_selection_ptr(), length));
    return {value, length};
  }
  async resize(rows, columns, {claim = false} = {}) {
    const begin = claim ? this.exports.hw_send_resize : this.exports.hw_send_resize_owned;
    await this.operation(() => begin(rows, columns), `${claim ? 'claim+resize' : 'resize'} ${rows}x${columns}`, 'resize');
    return Number(this.exports.hw_last_result_code());
  }
  waitForPhase(wanted) {
    if (this.exports.hw_phase() === wanted) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const started = performance.now();
      const tick = () => {
        if (this.exports.hw_phase() === wanted) return resolve();
        if (this.closed) return reject(new Error(`${this.role}: connection closed while waiting for phase ${wanted}`));
        if (this.exports.hw_phase() === 99) return reject(new Error(errorText(this.exports) || `${this.role}: protocol failure`));
        if (performance.now() - started > 5000) return reject(new Error(`${this.role}: phase ${wanted} timeout`));
        setTimeout(tick, 5);
      };
      tick();
    });
  }
  async closeAndWait() {
    this.closed = true;
    const socket = this.socket;
    if (!socket || socket.readyState === WebSocket.CLOSED) return;
    const closed = new Promise(resolve => socket.addEventListener('close', resolve, {once:true}));
    socket.close();
    await Promise.race([closed, new Promise((_, reject) => setTimeout(() => reject(new Error(`${this.role}: close timeout`)), 3000))]);
  }
  close() {
    this.closed = true;
    this.socket?.close();
  }
}

async function ensureControl() {
  if (control && !control.closed && control.socket?.readyState === WebSocket.OPEN) return control;
  control = await WireConnection.connect('control');
  resizePolicy.reset();
  focusState = null;
  interactionStateCache = null;
  interactionStateCachedAt = 0;
  return control;
}

async function ensureImageConnection() {
  if (imageConnection && !imageConnection.closed && imageConnection.socket?.readyState === WebSocket.OPEN) return imageConnection;
  imageConnection = await WireConnection.connect('image');
  updateFacts();
  return imageConnection;
}

function queueControl(run, kind = 'control') {
  return controlQueue.operation(async () => run(await ensureControl()), kind);
}

async function currentInteractionState() {
  const now = performance.now();
  if (interactionStateCache && now - interactionStateCachedAt <= interactionStateFreshMs)
    return interactionStateCache;
  const state = await controlQueue.operation(
    async () => (await ensureControl()).interactionState(),
    'interaction',
  );
  interactionStateCache = state;
  interactionStateCachedAt = performance.now();
  return state;
}

function utf8Chunks(value, maximum = 4096) {
  const result = [];
  let current = '';
  let bytes = 0;
  for (const scalar of value) {
    const size = encoder.encode(scalar).length;
    if (size > maximum) throw new Error('one Unicode scalar exceeds semantic request bound');
    if (bytes + size > maximum) { result.push(current); current = ''; bytes = 0; }
    current += scalar; bytes += size;
  }
  if (current) result.push(current);
  return result;
}

function queueCommitted(value) {
  if (!value) return;
  returnToLive();
  const latched = modifierLatch;
  clearModifierLatch();
  const scalar = latched ? singleScalar(value) : null;
  if (scalar != null) {
    queueKeyCycle({scalar, modifiers:latched});
    return;
  }
  for (const chunk of utf8Chunks(value)) {
    const bytes = encoder.encode(chunk).length;
    controlQueue.text(chunk, bytes, async merged => (await ensureControl()).committedText(merged));
  }
}

function queuePaste(value) {
  if (!value) return;
  returnToLive();
  clearModifierLatch();
  if (encoder.encode(value).length > 4096) {
    fail(new Error('paste exceeds current 4096-byte semantic request bound'));
    return;
  }
  queueControl(connection => connection.paste(value), 'paste');
}

function queueKeyCycle({named, scalar, modifiers = modifierLatch}) {
  returnToLive();
  clearModifierLatch();
  const operation = named != null
    ? (connection, action) => connection.namedKey(named, action, modifiers)
    : (connection, action) => connection.unicodeKey(scalar, action, modifiers);
  queueControl(connection => operation(connection, KeyAction.press), 'key');
  queueControl(connection => operation(connection, KeyAction.release), 'key');
}

function queueHardwareKey({named, scalar, action, modifiers}) {
  returnToLive();
  if (named != null) queueControl(connection => connection.namedKey(named, action, modifiers), 'key');
  else queueControl(connection => connection.unicodeKey(scalar, action, modifiers), 'key');
}

function historyMetadata(wire) {
  return {
    historyOffset: Number(wire.hw_history_offset()),
    historyCount: Number(wire.hw_history_count()),
    historyRowBase: Number(wire.hw_history_row_base()),
    alternateScreen: wire.hw_alternate_screen() === 1,
    leaderPresent: wire.hw_leader_present() === 1,
  };
}

function snapshotCopy(connection) {
  const wire = connection.exports;
  const length = Number(wire.hw_snapshot_len());
  if (length === 0 || length > renderer.exports.rv_snapshot_capacity()) throw new Error('snapshot exceeds renderer input bound');
  return bytesAt(wire.memory, wire.hw_snapshot_ptr(), length).slice();
}

let renderTail = Promise.resolve();

function rendererMissingExternal() {
  if (renderer.exports.rv_missing_external() !== 1) return null;
  const q = [
    renderer.exports.rv_missing_resource(),
    renderer.exports.rv_missing_generation(),
  ];
  const value = {
    q,
    key:resourceKey(q),
    format:Number(renderer.exports.rv_missing_format()),
    width:Number(renderer.exports.rv_missing_width()),
    height:Number(renderer.exports.rv_missing_height()),
    stride:Number(renderer.exports.rv_missing_stride()),
    imageId:Number(renderer.exports.rv_missing_image_id()),
    imageGeneration:renderer.exports.rv_missing_image_generation(),
  };
  if (value.q.some(part => part === 0n) || value.format !== 1 || value.width <= 0 || value.height <= 0 ||
      value.stride !== value.width * 4 || value.imageId <= 0 || value.imageGeneration === 0n) {
    throw new Error('renderer exposed invalid external image request');
  }
  return value;
}

function externalResourceMatches(resource, missing) {
  return resource?.format === missing.format && resource.width === missing.width &&
    resource.height === missing.height && resource.stride === missing.stride;
}

async function ensureExternalResource(missing) {
  const existing = resources.get(missing.key);
  if (existing) {
    if (!externalResourceMatches(existing, missing)) throw new Error(`backend resource metadata changed for ${missing.key}`);
    return {bytes:0, ms:0, reused:true};
  }
  const started = performance.now();
  const connection = await ensureImageConnection();
  const image = await connection.image(missing.imageId, missing.imageGeneration);
  if (image.imageId !== missing.imageId || image.generation !== missing.imageGeneration ||
      image.width !== missing.width || image.height !== missing.height ||
      image.pixels.length !== missing.stride * missing.height) {
    throw new Error(`terminal image refill does not match Canvas external ${missing.key}`);
  }
  const upload = {
    q:missing.q, f:missing.format, z:[missing.width, missing.height],
    o:0, n:image.pixels.length, stride:missing.stride,
  };
  const resource = createResource(upload, image.pixels);
  const ms = performance.now() - started;
  return {bytes:image.pixels.length, ms, reused:false, resource};
}

function renderSnapshotBytes(snapshot, clientId, mode, stillCurrent = () => true, displayHistory = null) {
  const run = renderTail.then(() => renderSnapshotBytesInner(snapshot, clientId, mode, stillCurrent, displayHistory));
  renderTail = run.catch(() => {});
  return run;
}

async function renderSnapshotBytesInner(snapshot, clientId, mode, stillCurrent, displayHistory) {
  if (!stillCurrent()) return;
  const renderStarted = performance.now();
  const renderGap = lastRenderTelemetryAt == null ? null : renderStarted - lastRenderTelemetryAt;
  lastRenderTelemetryAt = renderStarted;
  if (snapshot.length === 0 || snapshot.length > renderer.exports.rv_snapshot_capacity()) throw new Error('snapshot exceeds renderer input bound');
  let externalBytes = 0;
  let externalMs = 0;
  let externalReused = false;
  let wasmMs = 0;
  for (let attempt = 0; attempt < MAX_RENDER_ATTEMPTS; attempt += 1) {
    bytesAt(renderer.exports.memory, renderer.exports.rv_snapshot_ptr(), snapshot.length).set(snapshot);
    const wasmStarted = performance.now();
    const result = renderer.exports.rv_render(snapshot.length);
    wasmMs += performance.now() - wasmStarted;
    if (result === 2) {
      const missing = rendererMissingExternal();
      if (!missing) throw new Error('renderer requested external image without exact metadata');
      let refill;
      try {
        refill = await ensureExternalResource(missing);
      } catch (error) {
        if (!stillCurrent()) return;
        throw error;
      }
      externalBytes += refill.bytes;
      externalMs += refill.ms;
      externalReused ||= refill.reused;
      if (!stillCurrent()) return;
      const current = rendererMissingExternal();
      if (!current || current.key !== missing.key || current.imageId !== missing.imageId ||
          current.imageGeneration !== missing.imageGeneration) {
        throw new Error('renderer external image request changed during refill');
      }
      // Keep cancellation before cache mutation. From this point through
      // rv_accept_external there is no await/event-loop handoff: the exact
      // browser resource is staged before renderer acceptance, rolled back on
      // rejection, and older generations retire only after acceptance succeeds.
      if (!refill.reused) resources.set(missing.key, refill.resource);
      if (renderer.exports.rv_accept_external() !== 1) {
        if (!refill.reused) resources.delete(missing.key);
        throw new Error(errorText(renderer.exports) || 'renderer external residency rejected');
      }
      if (!refill.reused) {
        const identity = String(missing.q[0]) + ':';
        for (const key of [...resources.keys()])
          if (key !== missing.key && key.startsWith(identity)) resources.delete(key);
        telemetry.record('image_refill', {
          image_id:missing.imageId,
          image_generation:String(missing.imageGeneration),
          canvas_resource:missing.key,
          bytes:refill.bytes,
          ms:Math.round(refill.ms * 10) / 10,
        });
        updateFacts();
      }
      continue;
    }
    if (result !== 1) throw new Error(errorText(renderer.exports) || 'terminal renderer failed');
    if (!stillCurrent()) return;

    const metadataStarted = performance.now();
    const metadata = parseRendererFrameV4(renderer.exports, decoder.decode(bytesAt(
      renderer.exports.memory, renderer.exports.rv_frame_ptr(), renderer.exports.rv_frame_len(),
    )));
    const pixelBytes = bytesAt(renderer.exports.memory, renderer.exports.rv_pixels_ptr(), renderer.exports.rv_pixels_len()).slice();
    const metadataFinished = performance.now();
    const canvas = drawFrame(metadata, pixelBytes);
    const drawFinished = performance.now();
    if (renderer.exports.rv_ack() !== 1) throw new Error(errorText(renderer.exports) || 'renderer frame acknowledgment failed');
    const ackFinished = performance.now();
    lastFrame = {...metadata, observer:String(clientId), mode};
    displayedHistory = displayHistory;
    validateSelection();
    renderSelectionOverlay();
    if (requestedGeometry && metadata.surface[0] === requestedGeometry.columns * metadata.cell[0] &&
        metadata.surface[1] === requestedGeometry.rows * metadata.cell[1]) requestedGeometry = null;
    status.textContent = mode === 'history'
      ? `HISTORY: ${history.targetOffset} rows above live`
      : 'LIVE: canonical Howl snapshot rendered by the shared Zig pipeline';
    telemetry.record('render', {
      mode, ms:Math.round((ackFinished - renderStarted) * 10) / 10,
      wasm_ms:Math.round(wasmMs * 10) / 10,
      metadata_ms:Math.round((metadataFinished - metadataStarted) * 10) / 10,
      canvas_ms:Math.round((drawFinished - metadataFinished) * 10) / 10,
      ack_ms:Math.round((ackFinished - drawFinished) * 10) / 10,
      external_ms:Math.round(externalMs * 10) / 10,
      external_bytes:externalBytes,
      external_reused:externalReused,
      gap_ms:renderGap == null ? null : Math.round(renderGap * 10) / 10,
      commands:metadata.commands.count, uploads:metadata.uploads.length,
      upload_ms:canvas.upload_ms, draw_commands_ms:canvas.draw_commands_ms,
      surface_ms:canvas.surface_ms, retire_ms:canvas.retire_ms,
      upload_bytes:canvas.upload_bytes, upload_pixels:canvas.upload_pixels,
      max_upload_pixels:canvas.max_upload_pixels, surface_resized:canvas.surface_resized,
      solid_commands:canvas.solid_commands, alpha_commands:canvas.alpha_commands, image_commands:canvas.image_commands,
      backend:canvas.backend, draw_calls:canvas.draw_calls, webgl_sync_ms:canvas.webgl_sync_ms,
      scratch:[alphaScratch.width, alphaScratch.height],
      terminal:String(metadata.terminal), observation:String(metadata.observation),
    });
    if (mode === 'live') scheduleViewportResize();
    updateFacts();
    return;
  }
  throw new Error('renderer external image retry limit exceeded');
}

function renderLatestLive() {
  if (latestLiveSnapshot) liveFrameScheduler.push({
    snapshot:latestLiveSnapshot, clientId:latestLiveClientId, history:latestLiveHistory,
  });
}

function handleLiveSnapshot(connection) {
  latestLiveSnapshot = snapshotCopy(connection);
  latestLiveClientId = connection.clientId ?? connection.exports.hw_identity();
  latestLiveHistory = historyMetadata(connection.exports);
  if (!history.active) {
    if (!presentationChanging) liveFrameScheduler.push({
      snapshot:latestLiveSnapshot, clientId:latestLiveClientId, history:latestLiveHistory,
    });
    return;
  }
  history.followLive(latestLiveHistory);
  historyGeneration += 1;
  if (!history.active) {
    leaveHistory();
    return;
  }
  scheduleHistorySnapshot();
  updateFacts();
}

async function ensureHistoryObserver() {
  if (historyObserver && !historyObserver.closed && historyObserver.socket?.readyState === WebSocket.OPEN) return historyObserver;
  historyObserver = await WireConnection.connect('history');
  return historyObserver;
}

function scheduleHistorySnapshot() {
  if (!history.active) return;
  historyRequestPending = true;
  if (!historyRequestRunning) void drainHistorySnapshots();
}

async function drainHistorySnapshots() {
  if (historyRequestRunning || !history.active) return;
  historyRequestRunning = true;
  try {
    while (history.active && historyRequestPending) {
      historyRequestPending = false;
      const generation = historyGeneration;
      const connection = await ensureHistoryObserver();
      if (!history.active || generation !== historyGeneration) continue;
      connection.observe(true, history.targetOffset);
      await connection.waitForPhase(4);
      if (!history.active || generation !== historyGeneration) continue;
      const acceptedHistory = historyMetadata(connection.exports);
      history.acceptSnapshot(acceptedHistory);
      if (!history.active) {
        leaveHistory();
        continue;
      }
      await renderSnapshotBytes(
        snapshotCopy(connection),
        connection.clientId ?? connection.exports.hw_identity(),
        'history',
        () => history.active && generation === historyGeneration,
        acceptedHistory,
      );
    }
  } catch (error) {
    if (history.active) {
      leaveHistory();
      fail(error);
    }
  } finally {
    historyRequestRunning = false;
    if (history.active && historyRequestPending) void drainHistorySnapshots();
  }
}

function leaveHistory() {
  history.reset();
  historyGeneration += 1;
  historyRequestPending = false;
  const oldObserver = historyObserver;
  historyObserver = null;
  oldObserver?.close();
  renderLatestLive();
  updateFacts();
}

function returnToLive() {
  const selectionChanged = clearSelection();
  if (!history.active) return selectionChanged;
  leaveHistory();
  return true;
}

function createResource(upload, framePixels) {
  const [width, height] = upload.z;
  const bytes = framePixels.slice(upload.o, upload.o + upload.n);
  const resource = {
    format:upload.f, width, height, stride:upload.stride, bytes,
    alphaSprites:new Map(), alphaSpritePixels:0,
  };
  const image = document.createElement('canvas');
  image.width = width; image.height = height;
  const ctx = image.getContext('2d');
  const data = ctx.createImageData(width, height);
  if (upload.f === 0) {
    for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
      const a = bytes[y * upload.stride + x];
      const p = (y * width + x) * 4;
      data.data[p] = data.data[p + 1] = data.data[p + 2] = 255;
      data.data[p + 3] = glyphCoverageLut[a];
    }
  } else if (upload.f === 1) {
    for (let y = 0; y < height; y += 1) {
      data.data.set(bytes.subarray(y * upload.stride, y * upload.stride + width * 4), y * width * 4);
    }
  } else throw new Error(`unsupported Canvas resource format ${upload.f}`);
  ctx.putImageData(data, 0, 0);
  resource.canvas = image;
  return resource;
}

function alphaSprite(resource, source, color) {
  const [sx, sy, sw, sh] = source;
  const width = Math.ceil(sw), height = Math.ceil(sh);
  const pixels = width * height;
  if (width <= 0 || height <= 0 || pixels > alphaSpritePixelBudget) return null;
  const key = `${sx}:${sy}:${sw}:${sh}:${color.join(':')}`;
  const existing = resource.alphaSprites.get(key);
  if (existing) {
    // Map insertion order is our tiny LRU. Frequently reused glyph/color pairs
    // stay resident while bounded uncommon combinations fall out naturally.
    resource.alphaSprites.delete(key);
    resource.alphaSprites.set(key, existing);
    return existing.canvas;
  }
  while (resource.alphaSpritePixels + pixels > alphaSpritePixelBudget && resource.alphaSprites.size !== 0) {
    const [oldKey, old] = resource.alphaSprites.entries().next().value;
    resource.alphaSprites.delete(oldKey);
    resource.alphaSpritePixels -= old.pixels;
  }
  const canvas = document.createElement('canvas');
  canvas.width = width; canvas.height = height;
  const ctx = canvas.getContext('2d');
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(resource.canvas, sx, sy, sw, sh, 0, 0, width, height);
  ctx.globalCompositeOperation = 'source-in';
  ctx.fillStyle = rgba(color);
  ctx.fillRect(0, 0, width, height);
  resource.alphaSprites.set(key, {canvas, pixels});
  resource.alphaSpritePixels += pixels;
  return canvas;
}

function syncCanvasResourceLease(frame, framePixels) {
  const started = performance.now();
  for (const q of frame.removals) resources.delete(resourceKey(q));
  const removalsFinished = performance.now();
  let uploadBytes = 0, uploadPixels = 0, maxUploadPixels = 0;
  for (const upload of frame.uploads) {
    const pixels = upload.z[0] * upload.z[1];
    uploadBytes += upload.n;
    uploadPixels += pixels;
    maxUploadPixels = Math.max(maxUploadPixels, pixels);
    resources.set(resourceKey(upload.q), createResource(upload, framePixels));
  }
  const uploadsFinished = performance.now();
  // Terminal Canvas derives uploads/removals from exact accepted residency.
  // Stable frames cannot change cache membership, so do not reconstruct the
  // same lease by walking every command on every presentation.
  if (frame.uploads.length !== 0 || frame.removals.length !== 0) {
    const live = new Set();
    for (let i = 0; i < frame.commands.count; i += 1)
      if (frame.commands.kind(i) !== 0) live.add(frame.commands.key(i));
    for (const key of [...resources.keys()]) if (!live.has(key)) resources.delete(key);
  }
  const finished = performance.now();
  const ms = (end, begin) => Math.round((end - begin) * 10) / 10;
  return {
    removals_ms:ms(removalsFinished, started),
    upload_ms:ms(uploadsFinished, removalsFinished),
    retire_ms:ms(finished, uploadsFinished),
    upload_bytes:uploadBytes,
    upload_pixels:uploadPixels,
    max_upload_pixels:maxUploadPixels,
  };
}

function ensureTerminalSurface(frame) {
  const [width, height] = frame.surface;
  const surfaceResized = terminal.width !== width || terminal.height !== height;
  if (surfaceResized) {
    terminal.width = width;
    terminal.height = height;
  }
  const logicalWidth = width / rasterScale;
  const expectedWidth = String(logicalWidth) + 'px';
  if (terminal.style.width !== expectedWidth) terminal.style.width = expectedWidth;
  if (terminal.style.height) terminal.style.height = '';
  context.imageSmoothingEnabled = false;
  return surfaceResized;
}

function disableWebGLBackend(error) {
  webglBackendFailure = error instanceof Error ? error.message : String(error);
  try { webglBackend?.reset(); } catch {}
  webglBackend = null;
}

function drawFrame(frame, framePixels) {
  let webglSyncMs = 0;
  if (webglBackend) {
    const syncStarted = performance.now();
    try {
      webglBackend.syncResources(frame, framePixels, resourceKey);
    } catch (error) {
      disableWebGLBackend(error);
    }
    webglSyncMs = performance.now() - syncStarted;
  }

  if (!webglBackend || !webglBackend.admit(frame)) {
    return {
      ...drawFrameCanvas(frame, framePixels),
      backend:'canvas2d',
      draw_calls:null,
      webgl_sync_ms:Math.round(webglSyncMs * 10) / 10,
    };
  }

  try {
    const started = performance.now();
    const lease = syncCanvasResourceLease(frame, framePixels);
    const resourcesFinished = performance.now();
    const surfaceResized = ensureTerminalSurface(frame);
    context.clearRect(0, 0, frame.surface[0], frame.surface[1]);
    const surfaceFinished = performance.now();
    const gpu = webglBackend.draw(frame, resourceKey);
    context.drawImage(webglBackend.canvas, 0, 0, frame.surface[0], frame.surface[1]);
    const commandsFinished = performance.now();
    const ms = (end, begin) => Math.round((end - begin) * 10) / 10;
    let solidCommands = 0, alphaCommands = 0;
    for (let i = 0; i < frame.commands.count; i += 1) {
      const kind = frame.commands.kind(i);
      if (kind === 0) solidCommands += 1;
      else if (kind === 1) alphaCommands += 1;
    }
    return {
      removals_ms:lease.removals_ms,
      upload_ms:Math.round((lease.upload_ms + webglSyncMs) * 10) / 10,
      surface_ms:ms(surfaceFinished, resourcesFinished),
      draw_commands_ms:ms(commandsFinished, surfaceFinished),
      retire_ms:lease.retire_ms,
      upload_bytes:lease.upload_bytes,
      upload_pixels:lease.upload_pixels,
      max_upload_pixels:lease.max_upload_pixels,
      surface_resized:surfaceResized,
      solid_commands:solidCommands,
      alpha_commands:alphaCommands,
      image_commands:0,
      backend:'webgl2',
      draw_calls:gpu.draw_calls,
      webgl_sync_ms:Math.round(webglSyncMs * 10) / 10,
      total_backend_ms:ms(commandsFinished, started),
    };
  } catch (error) {
    disableWebGLBackend(error);
    return {
      ...drawFrameCanvas(frame, framePixels),
      backend:'canvas2d',
      draw_calls:null,
      webgl_sync_ms:Math.round(webglSyncMs * 10) / 10,
    };
  }
}

function drawFrameCanvas(frame, framePixels) {
  const started = performance.now();
  for (const q of frame.removals) resources.delete(resourceKey(q));
  const removalsFinished = performance.now();
  let uploadBytes = 0, uploadPixels = 0, maxUploadPixels = 0;
  for (const upload of frame.uploads) {
    const pixels = upload.z[0] * upload.z[1];
    uploadBytes += upload.n;
    uploadPixels += pixels;
    maxUploadPixels = Math.max(maxUploadPixels, pixels);
    resources.set(resourceKey(upload.q), createResource(upload, framePixels));
  }
  const uploadsFinished = performance.now();
  const [width, height] = frame.surface;
  const surfaceResized = terminal.width !== width || terminal.height !== height;
  if (surfaceResized) { terminal.width = width; terminal.height = height; }
  const logicalWidth = width / rasterScale;
  if (terminal.style.width !== `${logicalWidth}px`) terminal.style.width = `${logicalWidth}px`;
  // CSS `height:auto` preserves the backing-store aspect ratio if max-width
  // temporarily constrains a follower before its next geometry cut.
  if (terminal.style.height) terminal.style.height = '';
  context.imageSmoothingEnabled = false;
  context.clearRect(0, 0, width, height);
  const surfaceFinished = performance.now();
  const currentResources = new Set();
  let solidCommands = 0, alphaCommands = 0, imageCommands = 0;
  const commands = frame.commands;
  for (let i = 0; i < commands.count; i += 1) {
    const kind = commands.kind(i);
    if (kind !== 0) currentResources.add(commands.key(i));
    if (kind === 0) {
      solidCommands += 1;
      context.fillStyle = rgbaValues(commands.red(i), commands.green(i), commands.blue(i), commands.alpha(i));
      context.fillRect(commands.x(i), commands.y(i), commands.width(i), commands.height(i));
      continue;
    }
    const key = commands.key(i);
    const resource = resources.get(key);
    if (!resource) throw new Error(`missing backend resource ${key}`);
    const source = [commands.sourceX(i), commands.sourceY(i), commands.sourceWidth(i), commands.sourceHeight(i)];
    const visible = clippedSprite(
      [commands.x(i), commands.y(i), commands.width(i), commands.height(i)],
      [commands.clipX(i), commands.clipY(i), commands.clipWidth(i), commands.clipHeight(i)],
      source,
    );
    if (!visible) continue;
    const [dx, dy, dw, dh] = visible.destination;
    const [sx, sy, sw, sh] = visible.source;
    if (kind === 2) {
      imageCommands += 1;
      context.drawImage(resource.canvas, sx, sy, sw, sh, dx, dy, dw, dh);
    } else if (kind === 1) {
      alphaCommands += 1;
      const color = [commands.red(i), commands.green(i), commands.blue(i), commands.alpha(i)];
      const full = alphaSprite(resource, source, color);
      if (full) {
        const [fullSx, fullSy, fullSw, fullSh] = source;
        const localX = (sx - fullSx) * full.width / fullSw;
        const localY = (sy - fullSy) * full.height / fullSh;
        const localW = sw * full.width / fullSw;
        const localH = sh * full.height / fullSh;
        context.drawImage(full, localX, localY, localW, localH, dx, dy, dw, dh);
      } else {
        const scratchWidth = Math.max(1, Math.ceil(dw));
        const scratchHeight = Math.max(1, Math.ceil(dh));
        if (alphaScratch.width < scratchWidth || alphaScratch.height < scratchHeight) {
          alphaScratch.width = Math.max(alphaScratch.width, scratchWidth);
          alphaScratch.height = Math.max(alphaScratch.height, scratchHeight);
        }
        alphaScratchContext.globalCompositeOperation = 'source-over';
        alphaScratchContext.clearRect(0, 0, scratchWidth, scratchHeight);
        alphaScratchContext.imageSmoothingEnabled = false;
        alphaScratchContext.drawImage(resource.canvas, sx, sy, sw, sh, 0, 0, scratchWidth, scratchHeight);
        alphaScratchContext.globalCompositeOperation = 'source-in';
        alphaScratchContext.fillStyle = rgba(color);
        alphaScratchContext.fillRect(0, 0, scratchWidth, scratchHeight);
        context.drawImage(alphaScratch, 0, 0, scratchWidth, scratchHeight, dx, dy, dw, dh);
      }
    } else throw new Error(`unknown Canvas command ${kind}`);
  }
  const commandsFinished = performance.now();
  // Match Flutter's lease: every completed frame names the exact resource
  // generations it still references. Retire superseded generations here.
  for (const key of [...resources.keys()]) if (!currentResources.has(key)) resources.delete(key);
  const finished = performance.now();
  const ms = (end, begin) => Math.round((end - begin) * 10) / 10;
  return {
    removals_ms:ms(removalsFinished, started),
    upload_ms:ms(uploadsFinished, removalsFinished),
    surface_ms:ms(surfaceFinished, uploadsFinished),
    draw_commands_ms:ms(commandsFinished, surfaceFinished),
    retire_ms:ms(finished, commandsFinished),
    upload_bytes:uploadBytes, upload_pixels:uploadPixels, max_upload_pixels:maxUploadPixels,
    surface_resized:surfaceResized, solid_commands:solidCommands, alpha_commands:alphaCommands, image_commands:imageCommands,
    backend:'canvas2d', draw_calls:null, webgl_sync_ms:0,
  };
}

function resetEditor() {
  stager.reset();
  keyboard.value = guardText;
  keyboard.setSelectionRange(1, 1);
}

function dispatchStaged(actions) {
  for (const action of actions) {
    if (action.kind === 'text') queueCommitted(action.text);
    else queueKeyCycle({named:action.key});
  }
}

function processEditor(composing) {
  const editorBytes = encoder.encode(keyboard.value).length;
  const actions = stager.update(keyboard.value, {composing});
  let textBytes = 0, textActions = 0, keyActions = 0;
  for (const action of actions) {
    if (action.kind === 'text') { textActions += 1; textBytes += encoder.encode(action.text).length; }
    else keyActions += 1;
  }
  telemetry.record('editor_stage', {composing, editor_bytes:editorBytes, actions:actions.length, text_actions:textActions, key_actions:keyActions, text_bytes:textBytes});
  if (!composing) resetEditor();
  dispatchStaged(actions);
}

function focusKeyboardPreservingHistory() {
  if (focusKeyboardCapture(keyboard, {composing:compositionActive})) resetEditor();
}

function focusKeyboard() {
  returnToLive();
  focusKeyboardPreservingHistory();
}

keyboard.addEventListener('compositionstart', () => { compositionActive = true; telemetry.record('composition_start'); });
keyboard.addEventListener('compositionend', () => {
  compositionActive = false;
  telemetry.record('composition_end', {editor_bytes:encoder.encode(keyboard.value).length});
  const value = keyboard.value;
  setTimeout(() => {
    if (!compositionActive && keyboard.value === value && value !== guardText) processEditor(false);
  }, 0);
});
keyboard.addEventListener('input', event => {
  telemetry.record('input_event', {input_type:event.inputType ?? null, composing:Boolean(event.isComposing || compositionActive), editor_bytes:encoder.encode(keyboard.value).length});
  processEditor(Boolean(event.isComposing || compositionActive));
});
keyboard.addEventListener('paste', event => {
  const value = event.clipboardData?.getData('text/plain');
  if (value == null) return;
  event.preventDefault();
  resetEditor();
  queuePaste(value);
});
keyboard.addEventListener('keydown', event => {
  const named = namedKeyForCode(event.code);
  const action = event.repeat ? KeyAction.repeat : KeyAction.press;
  const modifiers = modifierBits(event);
  if (named != null) {
    queueHardwareKey({named, action, modifiers});
    if (named < 15 || named > 22) event.preventDefault();
    return;
  }
  const scalar = singleScalar(event.key);
  if (scalar != null && (modifiers & (Modifier.alt | Modifier.control | Modifier.super)) !== 0) {
    modifiedKeys.set(event.code, {scalar, modifiers});
    queueHardwareKey({scalar, action, modifiers});
    event.preventDefault();
  }
});
keyboard.addEventListener('keyup', event => {
  const named = namedKeyForCode(event.code);
  if (named != null) {
    queueHardwareKey({named, action:KeyAction.release, modifiers:modifierBits(event)});
    if (named < 15 || named > 22) event.preventDefault();
    return;
  }
  const tracked = modifiedKeys.get(event.code);
  if (tracked) {
    modifiedKeys.delete(event.code);
    queueHardwareKey({...tracked, action:KeyAction.release});
    event.preventDefault();
  }
});

function currentPointerGeometry() {
  if (!lastFrame?.cell || !lastFrame?.surface) return null;
  const rect = terminal.getBoundingClientRect();
  return new TerminalPointerGeometry({
    left:rect.left + terminal.clientLeft, top:rect.top + terminal.clientTop,
    width:terminal.clientWidth, height:terminal.clientHeight,
    surfaceWidth:lastFrame.surface[0], surfaceHeight:lastFrame.surface[1],
    cellWidth:lastFrame.cell[0], cellHeight:lastFrame.cell[1],
  });
}

function currentSelectionViewport() {
  if (!displayedHistory || !lastFrame?.cell || !lastFrame?.surface) return null;
  const [cellWidth, cellHeight] = lastFrame.cell;
  if (!cellWidth || !cellHeight || lastFrame.surface[0] % cellWidth !== 0 || lastFrame.surface[1] % cellHeight !== 0)
    return null;
  return new TerminalSelectionViewport({
    historyOffset:displayedHistory.historyOffset,
    historyCount:displayedHistory.historyCount,
    historyRowBase:displayedHistory.historyRowBase,
    rows:lastFrame.surface[1] / cellHeight,
    columns:lastFrame.surface[0] / cellWidth,
    alternateScreen:displayedHistory.alternateScreen,
    selectionRows:Array.isArray(lastFrame.selection_rows) ? lastFrame.selection_rows : [],
  });
}

function selectionPointForEvent(event, {clamped = false} = {}) {
  const geometry = currentPointerGeometry();
  const viewport = currentSelectionViewport();
  if (!geometry || !viewport) return null;
  let clientX = event.clientX, clientY = event.clientY;
  if (clamped) {
    const rect = terminal.getBoundingClientRect();
    const left = rect.left + terminal.clientLeft;
    const top = rect.top + terminal.clientTop;
    const epsilon = 0.001;
    clientX = clamp(clientX, left, left + terminal.clientWidth - epsilon);
    clientY = clamp(clientY, top, top + terminal.clientHeight - epsilon);
  }
  const cell = geometry.locate({clientX, clientY});
  if (!cell) return null;
  const point = viewport.pointAt(cell.row, cell.column);
  return point ? {point, viewport} : null;
}

function clearSelection() {
  const changed = desktopSelection.range != null || desktopSelection.active || pointerDecisionPointer != null;
  desktopSelection.clear();
  pointerDecisionPointer = null;
  selectionOverlayView.clear();
  if (changed) updateFacts();
  return changed;
}

function validateSelection() {
  const range = desktopSelection.range;
  if (!range) return;
  const viewport = currentSelectionViewport();
  if (!viewport || viewport.validity(range) !== 'valid') clearSelection();
}

function renderSelectionOverlay() {
  selectionOverlayView.render(desktopSelection.range, currentSelectionViewport());
}

function startLocalSelection(event) {
  const located = selectionPointForEvent(event);
  if (!located) return false;
  terminalPointer.clear();
  pointerMoveScheduler.clear();
  desktopSelection.start({
    pointer:event.pointerId,
    point:located.point,
    columns:located.viewport.columns,
    alternateScreen:located.viewport.alternateScreen,
  });
  focusKeyboardPreservingHistory();
  renderSelectionOverlay();
  updateFacts();
  return true;
}

function updateLocalSelection(event) {
  if (desktopSelection.pointer !== event.pointerId) return false;
  const located = selectionPointForEvent(event, {clamped:true});
  const current = desktopSelection.range;
  if (!located || !current || located.viewport.validity(current) !== 'valid') return false;
  const next = desktopSelection.update(event.pointerId, located.point);
  if (!next) return false;
  renderSelectionOverlay();
  updateFacts();
  return true;
}

function finishLocalSelection(event) {
  if (desktopSelection.pointer !== event.pointerId) return false;
  updateLocalSelection(event);
  const result = desktopSelection.finish(event.pointerId);
  if (!result.keep) selectionOverlayView.clear();
  else renderSelectionOverlay();
  updateFacts();
  return true;
}

function handleTerminalPointer(event) {
  if (history.active || desktopSelection.range != null) return false;
  const inputs = terminalPointer.translate(event, {
    geometry:currentPointerGeometry(), modifiers:modifierBits(event),
  });
  if (inputs.length === 0) return false;
  for (const input of inputs) {
    if (input.kind === MouseKind.move) pointerMoveScheduler.push(input);
    else {
      pointerMoveScheduler.clear();
      queueControl(connection => connection.mouse(input), 'mouse');
    }
  }
  return true;
}

async function routePrimaryPointerDown(event) {
  const pointerId = event.pointerId;
  let route = routeDesktopPrimaryPointer({
    historyActive:history.active,
    forceSelection:event.shiftKey,
    mouseTrackingEnabled:null,
  });
  if (route === 'local_selection') {
    startLocalSelection(event);
    return;
  }
  pointerDecisionPointer = pointerId;
  try {
    const interaction = await currentInteractionState();
    if (pointerDecisionPointer !== pointerId) return;
    pointerDecisionPointer = null;
    route = routeDesktopPrimaryPointer({
      historyActive:history.active,
      forceSelection:event.shiftKey,
      mouseTrackingEnabled:interaction.mouseTracking !== 0,
    });
    if (route === 'local_selection') startLocalSelection(event);
    else if (route === 'terminal_mouse') handleTerminalPointer(event);
    else throw new Error('resolved primary pointer route requested interaction state');
  } catch (error) {
    if (pointerDecisionPointer === pointerId) pointerDecisionPointer = null;
    fail(error);
  }
}

terminal.addEventListener('pointerdown', event => {
  if (event.pointerType === 'touch') return;
  const primary = (event.buttons & 1) !== 0;
  try { terminal.setPointerCapture(event.pointerId); } catch {}
  if (primary) {
    event.preventDefault();
    void routePrimaryPointerDown(event);
    return;
  }
  focusKeyboardPreservingHistory();
  if (handleTerminalPointer(event)) event.preventDefault();
});
terminal.addEventListener('pointermove', event => {
  if (desktopSelection.pointer === event.pointerId) {
    updateLocalSelection(event);
    event.preventDefault();
    return;
  }
  if (pointerDecisionPointer === event.pointerId) return;
  handleTerminalPointer(event);
});
terminal.addEventListener('pointerup', event => {
  if (finishLocalSelection(event)) event.preventDefault();
  else if (pointerDecisionPointer === event.pointerId) pointerDecisionPointer = null;
  else if (handleTerminalPointer(event)) event.preventDefault();
  try { terminal.releasePointerCapture(event.pointerId); } catch {}
});
terminal.addEventListener('pointercancel', event => {
  if (desktopSelection.pointer === event.pointerId) clearSelection();
  else if (pointerDecisionPointer === event.pointerId) pointerDecisionPointer = null;
  else handleTerminalPointer(event);
  try { terminal.releasePointerCapture(event.pointerId); } catch {}
});
function scrollHistoryWheel({deltaY, deltaMode}) {
  if (!lastFrame?.cell || !latestLiveHistory || latestLiveHistory.alternateScreen || latestLiveHistory.historyCount === 0)
    return false;
  if (historyWheelTimer == null) history.beginGesture();
  else clearTimeout(historyWheelTimer);
  historyWheelTimer = setTimeout(() => { history.endGesture(); historyWheelTimer = null; }, 160);
  const rowHeight = lastFrame.cell[1] / rasterScale;
  let pixels = deltaY;
  if (deltaMode === WheelEvent.DOM_DELTA_LINE) pixels *= rowHeight;
  else if (deltaMode === WheelEvent.DOM_DELTA_PAGE) pixels *= Math.max(rowHeight, terminal.clientHeight);
  if (!history.scroll({
    deltaY:pixels, rowHeight,
    historyCount:latestLiveHistory.historyCount,
    historyRowBase:latestLiveHistory.historyRowBase,
    alternateScreen:latestLiveHistory.alternateScreen,
  })) return false;
  historyGeneration += 1;
  if (history.active) {
    terminalPointer.clear();
    pointerMoveScheduler.clear();
    scheduleHistorySnapshot();
    updateFacts();
  } else {
    leaveHistory();
  }
  return true;
}

async function routeTerminalWheel(event) {
  if (!lastFrame?.cell || !latestLiveHistory || !Number.isFinite(event.deltaY) || event.deltaY === 0) return;
  event.preventDefault();
  const local = {deltaY:event.deltaY, deltaMode:event.deltaMode};
  let route = routeDesktopWheel({
    historyActive:history.active,
    mouseTrackingEnabled:null,
    alternateScreen:latestLiveHistory.alternateScreen,
    alternateScroll:null,
  });
  if (route === 'history') {
    scrollHistoryWheel(local);
    return;
  }

  const wheel = terminalPointer.wheel(event, {
    geometry:currentPointerGeometry(), modifiers:modifierBits(event),
  });
  let interaction;
  try {
    interaction = await currentInteractionState();
  } catch (error) {
    fail(error);
    return;
  }
  route = routeDesktopWheel({
    historyActive:history.active,
    mouseTrackingEnabled:interaction.mouseTracking !== 0,
    alternateScreen:latestLiveHistory.alternateScreen,
    alternateScroll:interaction.alternateScroll,
  });
  if (route === 'history') scrollHistoryWheel(local);
  else if (route === 'terminal_mouse') {
    if (wheel != null) queueControl(connection => connection.mouse(wheel), 'mouse_wheel');
  } else if (route === 'alternate_scroll') {
    queueKeyCycle({named:event.deltaY < 0 ? NamedKey.ArrowUp : NamedKey.ArrowDown});
  } else if (route !== 'ignore') {
    fail(new Error('resolved wheel route requested interaction state'));
  }
}
terminal.addEventListener('wheel', event => { void routeTerminalWheel(event); }, {passive:false});
async function cyclePresentationZoom() {
  if (presentationChanging || !renderAssets) return;
  const nextIndex = (presentationIndex + 1) % presentationPixels.length;
  const nextPixels = presentationPixels[nextIndex];
  const nextCellWidth = presentationCellWidths[nextIndex];
  const nextLineHeight = presentationLineHeights[nextIndex];
  presentationChanging = true;
  zoomButton.disabled = true;
  liveFrameScheduler.reset();
  try {
    await renderTail.catch(() => {});
    const previousPixels = presentationPixels[presentationIndex];
    if (renderer.exports.rv_reset() !== 1) throw new Error('renderer reset failed');
    try {
      initializeRendererPresentation(renderer, nextPixels, nextCellWidth, nextLineHeight);
    } catch (error) {
      renderer.exports.rv_reset();
      initializeRendererPresentation(
        renderer,
        previousPixels,
        presentationCellWidths[presentationIndex],
        presentationLineHeights[presentationIndex],
      );
      throw error;
    }
    resources.clear();
    webglBackend?.reset();
    alphaScratch.width = 1;
    alphaScratch.height = 1;
    lastFrame = null;
    lastRenderTelemetryAt = null;
    requestedGeometry = null;
    presentationIndex = nextIndex;
    zoomButton.textContent = `${nextPixels}px`;
    telemetry.record('presentation_zoom', {pixels:nextPixels});
    presentationChanging = false;
    if (history.active) {
      historyGeneration += 1;
      scheduleHistorySnapshot();
    } else {
      renderLatestLive();
    }
  } catch (error) {
    presentationChanging = false;
    renderLatestLive();
    fail(error);
  } finally {
    zoomButton.disabled = false;
    focusKeyboard();
  }
}

keyboardButton.addEventListener('click', focusKeyboard);
zoomButton.addEventListener('click', () => { void cyclePresentationZoom(); });
leaderButton.addEventListener('click', () => {
  if (!lastFrame?.cell || !control || control.closed) return;
  const cellWidth = lastFrame.cell[0] / rasterScale;
  const cellHeight = lastFrame.cell[1] / rasterScale;
  if (!cellWidth || !cellHeight) return;
  const viewportHeight = Math.floor(window.visualViewport?.height ?? window.innerHeight);
  const width = Math.floor(main.clientWidth);
  const top = Math.max(0, terminal.getBoundingClientRect().top);
  const toolbarHeight = Math.ceil(toolbar.getBoundingClientRect().height);
  const rows = clamp(
    Math.floor(Math.max(cellHeight * 2, viewportHeight - top - toolbarHeight - 28) / cellHeight),
    2,
    control.exports.hw_maximum_rows(),
  );
  const columns = clamp(Math.floor(width / cellWidth), 20, control.exports.hw_maximum_columns());
  const controlId = control.clientId == null ? null : String(control.clientId);
  queueControl(connection => connection.resize(rows, columns, {claim:true}), 'resize')
    .then(code => {
      if (code !== 0) throw new Error(`leader claim result ${code}`);
      resizePolicy.accepted(controlId);
      requestedGeometry = {rows, columns};
      telemetry.record('resize_leader_acquired', {control:controlId, explicit:true});
      updateFacts();
    })
    .catch(fail)
    .finally(focusKeyboard);
});
copyButton.addEventListener('click', async () => {
  try {
    if (desktopSelection.range) {
      const selected = desktopSelection.range;
      const extracted = await queueControl(connection => connection.textExtract(selected), 'selection');
      if (!extracted?.value) throw new Error('selected terminal text is empty');
      await navigator.clipboard.writeText(extracted.value);
      clearSelection();
      status.textContent = `Selection copied (${extracted.length} bytes)`;
      return;
    }
    if (!lastFrame) throw new Error('displayed terminal text is not ready');
    const length = Number(renderer.exports.rv_text_len());
    const value = decoder.decode(bytesAt(renderer.exports.memory, renderer.exports.rv_text_ptr(), length));
    await navigator.clipboard.writeText(value);
    const truncated = renderer.exports.rv_text_truncated() === 1;
    status.textContent = `Visible terminal copied (${length} bytes${truncated ? ', truncated' : ''})`;
  } catch (error) {
    status.textContent = `COPY UNAVAILABLE: ${error.message}`;
  } finally {
    focusKeyboardPreservingHistory();
  }
});
pasteButton.addEventListener('click', async () => {
  try {
    if (!navigator.clipboard?.readText) throw new Error('browser clipboard read is unavailable');
    const value = await navigator.clipboard.readText();
    if (!value) {
      status.textContent = 'Clipboard is empty';
      return;
    }
    queuePaste(value);
    status.textContent = `Clipboard paste queued (${encoder.encode(value).length} bytes)`;
    focusKeyboard();
  } catch (error) {
    status.textContent = `PASTE UNAVAILABLE: ${error.message}`;
    focusKeyboard();
  }
});

function setModifierLatch(value) {
  modifierLatch = value;
  for (const button of toolbar.querySelectorAll('[data-modifier]')) {
    const bit = button.dataset.modifier === 'control' ? Modifier.control : Modifier.alt;
    button.setAttribute('aria-pressed', String((modifierLatch & bit) !== 0));
  }
  updateFacts();
}
function clearModifierLatch() { if (modifierLatch !== 0) setModifierLatch(0); }
for (const button of toolbar.querySelectorAll('[data-modifier]')) {
  button.addEventListener('click', () => {
    const bit = button.dataset.modifier === 'control' ? Modifier.control : Modifier.alt;
    setModifierLatch(modifierLatch ^ bit);
    focusKeyboard();
  });
}
for (const button of toolbar.querySelectorAll('[data-key]')) {
  button.addEventListener('click', () => {
    const key = NamedKey[button.dataset.key];
    if (key == null) return fail(new Error(`unknown toolbar key ${button.dataset.key}`));
    queueKeyCycle({named:key});
    focusKeyboard();
  });
}

function pageVisible() { return document.visibilityState === 'visible'; }
function desiredFocus() { return pageVisible() && document.hasFocus(); }
function connectionOpen(connection) {
  return Boolean(connection && !connection.closed && connection.socket?.readyState === WebSocket.OPEN);
}
function syncFocus() {
  const next = desiredFocus() ? 1 : 2;
  if (focusState === next || !wireModule) return;
  focusState = next;
  queueControl(connection => connection.focus(next), 'focus');
}
function lifecycleDecision() {
  return lifecyclePolicy.decide({
    visible:pageVisible(),
    observerOpen:connectionOpen(observer),
    controlOpen:connectionOpen(control),
  });
}
function lifecycleProbe(generation) {
  if (generation !== lifecycleGeneration || !wireModule) return;
  const decision = lifecycleDecision();
  telemetry.record('lifecycle_probe', {decision});
  if (decision === 'boot' || decision === 'hidden') return;
  if (decision === 'healthy') {
    syncFocus();
    return;
  }
  status.textContent = 'RESUMING: reconnecting browser transport…';
  reconnectAll().catch(fail);
}
function scheduleRecoveryProbes(source, extra = {}) {
  lifecycleGeneration += 1;
  const decision = lifecycleDecision();
  telemetry.record(source, {visibility:document.visibilityState, focused:document.hasFocus(), observer_open:connectionOpen(observer), control_open:connectionOpen(control), decision, ...extra});
  const generation = lifecycleGeneration;
  if (decision === 'boot') return;
  if (decision === 'hidden') {
    syncFocus();
    return;
  }
  if (decision === 'healthy' && !history.active) liveFrameScheduler.resume();
  setTimeout(() => lifecycleProbe(generation), 250);
  setTimeout(() => lifecycleProbe(generation), 1500);
}
function handleTransportClose(role) {
  scheduleRecoveryProbes('transport_close', {role});
}
function handleLifecycle() {
  eventLoopProbe.reset();
  scheduleRecoveryProbes('lifecycle');
}
window.addEventListener('focus', handleLifecycle);
window.addEventListener('blur', handleLifecycle);
document.addEventListener('visibilitychange', handleLifecycle);
window.addEventListener('pageshow', handleLifecycle);

function recordViewport(kind, source) {
  const viewport = window.visualViewport;
  telemetry.record(kind, {
    source,
    viewport:[Math.round(viewport?.width ?? innerWidth), Math.round(viewport?.height ?? innerHeight)],
    inner:[Math.round(innerWidth), Math.round(innerHeight)],
    offset:[Math.round(viewport?.offsetLeft ?? 0), Math.round(viewport?.offsetTop ?? 0)],
    scale:Math.round((viewport?.scale ?? 1) * 1000) / 1000,
    keyboard_focused:document.activeElement === keyboard,
  });
}

function scheduleViewportResize() {
  if (resizeTimer) clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    resizeTimer = null;
    if (!lastFrame?.cell || !control || control.closed) return;
    const cellWidth = lastFrame.cell[0] / rasterScale;
    const cellHeight = lastFrame.cell[1] / rasterScale;
    if (!cellWidth || !cellHeight) return;
    const viewportHeight = Math.floor(window.visualViewport?.height ?? window.innerHeight);
    const width = Math.floor(main.clientWidth);
    const top = Math.max(0, terminal.getBoundingClientRect().top);
    const toolbarHeight = Math.ceil(toolbar.getBoundingClientRect().height);
    const maximumColumns = control.exports.hw_maximum_columns();
    const maximumRows = control.exports.hw_maximum_rows();
    const columns = clamp(Math.floor(width / cellWidth), 20, maximumColumns);
    const rows = clamp(
      Math.floor(Math.max(cellHeight * 2, viewportHeight - top - toolbarHeight - 28) / cellHeight),
      2, maximumRows,
    );
    const currentColumns = Math.floor(lastFrame.surface[0] / lastFrame.cell[0]);
    const currentRows = Math.floor(lastFrame.surface[1] / lastFrame.cell[1]);
    if ((rows === currentRows && columns === currentColumns) ||
        (requestedGeometry?.rows === rows && requestedGeometry?.columns === columns)) return;
    const controlId = control?.clientId == null ? null : String(control.clientId);
    const leaderPresent = latestLiveHistory?.leaderPresent ?? false;
    const decision = resizePolicy.decide({leaderPresent, controlId});
    telemetry.record('resize_request', {
      rows, columns, current_rows:currentRows, current_columns:currentColumns,
      viewport_height:viewportHeight, width, leader_present:leaderPresent,
      owned:resizePolicy.owns(controlId), decision,
    });
    if (decision === 'wait' || decision === 'follow') return;
    requestedGeometry = {rows, columns};
    queueControl(connection => connection.resize(rows, columns, {claim:decision === 'claim'}), 'resize')
      .then(code => {
        telemetry.record('resize_ack', {rows, columns, code, claim:decision === 'claim'});
        const settled = resizePolicy.settle({decision, controlId, code});
        if (settled === 'ok') {
          if (decision === 'claim') telemetry.record('resize_leader_acquired', {control:controlId});
          updateFacts();
          return;
        }
        if (settled === 'not_leader') {
          requestedGeometry = null;
          telemetry.record('resize_not_leader', {control:controlId});
          updateFacts();
          return;
        }
        throw new Error(`resize result ${code}`);
      })
      .catch(error => { requestedGeometry = null; fail(error); });
  }, 120);
}
window.addEventListener('resize', () => {
  recordViewport('viewport_resize', 'window'); scheduleViewportResize(); renderSelectionOverlay();
});
window.visualViewport?.addEventListener('resize', () => {
  recordViewport('viewport_resize', 'visual'); scheduleViewportResize(); renderSelectionOverlay();
});
window.visualViewport?.addEventListener('scroll', () => {
  recordViewport('viewport_scroll', 'visual'); renderSelectionOverlay();
});

function updateFacts() {
  factsNode.textContent = JSON.stringify({
    generation: CANARY_GENERATION,
    presentation_pixels:presentationPixels[presentationIndex],
    observer_client: observer?.clientId ? String(observer.clientId) : null,
    previous_observer_client: previousObserverId,
    history_observer_client: historyObserver?.clientId ? String(historyObserver.clientId) : null,
    control_client: control?.clientId ? String(control.clientId) : null,
    image_client: imageConnection?.clientId ? String(imageConnection.clientId) : null,
    observer_phase: observer?.exports.hw_phase() ?? null,
    control_phase: control?.exports.hw_phase() ?? null,
    image_phase: imageConnection?.exports.hw_phase() ?? null,
    observation_revision: observer ? String(observer.exports.hw_revision()) : null,
    terminal_revision: observer ? String(observer.exports.hw_terminal_revision()) : null,
    history_active: history.active,
    history_target_offset: history.targetOffset,
    history_anchor_top_row: history.anchorTopRow,
    live_history_offset: latestLiveHistory?.historyOffset ?? null,
    live_history_count: latestLiveHistory?.historyCount ?? null,
    live_history_row_base: latestLiveHistory?.historyRowBase ?? null,
    alternate_screen: latestLiveHistory?.alternateScreen ?? null,
    resize_leader_present: latestLiveHistory?.leaderPresent ?? null,
    resize_authority_owned: resizePolicy.owns(control?.clientId == null ? null : String(control.clientId)),
    semantic_control_ready: control?.exports.hw_control_ready() === 1,
    control_queue_pending: controlQueue.pending,
    modifier_latch: modifierLatch,
    focus_state: focusState,
    requested_geometry: requestedGeometry,
    selection: desktopSelection.range
      ? {anchor:desktopSelection.range.anchor, focus:desktopSelection.range.focus}
      : null,
    last_control: lastInput || null,
    render_count: renderer ? String(renderer.exports.rv_render_count()) : '0',
    renderer_memory_bytes: renderer?.exports.memory.buffer.byteLength ?? null,
    backend_resources: resources.size,
    webgl_backend: webglBackend ? 'ready' : 'canvas2d',
    webgl_resources: webglBackend?.resourceCount() ?? 0,
    webgl_failure: webglBackendFailure,
    frame: lastFrame ? {
      observation: lastFrame.observation,
      terminal: lastFrame.terminal,
      commands: lastFrame.commands.count,
      uploads: lastFrame.uploads.length,
      removals: lastFrame.removals.length,
      surface: lastFrame.surface,
      cell: lastFrame.cell,
      mode: lastFrame.mode,
    } : null,
  }, null, 2);
}

telemetryPanel?.addEventListener('toggle', renderTelemetryLog);
telemetrySummaryCopy?.addEventListener('click', async () => {
  try {
    const text = telemetry.summaryCompact({context:telemetryContext()});
    await navigator.clipboard.writeText(text);
    status.textContent = `Telemetry summary copied (${telemetry.retained} events)`;
  } catch (error) {
    status.textContent = `TELEMETRY SUMMARY COPY FAILED: ${error.message}`;
  }
});
telemetryCopy?.addEventListener('click', async () => {
  try {
    const text = telemetry.compact({context:telemetryContext()});
    await navigator.clipboard.writeText(text);
    status.textContent = `Telemetry copied (${telemetry.retained} events)`;
  } catch (error) {
    status.textContent = `TELEMETRY COPY FAILED: ${error.message}`;
  }
});
telemetryClear?.addEventListener('click', () => {
  telemetry.clear();
  lastRenderTelemetryAt = null;
  renderTelemetryLog();
  status.textContent = 'Telemetry cleared';
});

reload.addEventListener('click', async () => {
  try {
    const registration = await navigator.serviceWorker?.getRegistration();
    const result = await updateAndPromoteServiceWorker(registration);
    if (registration?.waiting && !result.promoted) console.warn('waiting service worker did not activate before reload');
  } catch (error) {
    console.warn('service worker update check failed', error);
  }
  location.reload();
});

async function reconnectAll({manual = false} = {}) {
  const decision = lifecycleDecision();
  if (!reconnectAllowed(decision, {manual})) return;
  const completesBoot = decision === 'boot';
  if (reconnectTask) return reconnectTask;
  telemetry.record('reconnect_start', {observer_open:connectionOpen(observer), control_open:connectionOpen(control)});
  reconnectTask = (async () => {
    liveFrameScheduler.reset();
    clearSelection();
    displayedHistory = null;
    history.reset();
    historyGeneration += 1;
    historyRequestPending = false;
    if (historyObserver) { await historyObserver.closeAndWait(); historyObserver = null; }
    if (imageConnection) { await imageConnection.closeAndWait(); imageConnection = null; }
    if (observer) {
      previousObserverId = observer.clientId ? String(observer.clientId) : null;
      await observer.closeAndWait();
    }
    await ensureControl();
    observer = await WireConnection.connect('observer');
    if (previousObserverId && String(observer.clientId) === previousObserverId) throw new Error('observer reconnect reused client identity');
    if (completesBoot) lifecyclePolicy.activate();
    focusState = null;
    syncFocus();
    status.textContent = 'Observer reconnected; waiting for canonical snapshot…';
    scheduleViewportResize();
    telemetry.record('reconnect_ready', {observer:String(observer.clientId), control:String(control.clientId)});
    updateFacts();
  })();
  try {
    await reconnectTask;
  } finally {
    reconnectTask = null;
  }
}

reconnect.addEventListener('click', () => reconnectAll({manual:true}).catch(fail));

function fail(error) {
  console.error(error);
  const networkFailure = /websocket|open timeout|open error|connection closed/i.test(error.message);
  telemetry?.record('failure', {network:networkFailure});
  status.textContent = `${networkFailure ? 'DISCONNECTED' : 'FAIL'}: ${error.message}`;
  factsNode.textContent = error.stack ?? String(error);
}

load().catch(fail);
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(error => console.warn('service worker registration failed', error));
}
