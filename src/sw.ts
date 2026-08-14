/* Service worker: caches the app shell so Enkela's Bookshelf works offline
 * and installs to the home screen. Bump CACHE when files change. */

// lib.webworker types `self` as a plain WorkerGlobalScope; re-view it as the
// service-worker scope so skipWaiting/clients/event types check correctly.
const sw = self as unknown as ServiceWorkerGlobalScope;

const CACHE = "enkelas-bookshelf-v49";
const SHELL = [
  "./",
  "./index.html",
  // Linked from the register form, so it has to survive offline too — without
  // it the HTML fallback hands back index.html and tapping "Terms" silently
  // reopens the app.
  "./terms.html",
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
  // Cache-first for static assets (fast + offline). A cache hit is served as-is
  // and NOT revalidated: this used to fire a network request for every cached
  // asset on every load, which is a full second copy of the shell over the wire
  // for no benefit — the CACHE version bump is what ships new files.
  e.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((res) => {
        if (res && res.status === 200) {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => { /* cache full */ });
        }
        return res;
      }).catch(() =>
        // Nothing cached and the network is gone. Answer with a real Response:
        // resolving respondWith to undefined makes the request fail as an
        // opaque network error instead.
        new Response("", { status: 504, statusText: "Offline and not cached" })
      );
    })
  );
});
