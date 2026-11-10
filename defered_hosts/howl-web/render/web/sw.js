const CACHE = 'howl-web-canary-v45-web-frame-v4';
const SHELL = [
  '/', '/host.mjs', '/frame_v3.mjs', '/frame_v4.mjs', '/webgl_backend.mjs', '/webgl_backend_v3.mjs', '/webgl_backend_v4.mjs', '/lifecycle_policy.mjs', '/input.mjs', '/pointer_input.mjs', '/history.mjs', '/selection.mjs', '/control_queue.mjs', '/telemetry.mjs', '/frame_scheduler.mjs', '/display_schedule.mjs', '/resize_policy.mjs', '/style.css', '/runtime.mjs', '/wire.wasm',
  '/render.wasm', '/font.bin', '/fallback-font.bin', '/nerd-font.bin', '/manifest.webmanifest', '/icon.png', '/font-licences.txt', '/nerd-font-license.txt', '/dependencies.txt',
];
const SHELL_SET = new Set(SHELL);

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await cache.addAll(SHELL);
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) if (name !== CACHE) await caches.delete(name);
    await self.clients.claim();
  })());
});

self.addEventListener('message', event => {
  if (event.data !== 'howl.promote-waiting-v1') return;
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || !SHELL_SET.has(url.pathname)) return;
  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    try {
      const response = await fetch(event.request, {cache: 'no-store'});
      // An Access redirect or login response is authentication UI, never app cache.
      if (response.ok && !response.redirected && new URL(response.url).origin === self.location.origin) {
        await cache.put(event.request, response.clone());
      }
      return response;
    } catch (error) {
      const cached = await cache.match(event.request);
      if (cached) return cached;
      throw error;
    }
  })());
});
