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

### AUTH_SECRET (required)

- Signs the 30-day HMAC login tokens. It is a **Cloudflare secret**, never in git.
- Set / rotate it:
  `cd sync-worker && openssl rand -hex 32 | npx wrangler secret put AUTH_SECRET`
- **Must be at least 32 characters.** The worker refuses every request with a
  `500` below that rather than pretend to authenticate — a short signing key makes
  the session tokens brute-forceable, which is every account at once.
- Rotating it just forces everyone to log in again — **password hashes and book
  data survive** (AUTH_SECRET only signs tokens, it doesn't encrypt data).

### Password-reset email (optional but recommended)

Without these, "Forgot your password?" is **hidden in the app** and a lost password
means a lost account — there is no admin backdoor by design. Reset uses
[Resend](https://resend.com) (free tier is plenty; no SDK, one `fetch`):

```bash
cd sync-worker
npx wrangler secret put RESEND_API_KEY          # re_... from the Resend dashboard
npx wrangler secret put RESET_FROM              # e.g. Bookshelf <no-reply@yourdomain>
npx wrangler secret put APP_URL                 # https://qelik.github.io/enkelas-bookshelf
```

- `RESET_FROM` must be on a domain verified in Resend, or delivery silently fails
  (the worker logs it — `npx wrangler tail`).
- **All three are required.** `/api` reports `passwordReset: false` until every one
  is set, and the app hides the link rather than mailing a URL that 404s — there is
  deliberately no default `APP_URL` to guess with.
- `APP_URL` builds the reset link. The token rides in the URL **fragment**
  (`#reset/<token>`), so it never reaches a server log or a `Referer` header, and
  the app strips it from the address bar as soon as it's read.
- Links last 30 minutes, work **once**, and redeeming one signs out every other
  device on that account.
- Check it's live: `curl -s <worker>/api` should report `"passwordReset": true`.

### ALLOWED_ORIGINS (optional)

Comma-separated list of origins allowed to call the API, e.g.
`https://qelik.github.io,http://localhost:8123`. Leave unset to allow any origin
— safe here because auth is a `Bearer` header rather than an ambient cookie, so a
hostile page has no credential to replay. Setting it is cheap defence in depth.

### RESET_DEBUG — local development only

`--var RESET_DEBUG:1` makes `/api/password/forgot` return the reset link in the
response body so the flow is testable with no mailer. **In production this is an
account-takeover primitive for anyone who knows an email address.** Pass it to
`wrangler dev` only; `scripts/preflight.mjs` fails the build if it ever appears in
a committed wrangler config.

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
3. **CORS + security headers present** (app is cross-origin to the worker):
   ```
   curl -sI https://enkelas-bookshelf-sync.enkela.workers.dev/ | grep -iE 'access-control|x-content-type|cache-control'
   ```
   Expect `access-control-allow-origin`, `x-content-type-options: nosniff` and
   `cache-control: no-store`.
4. **Password reset is wired up (or knowingly isn't):**
   ```
   curl -s https://enkelas-bookshelf-sync.enkela.workers.dev/api
   ```
   `"passwordReset": true` means the mailer is configured. `false` means the app
   hides "Forgot your password?" — see section B.
5. **In-app:** sign in on the live site, add a book, confirm the header shows
   **☁️ Synced · just now** and **Settings → App** shows the current version.
6. **Change password once** from the account menu: the device you did it on stays
   signed in, and any other signed-in device drops to **🔑 Session expired** on its
   next sync. That round trip proves token revocation is live.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Login says "Something went wrong" after infra changes | `AUTH_SECRET` was wiped/rotated by a bad deploy | Re-set `AUTH_SECRET` (section B); users re-log-in once, data safe |
| Every request returns `500 "Server misconfigured (weak AUTH_SECRET)"` | `AUTH_SECRET` is under 32 chars | Re-set it with `openssl rand -hex 32` (section B) |
| "Forgot your password?" doesn't appear in the app | No mailer configured (`/api` reports `passwordReset: false`) | Set `RESEND_API_KEY` + `RESET_FROM` + `APP_URL` (section B) |
| Reset emails never arrive but the app says they were sent | `RESET_FROM` domain isn't verified in Resend | `npx wrangler tail` shows the rejection; verify the domain |
| Everyone is signed out after one person changed their password | Expected — a change/reset revokes that account's other tokens only | Nothing to fix; sign in again |
| "Too many sign-in attempts" during testing | Per-email (10) or per-IP (30) failure cap, 15-minute window | Wait it out, or use a different email; caps live in `worker.ts` |
| Worker `/` returns 404 or HTML | Root deploy shipped a static site over the worker | `cd sync-worker && npx wrangler deploy`; confirm `wrangler.jsonc` still points at `sync-worker/src/worker.js` |
| App changes not showing on a device | Stale SW cache | Bump `sw.js` CACHE + `APP_VERSION`, redeploy; on-device use **Settings → Refresh app files** |
| Pages build stuck | GitHub flakiness | `gh api -X POST repos/Qelik/enkelas-bookshelf/pages/builds` |

## Quick reference

- App: <https://qelik.github.io/enkelas-bookshelf/>
- Worker: <https://enkelas-bookshelf-sync.enkela.workers.dev>
- `SYNC_API` lives in `app.js` (top of the IIFE); per-device override via
  `localStorage["enkelas-sync-api"]`.
- KV namespace `BOOKSHELF` id: `cdeead88aa7d42579a16de9aa549fc14`.
