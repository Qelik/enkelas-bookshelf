# Enkela's Bookshelf — sync worker

A tiny Cloudflare Worker that gives the bookshelf app **per-user accounts** (email + full
name + password) and **private cross-device sync**. Free-forever on Cloudflare's Workers +
KV free plan (no credit card).

## Endpoints
- `POST /api/register` `{ email, fullName, password }` → `{ token, user }`
- `POST /api/login` `{ email, password }` → `{ token, user }`
- `GET  /api/data` (Bearer token) → `{ blob, updatedAt }`
- `PUT  /api/data` (Bearer token) `{ blob, updatedAt, baseUpdatedAt | force }` → `{ ok, updatedAt }` (or `409` with the server copy on conflict)
- `DELETE /api/account` (Bearer token) `{ password }` → `{ ok, deleted: { clubs, recs } }`

Passwords are salted + PBKDF2-hashed (never stored in plaintext); sessions are HMAC-signed
tokens (30-day expiry) signed with the `AUTH_SECRET` secret.

### Moderation (needs the D1 tables — see *Schema migrations*)
- `POST /api/recs/<id>/report` `{ reason, detail? }` → `{ ok, hidden }`
- `POST /api/clubs/<id>/comments/<commentId>/report` `{ reason, detail? }` → `{ ok, hidden }`
- `GET  /api/blocks` · `POST /api/blocks` `{ uid }` · `DELETE /api/blocks/<uid>`
- `GET  /api/moderation/reports` · `POST /api/moderation/reports/<id>` `{ action }` — owner only, gated on `ADMIN_UIDS`

`reason` is one of `spam`, `harassment`, `sexual`, `violence`, `hate`, `spoiler`, `other`.
Three **distinct** reporters hide an item automatically; the review queue is asynchronous.
Blocks are applied per viewer at read time — nothing is deleted, and the blocked person is
never told. Non-admins get `404` (not `403`) from `/api/moderation/*`.

To find your own uid for `ADMIN_UIDS`, the `user` object returned by login carries `id`.

## Schema migrations

> **Run the schema BEFORE deploying a worker that uses new tables.** The clubs, recs,
> report and block queries name their tables directly, so a worker deployed ahead of the
> migration answers `500 no such table` on those routes. The file is idempotent
> (`CREATE TABLE IF NOT EXISTS` throughout) — re-running it on a live database is safe.

```sh
npx wrangler d1 execute enkelas-clubs --remote --file schema-clubs.sql
```

Locally, `--config` is required or wrangler seeds the wrong state directory:

```sh
cd sync-worker && npx wrangler d1 execute enkelas-clubs --local --config wrangler.toml --file schema-clubs.sql
```

## Local development (no Cloudflare account needed)
```sh
cd sync-worker
npm install
npm run dev             # serves at http://127.0.0.1:8787 with a local KV + D1
```
Then in the app (served locally), set the API override once in the browser console:
```js
localStorage.setItem("enkelas-sync-api", "http://127.0.0.1:8787"); location.reload();
```

### `npm run dev`, not `npx wrangler dev`

**Wrangler 4.110.0 does not load `.dev.vars` or `.env`.** Verified: neither file
appears in the bindings table, `--env-file` makes no difference, and there is no
warning — the Worker just starts without `AUTH_SECRET` and returns
`500 {"error":"Server not configured (missing AUTH_SECRET)."}` on every request.
So `npm run dev` reads the secret out of `.env` and passes it with `--var`, which
does work. Confirm it took by looking for this line at startup:

```
env.AUTH_SECRET ("(hidden)")     Environment Variable   local
```

If that line is missing, nothing will work and the error will not say why. A
wrangler upgrade (4.118 was available at the time of writing) may well fix the
file loading and make the `--var` hop unnecessary — check the banner after
upgrading, and simplify the script if the line appears without it.

`AUTH_SECRET` must be **at least 32 characters** (`MIN_SECRET_CHARS` in
`worker.ts`). A shorter one gets a *different* 500 — "weak AUTH_SECRET" — so the
two failures are distinguishable from the response alone.

The secret lives in **`.env` only** (gitignored). `.dev.vars` was deleted rather
than kept in step: wrangler doesn't read it, the script doesn't either, and a
second copy of a secret is a copy that silently goes stale — rotate it there and
nothing changes, with no error to say so.

Changing the secret invalidates every token signed with the old one, so the app
reports the session as expired and asks for a fresh sign-in. The accounts
themselves live in the local D1 and survive.

## Deploy (one-time)
```sh
cd sync-worker
npm install
npx wrangler login                                   # opens the browser to authorize
npx wrangler kv namespace create BOOKSHELF           # paste id into wrangler.toml
npx wrangler kv namespace create BOOKSHELF --preview # paste preview_id into wrangler.toml
npx wrangler secret put AUTH_SECRET                  # paste a long random string
npx wrangler deploy                                  # prints the https://<name>.<sub>.workers.dev URL
```
Put that URL into `SYNC_API` in `../app.js`, commit, and GitHub Pages redeploys.

## Reset a forgotten password (owner, until email reset exists)
```sh
# find the user key, then overwrite it with a fresh hash — or simplest: delete + let them re-register
npx wrangler kv key delete --binding BOOKSHELF "user:their@email.com"
```
