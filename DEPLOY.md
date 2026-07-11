# Deploy checklist — Enkela's Bookshelf

Two things ship independently:

1. **The app** (static files) → **GitHub Pages**
2. **The sync API** (`sync-worker/`) → **Cloudflare Workers**

They talk via `SYNC_API` in `app.js` (currently
`https://enkelas-bookshelf-sync.enkela.workers.dev`).

---

## A. Ship the app (static site)

The app is plain static files served from the repo root by GitHub Pages
(repo `Qelik/enkelas-bookshelf`, branch `main`, live at
<https://qelik.github.io/enkelas-bookshelf/>).

0. **Build from TypeScript.** Sources are `src/*.ts`; the served `app.js`/
   `reader.js`/`sw.js` at the root are compiler output and are COMMITTED.
   After editing any `src/*.ts`: `npm run build`, then commit the sources
   AND the regenerated JS together. Never hand-edit the root JS files —
   the next build overwrites them. `npm run check` must pass (it also
   type-checks the worker) before shipping.
1. **Bump the service-worker cache** in `src/sw.ts` (`const CACHE = "enkelas-bookshelf-vNN"`).
   Installed devices keep running old code until this changes — skip it and your
   changes won't reach anyone who already opened the app. Also bump `APP_VERSION`
   in `src/app.ts` so the version shown in **Settings → App** matches (then rebuild).
2. **Commit & push to `main`.** Pages auto-rebuilds (~1 min).
3. **Verify live:**
   - Hard-reload <https://qelik.github.io/enkelas-bookshelf/> (or use
     **Settings → App → Refresh app files**, which clears caches + re-registers the SW).
   - `curl -sI https://qelik.github.io/enkelas-bookshelf/app.js | head -1` → `200`.
4. **If the Pages build sticks in "queued"/fails:** don't rerun the stuck one —
   trigger a fresh build:
   `gh api -X POST repos/Qelik/enkelas-bookshelf/pages/builds`
   (goes live in <1 min).

> **SW cache gotcha:** `sw.js` is cache-first for CSS/JS, so the *first* reload
> after a deploy can still show the stale file — reload twice, or use
> **Refresh app files**.

---

## B. Ship the sync worker

The worker lives in `sync-worker/` (`src/worker.js`, `wrangler.toml`). It is
**not** served by Pages.

### Two ways it deploys — know which is active

- **Auto (Workers Builds / Git integration):** on every push to `main`,
  Cloudflare runs `npx wrangler deploy` from the **repo root**. The root
  **`wrangler.jsonc`** exists so that root deploy targets the *real* worker
  (`main: sync-worker/src/worker.js` + the `BOOKSHELF` KV binding). This is the
  current setup and it works.
  - ⚠️ **Keep `wrangler.jsonc` in sync with `sync-worker/wrangler.toml`.** If you
    change the worker's entry point, name, or KV binding in one, mirror it in the
    other, or a push will deploy a broken worker.
  - ⚠️ **Never merge the Cloudflare bot PR** (`cloudflare/workers-autoconfig`,
    PR #1). It would deploy a static site over the API. Close it, keep it closed.
- **Manual:** `cd sync-worker && npx wrangler deploy` (already OAuth-logged-in as
  `qelik`). Use this when iterating on the worker without pushing.

### AUTH_SECRET

- Signs the 30-day HMAC login tokens. It is a **Cloudflare secret**, never in git.
- Set / rotate it:
  `cd sync-worker && openssl rand -hex 32 | npx wrangler secret put AUTH_SECRET`
- Rotating it just forces everyone to log in again — **password hashes and book
  data survive** (AUTH_SECRET only signs tokens, it doesn't encrypt data).

---

## C. Post-deploy health checks

1. **Worker is up (no auth needed):**
   ```
   curl -s https://enkelas-bookshelf-sync.enkela.workers.dev/
   ```
   Expect: `{"ok":true,"service":"enkelas-bookshelf-sync"}`
   - A `404`/HTML here usually means a bad root deploy clobbered the worker →
     redeploy from `sync-worker/` and re-check.
2. **Auth endpoint responds:**
   ```
   curl -s -o /dev/null -w "%{http_code}\n" \
     https://enkelas-bookshelf-sync.enkela.workers.dev/api/data
   ```
   Expect: `401` (no token) — proves the route exists and auth is enforced.
3. **CORS header present** (app is cross-origin to the worker):
   ```
   curl -sI https://enkelas-bookshelf-sync.enkela.workers.dev/ | grep -i access-control
   ```
4. **In-app:** sign in on the live site, add a book, confirm the header shows
   **☁️ Synced · just now** and **Settings → App** shows the current version.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Login says "Something went wrong" after infra changes | `AUTH_SECRET` was wiped/rotated by a bad deploy | Re-set `AUTH_SECRET` (section B); users re-log-in once, data safe |
| Worker `/` returns 404 or HTML | Root deploy shipped a static site over the worker | `cd sync-worker && npx wrangler deploy`; confirm `wrangler.jsonc` still points at `sync-worker/src/worker.js` |
| App changes not showing on a device | Stale SW cache | Bump `sw.js` CACHE + `APP_VERSION`, redeploy; on-device use **Settings → Refresh app files** |
| Pages build stuck | GitHub flakiness | `gh api -X POST repos/Qelik/enkelas-bookshelf/pages/builds` |

## Quick reference

- App: <https://qelik.github.io/enkelas-bookshelf/>
- Worker: <https://enkelas-bookshelf-sync.enkela.workers.dev>
- `SYNC_API` lives in `app.js` (top of the IIFE); per-device override via
  `localStorage["enkelas-sync-api"]`.
- KV namespace `BOOKSHELF` id: `cdeead88aa7d42579a16de9aa549fc14`.
