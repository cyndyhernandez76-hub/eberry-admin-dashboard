/**
 * eBerry HRIS service worker — minimal, network-first.
 *
 * Strategy:
 *   - HTML / navigations: network-first, fall back to cached shell when offline.
 *   - Hashed assets (JS/CSS/fonts/images under /assets/): cache-first (immutable).
 *   - Everything else: network only (no caching) — keeps Supabase calls fresh
 *     and avoids the "stale dashboard" trap we hit pre-PWA.
 *
 * The cache name is bumped on every deploy via {{BUILD_ID}} substitution at
 * build time. Old caches are pruned in 'activate'.
 */
const CACHE_VERSION = 'eberry-v1-2026-04-30';
const SHELL_CACHE = `${CACHE_VERSION}-shell`;
const ASSET_CACHE = `${CACHE_VERSION}-assets`;
const SHELL_URL = '/eberry-admin-dashboard/index.html';

// Install: precache the app shell so the dashboard launches offline.
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) => cache.addAll([SHELL_URL])),
  );
  self.skipWaiting();
});

// Activate: clean up any prior version's caches.
self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const keys = await caches.keys();
      await Promise.all(
        keys
          .filter((k) => !k.startsWith(CACHE_VERSION))
          .map((k) => caches.delete(k)),
      );
      await self.clients.claim();
    })(),
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  // Only handle GET — POST/PUT/PATCH go straight to network.
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // Don't intercept third-party (Supabase, Google Fonts, etc.).
  if (url.origin !== self.location.origin) return;

  // Navigation requests (the HTML shell).
  if (req.mode === 'navigate') {
    event.respondWith(
      (async () => {
        try {
          const fresh = await fetch(req);
          // Update the cached shell on every successful navigation fetch.
          const cache = await caches.open(SHELL_CACHE);
          cache.put(SHELL_URL, fresh.clone()).catch(() => { /* ignore */ });
          return fresh;
        } catch {
          const cache = await caches.open(SHELL_CACHE);
          const cached = await cache.match(SHELL_URL);
          return cached || new Response('Offline', { status: 503 });
        }
      })(),
    );
    return;
  }

  // Hashed assets — cache-first, since Vite output filenames include a content
  // hash so they are immutable.
  if (url.pathname.includes('/assets/')) {
    event.respondWith(
      (async () => {
        const cache = await caches.open(ASSET_CACHE);
        const cached = await cache.match(req);
        if (cached) return cached;
        try {
          const fresh = await fetch(req);
          if (fresh.ok) cache.put(req, fresh.clone()).catch(() => { /* ignore */ });
          return fresh;
        } catch {
          return cached || Response.error();
        }
      })(),
    );
    return;
  }

  // Everything else: network only.
});
