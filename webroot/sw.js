/* Hamedis Performance Core - service worker
 *
 * Purpose is installability and shell caching ONLY.
 *
 * Deliberately does NOT cache API responses. This app reports live CPU
 * temperature, battery state and charge current. Serving a stale reading
 * from cache would be worse than showing nothing - you could be looking
 * at a 45C reading from ten minutes ago while the phone is at 70C now.
 * Every /cgi-bin/ request goes straight to the network, always.
 */

const SHELL = 'hpc-shell-v5';   // bumped: index.html changed, force cache refresh

// Only the static shell is cached, so the app opens instantly offline
// and Chrome treats it as installable.
const SHELL_FILES = [
  '/',
  '/index.html',
  '/icon.svg',
  '/icon-maskable.svg',
  '/manifest.webmanifest'
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(SHELL)
      .then((c) => c.addAll(SHELL_FILES))
      .then(() => self.skipWaiting())
      .catch(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys.filter((k) => k !== SHELL).map((k) => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);

  // Live data: never cached, never served stale.
  if (url.pathname.startsWith('/cgi-bin/')) {
    e.respondWith(fetch(e.request));
    return;
  }

  if (e.request.method !== 'GET') {
    e.respondWith(fetch(e.request));
    return;
  }

  // Shell: network first so updates land immediately after a reflash,
  // falling back to cache when the server is not running yet.
  e.respondWith(
    fetch(e.request)
      .then((res) => {
        if (res && res.status === 200 && res.type === 'basic') {
          const copy = res.clone();
          caches.open(SHELL).then((c) => c.put(e.request, copy)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(e.request).then((r) => r || caches.match('/index.html')))
  );
});
