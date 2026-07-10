/* Service worker: caches the app shell so Enkela's Bookshelf works offline
 * and installs to the home screen. Bump CACHE when files change. */

// lib.webworker types `self` as a plain WorkerGlobalScope; re-view it as the
// service-worker scope so skipWaiting/clients/event types check correctly.
const sw = self as unknown as ServiceWorkerGlobalScope;

const CACHE = "enkelas-bookshelf-v31";
const SHELL = [
  "./",
  "./index.html",
  "./styles.css",
  "./app.js",
  "./reader.js",
  "./vendor/jszip.min.js",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png",
  "./apple-touch-icon.png",
];

sw.addEventListener("install", (e) => {
  // cache:"reload" bypasses the browser HTTP cache — otherwise a version bump
  // can precache STALE files the browser had lying around, and users keep
  // running old code until the next bump.
  e.waitUntil(
    caches.open(CACHE)
      .then((c) => c.addAll(SHELL.map((u) => new Request(u, { cache: "reload" }))))
      .then(() => sw.skipWaiting())
  );
});

sw.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => sw.clients.claim())
  );
});

sw.addEventListener("fetch", (e) => {
  const req = e.request;
  // Only handle same-origin GETs; let cover-image API calls go straight to network.
  if (req.method !== "GET" || new URL(req.url).origin !== sw.location.origin) return;

  const isHTML = req.mode === "navigate" || (req.headers.get("accept") || "").indexOf("text/html") >= 0;
  if (isHTML) {
    // Network-first for the page itself, so updates appear immediately when online.
    e.respondWith(
      fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(req, copy));
        return res;
      }).catch(() => caches.match(req).then((c) => c || caches.match("./index.html")) as Promise<Response>)
    );
    return;
  }
  // Cache-first for static assets (fast + offline), refresh in the background.
  e.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req).then((res) => {
        if (res && res.status === 200) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
        return res;
      }).catch(() => cached) as Promise<Response>;
      return cached || network;
    })
  );
});
