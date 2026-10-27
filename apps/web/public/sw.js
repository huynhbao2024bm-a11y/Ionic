const CACHE_NAME = 'ionic-shell-v2';
const APP_SHELL = [
  './index.html',
  './manifest.webmanifest',
  './ionic-logo-lockup.png',
  './ionic-icon-192.png',
  './ionic-icon-512.png',
  './ionic-icon-maskable.png',
  './apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    const shellUrls = APP_SHELL.map((path) => new URL(path, self.registration.scope).href);
    await cache.addAll(shellUrls);

    const indexUrl = new URL('./index.html', self.registration.scope).href;
    const response = await fetch(indexUrl);
    if (!response.ok) return;
    const html = await response.text();
    await cache.put(indexUrl, new Response(html, { headers: response.headers }));

    const assetRefs = [...html.matchAll(/(?:src|href)="([^"]+\.(?:js|css))"/g)].map((match) => match[1]);
    const assetUrls = assetRefs.map((path) => new URL(path, indexUrl).href);
    await Promise.all(assetUrls.map((url) => cache.add(url).catch(() => undefined)));
  })());
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(
      keys.filter((key) => key.startsWith('ionic-shell-') && key !== CACHE_NAME).map((key) => caches.delete(key)),
    )),
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET' || new URL(event.request.url).origin !== self.location.origin) return;
  if (event.request.mode === 'navigate') {
    const indexUrl = new URL('./index.html', self.registration.scope).href;
    event.respondWith(fetch(event.request).catch(() => caches.match(indexUrl)));
    return;
  }
  if (['script', 'style', 'font'].includes(event.request.destination)) {
    event.respondWith(caches.match(event.request).then((cached) => cached ?? fetch(event.request)));
    return;
  }
  if (event.request.destination === 'image' && APP_SHELL.some((path) => new URL(path, self.registration.scope).href === event.request.url)) {
    event.respondWith(caches.match(event.request).then((cached) => cached ?? fetch(event.request)));
  }
});
