import assert from 'node:assert/strict';
import fs from 'node:fs';

const host = fs.readFileSync('web/host.mjs', 'utf8');
const index = fs.readFileSync('web/index.html', 'utf8');
const serviceWorker = fs.readFileSync('web/sw.js', 'utf8');
const frameV3 = fs.readFileSync('web/frame_v3.mjs', 'utf8');
const frameV4 = fs.readFileSync('web/frame_v4.mjs', 'utf8');
const legacyWebgl = fs.readFileSync('web/webgl_backend.mjs', 'utf8');
const webglV3 = fs.readFileSync('web/webgl_backend_v3.mjs', 'utf8');
const webglV4 = fs.readFileSync('web/webgl_backend_v4.mjs', 'utf8');
const renderBuild = fs.readFileSync('build.zig', 'utf8');
const gateway = fs.readFileSync('../gateway/src/main.zig', 'utf8');

const imports = [...host.matchAll(/from\s+['"]\.\/([^'"]+)['"]/g)].map(match => match[1]);
const modules = [...new Set(['host.mjs', ...imports])].sort();
const shellBlock = serviceWorker.match(/const SHELL = \[(.*?)\];/s);
assert(shellBlock, 'service worker SHELL list is missing');
const shell = new Set([...shellBlock[1].matchAll(/'([^']+)'/g)].map(match => match[1]));

for (const module of modules) {
  const route = `/${module}`;
  assert(shell.has(route), `${module} is imported by the browser host but absent from the offline shell`);
  assert(renderBuild.includes(module), `${module} is imported by the browser host but absent from the render install graph`);
  assert(gateway.includes(`.target = "${route}"`), `${module} is imported by the browser host but absent from the gateway allowlist`);
}

// Every incompatible browser vocabulary has a generation-specific URL. Older
// service workers may still fall back /host.mjs or /render.wasm from their
// shell, but cannot substitute v2/v3 consumers for a v4 host.
for (const route of [
  '/frame_v3.mjs', '/frame_v4.mjs',
  '/webgl_backend.mjs', '/webgl_backend_v3.mjs', '/webgl_backend_v4.mjs',
]) {
  assert(shell.has(route), `${route} must remain in the coherent current shell`);
  assert(renderBuild.includes(route.slice(1)), `${route} must remain in the render install graph`);
  assert(gateway.includes(`.target = "${route}"`), `${route} must remain in the gateway allowlist`);
}
assert(host.includes("from './frame_v4.mjs'"), 'v4 host must negotiate its renderer vocabulary');
assert(host.includes("from './webgl_backend_v4.mjs'"), 'v4 host must use a generation-specific WebGL module');
assert(!host.includes("from './frame_v3.mjs'"), 'v4 host must not consume the v3 frame module');
assert(!host.includes("from './webgl_backend_v3.mjs'"), 'v4 host must not consume the v3 WebGL module');
assert(!host.includes("from './webgl_backend.mjs'"), 'v4 host must not consume the legacy WebGL module');
assert(webglV3.includes("from './frame_v3.mjs'"), 'v3 WebGL backend must consume the shared positional contract');
assert(!legacyWebgl.includes("from './frame_v3.mjs'"), 'legacy WebGL URL must remain v2-compatible for an old host');
assert(legacyWebgl.includes('command.k'), 'legacy WebGL URL must retain the v2 object command vocabulary');
assert(frameV3.includes('rv_frame_format') && frameV3.includes('rv_set_frame_format'), 'v3 host contract must negotiate renderer format explicitly');
assert(frameV3.includes('rv_reset'), 'v3 frame mismatch must clear renderer pending-ack state');
assert(frameV4.includes('rv_frame_format') && frameV4.includes('rv_set_frame_format'), 'v4 host contract must negotiate renderer format explicitly');
assert(frameV4.includes('rv_commands_ptr') && frameV4.includes('rv_commands_stride'), 'v4 host contract must bind the explicit binary command lane');
assert(frameV4.includes('rv_reset'), 'v4 frame mismatch must clear renderer pending-ack state');
assert(webglV4.includes('frame.commands.count'), 'v4 WebGL backend must consume the bounded binary command view');
const leaseTransition = 'frame.uploads.length !== 0 || frame.removals.length !== 0';
assert(host.includes(leaseTransition), 'v4 Canvas lease reconciliation must be transition-driven');
assert(webglV4.includes(leaseTransition), 'v4 WebGL lease reconciliation must be transition-driven');
assert(host.includes('!webglBackend.admit(frame)'),
  'v4 WebGL host must use the backend one-shot admission before drawing');
assert(webglV4.includes('this.admittedCommands = null;\n    if (!webglFrameEligible(frame)) return false;') &&
  webglV4.includes('const admittedCommands = this.admittedCommands;') &&
  webglV4.includes('if (admittedCommands !== frame.commands)'),
  'v4 WebGL draw must consume the exact command view admitted by the backend');
assert(host.includes("const identity = String(missing.q[0]) + ':';") &&
  host.includes('key !== missing.key && key.startsWith(identity)'),
  'v4 external refill must replace older generations of the same logical browser resource');
const refillStage = 'if (!refill.reused) resources.set(missing.key, refill.resource);';
const refillAccept = 'if (renderer.exports.rv_accept_external() !== 1) {';
const refillRollback = 'if (!refill.reused) resources.delete(missing.key);';
assert(host.includes(refillStage) && host.includes(refillAccept) && host.includes(refillRollback),
  'v4 external refill must stage immediately before accept and roll back rejection');
assert(host.indexOf(refillStage) < host.indexOf(refillAccept) &&
  host.indexOf(refillAccept) < host.indexOf("const identity = String(missing.q[0]) + ':';"),
  'v4 external refill may retire older generations only after renderer acceptance');
assert(serviceWorker.includes("const CACHE = 'howl-web-canary-v45-web-frame-v4'"), 'v4 shell cache generation is not current');

assert(index.includes('id="zoom-button"'), 'browser shell must expose the native presentation zoom control');
assert(index.includes('id="selection-overlay"'), 'browser shell must expose the client-local selection overlay');
assert(index.includes('>16px</button>'), 'browser presentation zoom must boot at the normal 16px preset');
assert(host.includes('const presentationPixels = [16, 12, 9];'), 'browser presentation presets drifted from maintained native presets');
assert(host.includes('const presentationCellWidths = [10, 8, 6];'), 'browser cell widths drifted from maintained native presets');
assert(host.includes('const presentationLineHeights = [20, 15, 12];'), 'browser line heights drifted from maintained native presets');
assert(host.includes('rv_init_presentation'), 'browser renderer must expose explicit HiDPI presentation geometry');
assert(host.includes("telemetry.record('presentation_zoom'"), 'browser presentation zoom must remain observable in telemetry');

for (const asset of ['nerd-font.bin', 'nerd-font-license.txt']) {
  const route = `/${asset}`;
  assert(shell.has(route), `${asset} is required by the browser host but absent from the offline shell`);
  assert(renderBuild.includes(asset), `${asset} is required by the browser host but absent from the render install graph`);
  assert(gateway.includes(`.target = "${route}"`), `${asset} is required by the browser host but absent from the gateway allowlist`);
}

console.log(JSON.stringify({status:'pass', browserModules:modules.length, offline:true, installed:true, gateway:true}));
