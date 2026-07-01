# Enkela's Bookshelf — sync worker

A tiny Cloudflare Worker that gives the bookshelf app **per-user accounts** (email + full
name + password) and **private cross-device sync**. Free-forever on Cloudflare's Workers +
KV free plan (no credit card).

## Endpoints
- `POST /api/register` `{ email, fullName, password }` → `{ token, user }`
- `POST /api/login` `{ email, password }` → `{ token, user }`
- `GET  /api/data` (Bearer token) → `{ blob, updatedAt }`
- `PUT  /api/data` (Bearer token) `{ blob, updatedAt, baseUpdatedAt | force }` → `{ ok, updatedAt }` (or `409` with the server copy on conflict)

Passwords are salted + PBKDF2-hashed (never stored in plaintext); sessions are HMAC-signed
tokens (30-day expiry) signed with the `AUTH_SECRET` secret.

## Local development (no Cloudflare account needed)
```sh
cd sync-worker
npm install
npx wrangler dev        # serves at http://127.0.0.1:8787 with a local KV + .dev.vars secret
```
Then in the app (served locally), set the API override once in the browser console:
```js
localStorage.setItem("enkelas-sync-api", "http://127.0.0.1:8787"); location.reload();
```

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
