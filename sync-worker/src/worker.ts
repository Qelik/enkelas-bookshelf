/* Enkela's Bookshelf — sync worker (Cloudflare Workers + KV).
 *
 * Per-user accounts (email + full name + password) and a private data blob per user.
 * No third-party libraries: password hashing via PBKDF2 (WebCrypto), sessions via
 * HMAC-signed tokens. KV keys:
 *   user:<email-lowercased>  -> { id, email, fullName, salt, hash, iterations, createdAt, pwChangedAt }
 *   uid:<userId>             -> <email>   reverse index; a token carries only a uid,
 *                                         so without this we can't load the account
 *                                         behind it (change-password needs to).
 *   data:<userId>            -> { blob, updatedAt }
 *   rev:<userId>             -> unix seconds; every token issued before this is dead
 *   reset:<sha256(token)>    -> { email, uid, at }   single-use, 30 min
 *   throttle:<email>         -> failed logins for that account   (15 min)
 *   ipfail:<ip>              -> failed logins from that IP       (15 min)
 *   ipreg:<ip>               -> accounts created from that IP    (24 h)
 *   resetreq:<email>         -> reset emails requested           (1 h)
 *   ipreset:<ip>             -> reset requests from that IP      (1 h)
 *   pwchange:<userId>        -> wrong current-password guesses   (15 min)
 *   pwdelete:<userId>        -> wrong password guesses on delete (15 min)
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

// ---- CORS + security headers ------------------------------------------------
// Applied once, to every response, in fetch() — so no handler can forget them.
const SECURITY_HEADERS: Record<string, string> = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  // Every response here is either a credential, private data, or a rate-limit
  // verdict. None of it should sit in a shared cache.
  "Cache-Control": "no-store",
};
function corsHeaders(request: Request, env: Env) {
  const h: Record<string, string> = {
    // DELETE is here for /api/account and /api/blocks/<uid>. A browser preflights
    // any method outside the simple set, and an unlisted one is refused before
    // the request is ever made — so omitting it breaks those two routes in the
    // web client only, while curl keeps working. Easy to lose an afternoon to.
    "Access-Control-Allow-Methods": "GET,POST,PUT,DELETE,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
    ...SECURITY_HEADERS,
  };
  const allowed = String(env.ALLOWED_ORIGINS || "").split(",").map((s) => s.trim()).filter(Boolean);
  const origin = request.headers.get("Origin") || "";
  // Tokens travel in a header, not a cookie, so a wildcard can't be replayed by
  // a hostile page the way an ambient cookie can — but naming the real origins
  // still stops other sites from casually driving this API, so honour the list
  // when it's set. Unset keeps the old behaviour (and local dev working).
  if (!allowed.length) h["Access-Control-Allow-Origin"] = "*";
  else if (origin && allowed.indexOf(origin) >= 0) h["Access-Control-Allow-Origin"] = origin;
  // A disallowed Origin gets no ACAO header at all: the browser blocks the read.
  return h;
}
function json(data: unknown, status = 200, extra?: Record<string, string>) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...(extra || {}) },
  });
}
/** Bodies for the auth endpoints are a few hundred bytes; refuse anything absurd. */
const SMALL_BODY_BYTES = 64 * 1024;
async function smallJson(request: Request): Promise<any> {
  if (Number(request.headers.get("content-length") || 0) > SMALL_BODY_BYTES) return {};
  return request.json<any>().catch(() => ({}));
}

// ---- base64url --------------------------------------------------------------
function b64url(bytes: Uint8Array | ArrayBuffer) {
  const b = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : bytes;
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToBytes(str: string) {
  str = String(str).replace(/-/g, "+").replace(/_/g, "/");
  while (str.length % 4) str += "=";
  const bin = atob(str);
  const arr = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  return arr;
}
function randomBytes(n: number) { const a = new Uint8Array(n); crypto.getRandomValues(a); return a; }
async function sha256b64(s: string) { return b64url(await crypto.subtle.digest("SHA-256", enc.encode(s))); }

// ---- rate limiting (KV counters) --------------------------------------------
// Best-effort by design: KV is eventually consistent and this is a read-then-write,
// so a burst of truly simultaneous requests can each see the same count. It raises
// the cost of guessing by orders of magnitude, which is the point — it is not a
// hard gate, and nothing downstream assumes it is.
function clientIp(request: Request) { return request.headers.get("CF-Connecting-IP") || "unknown"; }
async function hits(env: Env, key: string) { return Number(await env.BOOKSHELF.get(key)) || 0; }
async function bumpHits(env: Env, key: string, ttlSeconds: number) {
  const n = (await hits(env, key)) + 1;
  await env.BOOKSHELF.put(key, String(n), { expirationTtl: ttlSeconds });
  return n;
}
const FAIL_WINDOW_S = 900;          // 15 min
const MAX_FAILS_PER_EMAIL = 10;     // one account under attack
const MAX_FAILS_PER_IP = 30;        // credential stuffing: one password, many emails.
                                    // Higher than the per-email cap because a household,
                                    // office or carrier NAT shares a single address.
const MAX_REGISTER_PER_IP = 10;     // per day
const MAX_RESET_PER_EMAIL = 5;      // per hour
const MAX_RESET_PER_IP = 10;        // per hour
const MAX_RESET_USES_PER_IP = 20;   // per hour — guessing at reset tokens
const MAX_PW_CHANGE_FAILS = 5;      // per 15 min — a stolen token guessing the password

// ---- password hashing (PBKDF2-SHA256) ---------------------------------------
async function pbkdf2(password: string, salt: Uint8Array, iterations: number) {
  const key = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations, hash: "SHA-256" }, key, 256);
  return new Uint8Array(bits);
}
async function makePasswordRecord(password: string) {
  const salt = randomBytes(16);
  const iterations = 100000; // Cloudflare Workers caps PBKDF2 at 100k
  const hash = await pbkdf2(password, salt, iterations);
  return { salt: b64url(salt), hash: b64url(hash), iterations };
}
async function verifyPassword(password: string, rec: { salt: string; hash: string; iterations?: number }) {
  const salt = b64urlToBytes(rec.salt);
  const hash = await pbkdf2(password, salt, rec.iterations || 100000);
  const expected = b64urlToBytes(rec.hash);
  if (hash.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < hash.length; i++) diff |= hash[i] ^ expected[i];
  return diff === 0;
}
// A stand-in record to hash against when the email has no account, so a missing
// user costs the same ~100ms of PBKDF2 as a wrong password. Without it, response
// time alone told you which addresses are registered here — which is exactly what
// the deliberately identical "Wrong email or password" message exists to hide.
const DUMMY_PASSWORD_RECORD = { salt: b64url(new Uint8Array(16)), hash: b64url(new Uint8Array(32)), iterations: 100000 };
/** Re-hash a password onto an existing account record and refresh the uid index. */
async function saveNewPassword(env: Env, user: any, password: string) {
  const next = { ...user, ...(await makePasswordRecord(password)), pwChangedAt: new Date().toISOString() };
  await env.BOOKSHELF.put("user:" + user.email, JSON.stringify(next));
  await env.BOOKSHELF.put("uid:" + user.id, user.email);
  return next;
}

// ---- password policy --------------------------------------------------------
const PW_MIN = 10, PW_MAX = 200;
// The handful of passwords that actually dominate credential-stuffing lists. A
// full dictionary belongs on a server with a database; this is the cheap 90%.
// Compared lowercased, so "Password123" is caught too.
// Every entry is ≥ PW_MIN characters; anything shorter is already rejected on length.
const PW_BLOCKLIST = new Set([
  "password12", "password123", "password1234", "passw0rd123", "p@ssword123",
  "1234567890", "12345678910", "qwertyuiop", "qwerty12345", "1q2w3e4r5t",
  "letmein123", "iloveyou123", "welcome123", "admin12345", "adminadmin", "changeme123",
  "abc12345678", "monkey12345", "dragon12345", "sunshine123", "princess123", "football123",
  "baseball123", "trustno1234", "superman123", "starwars123", "whatever123", "qazwsxedc123",
  "bookshelf1", "bookshelf123", "enkela1234", "readingbooks",
]);
/**
 * Why a policy at all, when length is what really matters: the three passwords
 * that actually get accounts taken over here are "password123" (a list), the
 * user's own email local-part (trivially known to anyone who has the address),
 * and their name. Everything else is left to length.
 * Existing accounts are never re-checked — this gates new passwords only, so
 * nobody gets locked out of a shelf they can still open today.
 */
function passwordProblem(password: string, email?: string, fullName?: string): string | null {
  if (password.length < PW_MIN) return "Password must be at least " + PW_MIN + " characters.";
  if (password.length > PW_MAX) return "Password must be at most " + PW_MAX + " characters.";
  const lower = password.toLowerCase();
  if (PW_BLOCKLIST.has(lower)) return "That's one of the most commonly guessed passwords — please pick another.";
  if (/^(.)\1+$/.test(password)) return "Please use more than one repeated character.";
  if (new Set(lower).size < 5) return "Please use a few more different characters.";
  const local = String(email || "").split("@")[0].toLowerCase();
  if (local.length >= 3 && lower.indexOf(local) >= 0) return "Your password can't contain your email address.";
  for (const part of String(fullName || "").toLowerCase().split(/\s+/)) {
    if (part.length >= 4 && lower.indexOf(part) >= 0) return "Your password can't contain your name.";
  }
  return null;
}

const EMAIL_RE = /^[^@\s,;:<>"'\\/]+@[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i;
function normEmail(v: unknown) { return String(v == null ? "" : v).trim().toLowerCase(); }
function emailProblem(email: string): string | null {
  if (!email) return "Please enter your email address.";
  if (email.length > 254) return "That email address is too long."; // RFC 5321 ceiling
  if (email.indexOf("..") >= 0 || !EMAIL_RE.test(email)) return "Please enter a valid email address.";
  return null;
}
/** Names land in other people's club feeds, so strip control characters and cap the length. */
function cleanName(v: unknown) {
  return String(v == null ? "" : v).replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028\u2029\ufeff]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 80);
}
function publicUser(u: any) { return { id: u.id, email: u.email, fullName: u.fullName }; }

// ---- HMAC session tokens ----------------------------------------------------
const TOKEN_DAYS = 30;
const WS_TICKET_S = 60;
async function hmacKey(secret: string) {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}
/**
 * `iat` (MILLISECONDS) is what makes revocation possible: a password change
 * stamps rev:<uid>, and any token issued before that stops verifying. It has to
 * be milliseconds — at second granularity, a session opened in the same second
 * as the change survives it.
 * `jti` is random, so two tokens are never byte-identical. Without it the payload
 * is fully deterministic and two logins in the same instant produce literally the
 * same string, which makes "is this the old token or the new one?" unanswerable.
 * `aud` keeps a WebSocket ticket from being replayed against the REST API.
 */
async function makeToken(uid: string, secret: string, opts?: { seconds?: number; aud?: string; club?: string; iatMs?: number }) {
  const iat = opts && opts.iatMs ? opts.iatMs : Date.now();
  const payload: Record<string, unknown> = {
    uid, iat,
    exp: Math.floor(iat / 1000) + (opts && opts.seconds ? opts.seconds : TOKEN_DAYS * 86400),
    aud: (opts && opts.aud) || "api",
    jti: b64url(randomBytes(9)),
  };
  if (opts && opts.club) payload.club = opts.club;
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(body));
  return body + "." + b64url(sig);
}
async function verifyToken(token: string, env: Env, aud = "api") {
  if (!token || token.indexOf(".") < 0) return null;
  // Everything here runs inside the try on purpose: b64urlToBytes calls atob,
  // which THROWS on malformed base64url, and it was being evaluated as an
  // argument — outside the old catch. A corrupt stored token therefore came
  // back as a 500 "Server error" instead of a 401, and the client only offers
  // re-login on a 401, so the app parked itself in a permanent "sync paused"
  // state with no way out. A broken token simply means "not signed in".
  let payload: any;
  try {
    const [body, sig] = token.split(".");
    const ok = await crypto.subtle.verify("HMAC", await hmacKey(env.AUTH_SECRET), b64urlToBytes(sig), enc.encode(body));
    if (!ok) return null;
    payload = JSON.parse(dec.decode(b64urlToBytes(body)));
    if (!payload || !payload.uid) return null;
    if (!payload.exp || payload.exp < Math.floor(Date.now() / 1000)) return null;
    // Tokens minted before `aud` existed are API session tokens.
    if ((payload.aud || "api") !== aud) return null;
  } catch (e) { return null; }
  // Revocation. One KV read per authenticated request buys "changing my password
  // signs my other devices out", which is the whole point of changing it after a
  // laptop goes missing. The key only exists once someone has actually revoked,
  // and it expires with the longest-lived token it could invalidate.
  // A token predating `iat` (issued before this code shipped) counts as 0, so a
  // revocation evicts it — which is the safe direction to fail.
  const notBefore = Number(await env.BOOKSHELF.get("rev:" + payload.uid)) || 0;
  if (notBefore && Number(payload.iat || 0) < notBefore) return null;
  return payload;
}
/**
 * Kills every token issued before now, and returns the boundary so the caller can
 * mint the replacement exactly ON it. Passing that boundary back into makeToken is
 * what removes the race: with `<` in verifyToken the replacement is the earliest
 * surviving token, so there is no window in which an attacker's freshly minted
 * token slips through alongside it.
 */
async function revokeSessions(env: Env, uid: string) {
  const boundaryMs = Date.now();
  await env.BOOKSHELF.put("rev:" + uid, String(boundaryMs), { expirationTtl: TOKEN_DAYS * 86400 + 3600 });
  return boundaryMs;
}
async function requireAuth(request: Request, env: Env) {
  const h = request.headers.get("Authorization") || "";
  const token = h.indexOf("Bearer ") === 0 ? h.slice(7) : "";
  return verifyToken(token, env);
}
/**
 * A session token carries only a uid; the account record is keyed by email, hence
 * the uid: index.
 *
 * `claimedEmail` is the fallback for accounts that predate that index: they only
 * get one written on their next login, and until then change-password would 404 on
 * a perfectly valid session. The client sends the email it already has on screen,
 * and it is treated as a HINT only — the loaded record's id must still equal the
 * uid the signed token asserts, so a caller can't reach another person's account
 * by naming their address.
 */
async function userByUid(env: Env, uid: string, claimedEmail?: string) {
  const email = await env.BOOKSHELF.get("uid:" + uid);
  if (email) {
    const raw = await env.BOOKSHELF.get("user:" + email);
    if (raw) return JSON.parse(raw);
  }
  const hinted = normEmail(claimedEmail);
  if (!hinted || emailProblem(hinted)) return null;
  const raw = await env.BOOKSHELF.get("user:" + hinted);
  if (!raw) return null;
  const user = JSON.parse(raw);
  if (user.id !== uid) return null; // the token, not the hint, decides whose account this is
  await env.BOOKSHELF.put("uid:" + uid, hinted); // heal the index while we're here
  return user;
}

// ---- handlers ---------------------------------------------------------------

async function register(request: Request, env: Env, secret: string) {
  const b = await smallJson(request);
  const email = normEmail(b.email);
  const fullName = cleanName(b.fullName);
  const password = String(b.password || "");
  const ip = clientIp(request);
  // Signing up writes to KV, and the free tier allows ~1k writes a day. Without
  // a cap, one script can spend the whole budget before breakfast and take
  // everyone else's sync down with it.
  if (await hits(env, "ipreg:" + ip) >= MAX_REGISTER_PER_IP) {
    return json({ error: "Too many accounts created from here recently. Please try again tomorrow." }, 429, { "Retry-After": "3600" });
  }
  const emailBad = emailProblem(email);
  if (emailBad) return json({ error: emailBad }, 400);
  if (!fullName) return json({ error: "Please enter your full name." }, 400);
  const pwBad = passwordProblem(password, email, fullName);
  if (pwBad) return json({ error: pwBad }, 400);
  if (await env.BOOKSHELF.get("user:" + email)) return json({ error: "An account with this email already exists." }, 409);
  const rec = await makePasswordRecord(password);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  // KV has no compare-and-set, so two truly simultaneous signups for the same
  // address can both pass the check above and the second wins. Rare, and the
  // loser simply can't log in — worth knowing, not worth a distributed lock.
  await env.BOOKSHELF.put("user:" + email, JSON.stringify({ id, email, fullName, ...rec, createdAt: now, pwChangedAt: now }));
  await env.BOOKSHELF.put("uid:" + id, email);
  await bumpHits(env, "ipreg:" + ip, 86400);
  return json({ token: await makeToken(id, secret), user: { id, email, fullName } });
}

async function login(request: Request, env: Env, secret: string) {
  const b = await smallJson(request);
  const email = normEmail(b.email);
  const password = String(b.password || "");
  const ip = clientIp(request);
  const emailKey = "throttle:" + email, ipKey = "ipfail:" + ip;
  // Two counters, because they stop different attacks: per-email stops guessing
  // at one account, per-IP stops spraying one leaked password across thousands
  // of addresses (which the per-email counter never even notices).
  const [byEmail, byIp] = await Promise.all([hits(env, emailKey), hits(env, ipKey)]);
  if (byEmail >= MAX_FAILS_PER_EMAIL || byIp >= MAX_FAILS_PER_IP) {
    return json({ error: "Too many sign-in attempts. Please wait a few minutes and try again." }, 429, { "Retry-After": String(FAIL_WINDOW_S) });
  }
  const raw = email ? await env.BOOKSHELF.get("user:" + email) : null;
  const user = raw ? JSON.parse(raw) : null;
  // Always hash, even with no account, so both paths cost the same wall-clock time.
  const matched = await verifyPassword(password, user || DUMMY_PASSWORD_RECORD);
  if (!user || !matched) {
    await Promise.all([bumpHits(env, emailKey, FAIL_WINDOW_S), bumpHits(env, ipKey, FAIL_WINDOW_S)]);
    // One message for both "no such account" and "wrong password": telling them
    // apart let anyone probe which email addresses have accounts here.
    return json({ error: "Wrong email or password." }, 401);
  }
  // Clear the counters on success — otherwise someone who fat-fingers it nine
  // times and then gets it right stays one typo from a 15-minute lockout.
  await Promise.all([
    env.BOOKSHELF.delete(emailKey),
    env.BOOKSHELF.delete(ipKey),
    // Backfill the reverse index for accounts created before it existed, so
    // change-password works for them without a migration script.
    env.BOOKSHELF.put("uid:" + user.id, user.email),
  ]);
  return json({ token: await makeToken(user.id, secret), user: publicUser(user) });
}

// ---- password change + reset ------------------------------------------------
const RESET_TTL_S = 30 * 60;

/** Signed in and knows the current password: rotate it and evict every other session. */
async function passwordChange(request: Request, env: Env, secret: string) {
  const auth = await requireAuth(request, env);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const b = await smallJson(request);
  const current = String(b.currentPassword || "");
  const next = String(b.newPassword || "");
  const user = await userByUid(env, auth.uid, b.email);
  if (!user) return json({ error: "We couldn't find your account. Please sign out and back in, then try again." }, 404);
  // A stolen token can already read the shelf; it must not get unlimited guesses
  // at the password that would let it lock the real owner out for good.
  const guessKey = "pwchange:" + auth.uid;
  if (await hits(env, guessKey) >= MAX_PW_CHANGE_FAILS) {
    return json({ error: "Too many attempts. Please wait a few minutes." }, 429, { "Retry-After": String(FAIL_WINDOW_S) });
  }
  if (!(await verifyPassword(current, user))) {
    await bumpHits(env, guessKey, FAIL_WINDOW_S);
    return json({ error: "Your current password isn't right." }, 401);
  }
  const pwBad = passwordProblem(next, user.email, user.fullName);
  if (pwBad) return json({ error: pwBad }, 400);
  if (next === current) return json({ error: "That's the password you already have." }, 400);
  await saveNewPassword(env, user, next);
  const boundaryMs = await revokeSessions(env, user.id);
  await env.BOOKSHELF.delete(guessKey);
  // Fresh token so THIS device stays signed in while the others get logged out.
  return json({ ok: true, token: await makeToken(user.id, secret, { iatMs: boundaryMs }), user: publicUser(user) });
}

/** Mail a single-use reset link. Answers identically whether or not the account exists. */
async function passwordForgot(request: Request, env: Env, ctx: ExecutionContext | null) {
  const b = await smallJson(request);
  const email = normEmail(b.email);
  const ip = clientIp(request);
  // The ONLY response this endpoint ever gives on the happy path. Varying it by
  // whether the address is registered would turn "forgot password" into a
  // free membership lookup for anyone with a list of emails.
  const neutral = { ok: true, message: "If that email has an account, a reset link is on its way. Check your inbox — and your spam folder." };
  if (await hits(env, "ipreset:" + ip) >= MAX_RESET_PER_IP) {
    return json({ error: "Too many requests. Please wait a while and try again." }, 429, { "Retry-After": "3600" });
  }
  await bumpHits(env, "ipreset:" + ip, 3600);
  if (emailProblem(email)) return json(neutral);
  // Per-address cap so this can't be used to mail-bomb someone who does have an account.
  if (await hits(env, "resetreq:" + email) >= MAX_RESET_PER_EMAIL) return json(neutral);
  await bumpHits(env, "resetreq:" + email, 3600);
  const raw = await env.BOOKSHELF.get("user:" + email);
  if (!raw) return json(neutral);
  const user = JSON.parse(raw);
  const token = b64url(randomBytes(32));
  // Only the HASH is stored. A dump of KV then yields no working reset links —
  // the same reasoning that has the passwords beside it hashed rather than stored.
  await env.BOOKSHELF.put(
    "reset:" + (await sha256b64(token)),
    JSON.stringify({ email, uid: user.id, at: new Date().toISOString() }),
    { expirationTtl: RESET_TTL_S },
  );
  const link = resetLink(env, token);
  if (!mailerReady(env)) {
    console.error("password reset requested for a real account but reset is not fully configured — need RESEND_API_KEY, RESET_FROM and APP_URL (see DEPLOY.md). Missing: "
      + [!env.RESEND_API_KEY && "RESEND_API_KEY", !env.RESET_FROM && "RESET_FROM", !env.APP_URL && "APP_URL"].filter(Boolean).join(", ")
      + ". Link NOT delivered.");
    // Local dev only, and only while there is genuinely no mailer, so a
    // misconfigured production deploy can never quietly start handing these out.
    if (env.RESET_DEBUG === "1") return json({ ...neutral, devResetLink: link });
    return json(neutral);
  }
  // Hand the send to waitUntil rather than awaiting it. Awaiting made a
  // registered address take several hundred milliseconds longer than an unknown
  // one — the response text is identical, but the clock told them apart, which
  // is the whole thing this endpoint is built to avoid.
  const sending = sendResetEmail(env, user, link);
  if (ctx) ctx.waitUntil(sending); else await sending;
  return json(neutral);
}

/** Redeem a reset link. Consumes the token, then evicts every existing session. */
async function passwordReset(request: Request, env: Env, secret: string) {
  const b = await smallJson(request);
  const token = String(b.token || "");
  const next = String(b.newPassword || "");
  const ip = clientIp(request);
  if (await hits(env, "ipresetuse:" + ip) >= MAX_RESET_USES_PER_IP) {
    return json({ error: "Too many attempts. Please wait a while and try again." }, 429, { "Retry-After": "3600" });
  }
  await bumpHits(env, "ipresetuse:" + ip, 3600);
  const expired = { error: "That reset link is invalid or has expired. Please request a new one." };
  if (!token) return json(expired, 400);
  const key = "reset:" + (await sha256b64(token));
  const raw = await env.BOOKSHELF.get(key);
  if (!raw) return json(expired, 400);
  const rec = JSON.parse(raw);
  const userRaw = await env.BOOKSHELF.get("user:" + rec.email);
  if (!userRaw) { await env.BOOKSHELF.delete(key); return json(expired, 400); }
  const user = JSON.parse(userRaw);
  const pwBad = passwordProblem(next, user.email, user.fullName);
  // Deliberately BEFORE the token is consumed: a rejected password shouldn't
  // cost someone their one link and send them back to the inbox.
  if (pwBad) return json({ error: pwBad }, 400);
  await saveNewPassword(env, user, next);
  await env.BOOKSHELF.delete(key);                        // single use
  const boundaryMs = await revokeSessions(env, user.id);  // whoever knew the old password is out
  await env.BOOKSHELF.delete("throttle:" + user.email);   // don't leave them locked out by the attempts that led here
  return json({ ok: true, token: await makeToken(user.id, secret, { iatMs: boundaryMs }), user: publicUser(user) });
}

/**
 * Deliberately has NO default. A guessed base URL produces a link that looks
 * right, arrives by email, and 404s — which reads to the person locked out as
 * "reset is broken" with nothing to act on. Returning "" here instead makes the
 * whole feature report itself unconfigured (see mailerReady), so the client hides
 * "Forgot your password?" rather than mailing out dead links.
 */
function resetLink(env: Env, token: string) {
  const base = String(env.APP_URL || "").replace(/\/+$/, "");
  if (!base) return "";
  // The token rides in the FRAGMENT, not the query string: fragments are never
  // sent to a server, so it stays out of access logs and Referer headers.
  return base + "/#reset/" + token;
}
/** Reset needs all three: a key to send with, a verified sender, and a link target. */
function mailerReady(env: Env) {
  return !!(env.RESEND_API_KEY && env.RESET_FROM && env.APP_URL);
}
async function sendResetEmail(env: Env, user: any, link: string) {
  if (!mailerReady(env) || !link) return false;
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: "Bearer " + env.RESEND_API_KEY, "content-type": "application/json" },
      body: JSON.stringify({
        from: env.RESET_FROM,
        to: [user.email],
        subject: "Reset your Bookshelf password",
        text: "Hi " + (String(user.fullName || "").split(" ")[0] || "there") + ",\n\n"
          + "Someone asked to reset the password on this Bookshelf account. If that was you, "
          + "open this link within 30 minutes:\n\n" + link + "\n\n"
          + "The link works once. If it wasn't you, you can ignore this email — nothing has changed, "
          + "and your books are untouched.\n",
      }),
    });
    if (!res.ok) { console.error("reset email rejected", res.status, await res.text().catch(() => "")); return false; }
    return true;
  } catch (e) { console.error("reset email failed", e); return false; }
}

const MAX_BLOB_BYTES = 8 * 1024 * 1024;

async function getData(request: Request, env: Env) {
  const auth = await requireAuth(request, env);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const raw = await env.BOOKSHELF.get("data:" + auth.uid);
  return json(raw ? JSON.parse(raw) : { blob: null, updatedAt: null });
}

async function putData(request: Request, env: Env) {
  const auth = await requireAuth(request, env);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const b = await request.json<any>().catch(() => ({}));
  if (b.blob == null) return json({ error: "No data." }, 400);
  const existingRaw = await env.BOOKSHELF.get("data:" + auth.uid);
  if (!b.force && existingRaw) {
    const existing = JSON.parse(existingRaw);
    // Optimistic concurrency: only write if the client's base matches what's stored.
    if (existing.updatedAt && b.baseUpdatedAt !== existing.updatedAt) {
      return json({ conflict: true, blob: existing.blob, updatedAt: existing.updatedAt }, 409);
    }
  }
  const updatedAt = b.updatedAt || new Date().toISOString();
  const record = JSON.stringify({ blob: b.blob, updatedAt });
  // KV's hard ceiling is 25MB; refuse well before that with an explanation the
  // client can show. Previously an oversized blob threw inside KV.put and
  // surfaced as an opaque 500.
  if (record.length > MAX_BLOB_BYTES) {
    return json({ error: "This bookshelf is too large to sync (over " + Math.round(MAX_BLOB_BYTES / (1024 * 1024)) + " MB). Export a backup, then remove some books or reading logs." }, 413);
  }
  await env.BOOKSHELF.put("data:" + auth.uid, record);
  return json({ ok: true, updatedAt });
}

// ---- Account deletion -------------------------------------------------------
/**
 * Erase an account and everything attached to it. Until now the only way out was
 * emailing whoever runs the server, which is not a way out.
 *
 * Re-authentication with the current password is deliberate. This is total and
 * irreversible, so a token lifted off a borrowed laptop must not be enough on its
 * own — the same reasoning that guards change-password, and the guesses are
 * throttled on their own counter for the same reason.
 */
async function accountDelete(request: Request, env: Env, ctx: ExecutionContext | null) {
  const auth = await requireAuth(request, env);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const b = await smallJson(request);
  const user = await userByUid(env, auth.uid, b.email);
  if (!user) return json({ error: "We couldn't find your account. Please sign out and back in, then try again." }, 404);
  const guessKey = "pwdelete:" + auth.uid;
  if (await hits(env, guessKey) >= MAX_PW_CHANGE_FAILS) {
    return json({ error: "Too many attempts. Please wait a few minutes." }, 429, { "Retry-After": String(FAIL_WINDOW_S) });
  }
  if (!(await verifyPassword(String(b.password || ""), user))) {
    await bumpHits(env, guessKey, FAIL_WINDOW_S);
    return json({ error: "That password isn't right." }, 401);
  }

  // The order below is the whole design, and it is chosen so that a failure at
  // any point leaves the account still signed-in-able and the delete retryable.
  // Every step is idempotent.

  // 1. Sessions first. Another device mid-sync would otherwise PUT /api/data a
  //    moment after step 2 and quietly resurrect the blob we just erased.
  //    Revocation does not block a fresh login (a new token's iat is after the
  //    boundary), which is exactly what makes a retry possible.
  await revokeSessions(env, user.id);
  // 2. The private data, before the account record. Deleting the account first
  //    would strand the blob with no credential left to authenticate a retry.
  await env.BOOKSHELF.delete("data:" + user.id);
  // 3. Clubs, comments, recs, votes, blocks, reports.
  const removed = await purgeUserFromCommunity(env, ctx, user.id);
  // 4. The account itself, last — this is the step that makes it unrecoverable.
  //    rev:<uid> deliberately stays: it has to outlive the account so any token
  //    still in the wild remains dead. It expires on its own TTL.
  await Promise.all([
    env.BOOKSHELF.delete("user:" + user.email),
    env.BOOKSHELF.delete("uid:" + user.id),
    env.BOOKSHELF.delete("throttle:" + user.email),
    env.BOOKSHELF.delete("pwchange:" + user.id),
    env.BOOKSHELF.delete(guessKey),
  ]);
  // 5. Sweep the blob once more. KV is eventually consistent, so a request
  //    already in flight when step 1 landed could still have written one.
  await env.BOOKSHELF.delete("data:" + user.id);
  // Outstanding reset: records need no sweep — they're keyed by token hash and
  // aren't enumerable by uid, and passwordReset already re-reads user:<email>,
  // finds it gone, deletes the record and reports the link as expired.
  return json({ ok: true, deleted: removed });
}

/**
 * Remove a user from the shared D1 side of the app. Runs as one batch so a
 * partial failure can't leave a club with no host or a comment with no author.
 *
 * Leaving a club and deleting your account are deliberately different: leaving
 * keeps your words in everyone else's feed (attributed to "Former member"),
 * because the discussion outlives the membership. Deleting the account is a
 * request for erasure, so the comments go too.
 */
async function purgeUserFromCommunity(env: Env, ctx: ExecutionContext | null, uid: string) {
  if (!env.CLUBS_DB) return { clubs: 0, recs: 0 };
  const memberships = (await env.CLUBS_DB.prepare("SELECT club_id, role FROM members WHERE uid=?1").bind(uid).all()).results as any[] || [];
  const recCount = Number((await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM recs WHERE created_by=?1 AND deleted=0").bind(uid).first<any>()).n) || 0;
  const stmts: any[] = [];
  const orphaned: string[] = [];
  for (const m of memberships) {
    if (m.role !== "host") continue;
    // Hosting is not ownership of the conversation. Deleting a club out from
    // under five other people who are halfway through the book is worse than
    // losing its founder, so the earliest-joined member inherits it.
    const heir = await env.CLUBS_DB.prepare(
      "SELECT uid FROM members WHERE club_id=?1 AND uid<>?2 ORDER BY joined_at ASC LIMIT 1"
    ).bind(m.club_id, uid).first<any>();
    if (heir) {
      stmts.push(
        env.CLUBS_DB.prepare("UPDATE members SET role='host' WHERE club_id=?1 AND uid=?2").bind(m.club_id, heir.uid),
        env.CLUBS_DB.prepare("UPDATE clubs SET host_uid=?2 WHERE id=?1").bind(m.club_id, heir.uid),
      );
    } else {
      orphaned.push(m.club_id); // sole member: nothing survives, take it all
    }
  }
  for (const clubId of orphaned) {
    stmts.push(
      env.CLUBS_DB.prepare("DELETE FROM reactions WHERE comment_id IN (SELECT id FROM comments WHERE club_id=?1)").bind(clubId),
      env.CLUBS_DB.prepare("DELETE FROM comments WHERE club_id=?1").bind(clubId),
      env.CLUBS_DB.prepare("DELETE FROM invites WHERE club_id=?1").bind(clubId),
      env.CLUBS_DB.prepare("DELETE FROM members WHERE club_id=?1").bind(clubId),
      env.CLUBS_DB.prepare("DELETE FROM clubs WHERE id=?1").bind(clubId),
    );
  }
  stmts.push(
    env.CLUBS_DB.prepare("DELETE FROM members WHERE uid=?1").bind(uid),
    env.CLUBS_DB.prepare("UPDATE comments SET deleted=1 WHERE uid=?1").bind(uid),
    env.CLUBS_DB.prepare("DELETE FROM reactions WHERE uid=?1").bind(uid),
    env.CLUBS_DB.prepare("UPDATE recs SET deleted=1 WHERE created_by=?1").bind(uid),
    // Their own auto-cast vote AND everyone else's votes on the recs that just
    // went away — otherwise rec_votes grows rows pointing at nothing forever.
    env.CLUBS_DB.prepare("DELETE FROM rec_votes WHERE rec_id IN (SELECT id FROM recs WHERE created_by=?1)").bind(uid),
    env.CLUBS_DB.prepare("DELETE FROM rec_votes WHERE uid=?1").bind(uid),
    env.CLUBS_DB.prepare("DELETE FROM invites WHERE created_by=?1").bind(uid),
    // Blocks in both directions: theirs are meaningless now, and a block *of*
    // them is a filter against a uid that will never post again.
    env.CLUBS_DB.prepare("DELETE FROM blocks WHERE uid=?1 OR blocked_uid=?1").bind(uid),
    env.CLUBS_DB.prepare("DELETE FROM reports WHERE reporter_uid=?1").bind(uid),
  );
  await env.CLUBS_DB.batch(stmts);
  // Nudge every club they were in, so anyone with it open sees the member list
  // change instead of a ghost sitting at 40%.
  for (const m of memberships) notifyClub(env, ctx, m.club_id, { type: "members" });
  return { clubs: memberships.length, recs: recCount };
}

// ---- Reading Clubs (D1) -----------------------------------------------------
// Small, private, spoiler-safe book clubs. The spoiler gate is a server-side
// integer compare: you only ever receive comments at or below YOUR progress_pct.
const MAX_MEMBERS = 6; // host + up to 5 friends
function code8() {
  const c = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no ambiguous 0/O/1/I
  const r = randomBytes(8);
  let s = "";
  for (let i = 0; i < 8; i++) s += c[r[i] % c.length];
  return s;
}
function clampPct(n: any) { n = Math.round(Number(n) || 0); return n < 0 ? 0 : n > 100 ? 100 : n; }
function clubMember(env: Env, clubId: string, uid: string) {
  return env.CLUBS_DB.prepare("SELECT * FROM members WHERE club_id=?1 AND uid=?2").bind(clubId, uid).first<any>();
}
function touchClub(env: Env, clubId: string) {
  return env.CLUBS_DB.prepare("UPDATE clubs SET last_activity=?2 WHERE id=?1").bind(clubId, new Date().toISOString()).run();
}
// Realtime is best-effort: nudge the club's Durable Object to broadcast to any
// connected members. D1 stays the source of truth (and the spoiler gate).
// The subrequest MUST be handed to ctx.waitUntil — an un-awaited fetch can be
// cancelled the moment we return the response, which silently dropped the
// broadcast and left everyone waiting on the 20s poll instead.
function notifyClub(env: Env, ctx: ExecutionContext | null, clubId: string, payload: unknown) {
  if (!env.CLUB_ROOMS) return;
  try {
    const stub = env.CLUB_ROOMS.get(env.CLUB_ROOMS.idFromName(clubId));
    const p = stub.fetch(new Request("https://club/broadcast", { method: "POST", body: JSON.stringify(payload || {}) }));
    if (ctx) ctx.waitUntil(p.catch(() => { /* room asleep or gone */ }));
  } catch (e) { /* realtime unavailable — clients still poll */ }
}
// A browser can't set an Authorization header on a WebSocket handshake, so the
// credential has to ride in the URL — and URLs end up in proxy logs, Cloudflare
// access logs and browser history. So don't send the 30-day session token: trade
// it for a 60-second ticket that only opens this one club's socket and is
// rejected outright by every REST endpoint (aud: "ws").
async function clubWsTicket(clubId: string, auth: { uid: string }, env: Env) {
  if (!(await clubMember(env, clubId, auth.uid))) return json({ error: "Not a member of this club." }, 403);
  return json({ ticket: await makeToken(auth.uid, env.AUTH_SECRET, { seconds: WS_TICKET_S, aud: "ws", club: clubId }) });
}
async function clubWs(url: URL, request: Request, env: Env, clubId: string) {
  if (!env.CLUB_ROOMS) return new Response("realtime unavailable", { status: 503 });
  const auth = await verifyToken(url.searchParams.get("ticket") || "", env, "ws");
  // Scoped to one club, so a ticket leaked from one room can't open another.
  if (!auth || auth.club !== clubId) return new Response("unauthorized", { status: 401 });
  if (!(await clubMember(env, clubId, auth.uid))) return new Response("forbidden", { status: 403 });
  const stub = env.CLUB_ROOMS.get(env.CLUB_ROOMS.idFromName(clubId));
  return stub.fetch(new Request("https://club/ws", request));
}

async function clubsList(auth: { uid: string }, env: Env) {
  const clubs = (await env.CLUBS_DB.prepare(
    "SELECT c.* FROM clubs c JOIN members m ON m.club_id=c.id WHERE m.uid=?1 AND c.archived=0 ORDER BY c.created_at DESC"
  ).bind(auth.uid).all()).results as any[] || [];
  if (!clubs.length) return json({ clubs });
  // One query for the members of every club, rather than one query per club.
  const ids = clubs.map((c) => c.id);
  const holes = ids.map((_, i) => "?" + (i + 1)).join(",");
  const rows = (await env.CLUBS_DB.prepare(
    `SELECT club_id, uid, display_name, role, progress_pct FROM members WHERE club_id IN (${holes}) ORDER BY progress_pct DESC`
  ).bind(...ids).all()).results as any[] || [];
  const byClub: Record<string, any[]> = {};
  for (const r of rows) (byClub[r.club_id] = byClub[r.club_id] || []).push(r);
  for (const c of clubs) {
    c.members = byClub[c.id] || [];
    c.me = c.members.find((m: any) => m.uid === auth.uid) || null;
  }
  return json({ clubs });
}
async function clubCreate(request: Request, auth: { uid: string }, env: Env) {
  const b = await request.json<any>().catch(() => ({}));
  const title = String(b.bookTitle || "").trim();
  if (!title) return json({ error: "A book title is required." }, 400);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
  const code = code8();
  const name = String(b.displayName || "You").trim().slice(0, 60);
  await env.CLUBS_DB.batch([
    env.CLUBS_DB.prepare("INSERT INTO clubs (id,host_uid,book_title,book_author,book_isbn,total_pages,created_at,archived) VALUES (?1,?2,?3,?4,?5,?6,?7,0)")
      .bind(id, auth.uid, title, String(b.bookAuthor || ""), String(b.bookIsbn || ""), Number(b.totalPages) || null, now),
    env.CLUBS_DB.prepare("INSERT INTO members (club_id,uid,display_name,role,progress_pct,joined_at) VALUES (?1,?2,?3,'host',0,?4)")
      .bind(id, auth.uid, name, now),
    env.CLUBS_DB.prepare("INSERT INTO invites (code,club_id,created_by,expires_at,max_uses,uses) VALUES (?1,?2,?3,?4,?5,0)")
      .bind(code, id, auth.uid, null, MAX_MEMBERS),
  ]);
  return json({ ok: true, clubId: id, joinCode: code });
}
async function clubJoin(request: Request, auth: { uid: string }, env: Env) {
  const b = await request.json<any>().catch(() => ({}));
  const code = String(b.joinCode || "").trim().toUpperCase();
  const name = String(b.displayName || "You").trim().slice(0, 60);
  const inv = await env.CLUBS_DB.prepare("SELECT * FROM invites WHERE code=?1").bind(code).first<any>();
  if (!inv) return json({ error: "That join code doesn't exist." }, 404);
  if (await clubMember(env, inv.club_id, auth.uid)) return json({ ok: true, clubId: inv.club_id }); // already in
  const count = (await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM members WHERE club_id=?1").bind(inv.club_id).first<any>()).n;
  if (count >= (inv.max_uses || MAX_MEMBERS)) return json({ error: "This club is full." }, 403);
  const now = new Date().toISOString();
  await env.CLUBS_DB.batch([
    env.CLUBS_DB.prepare("INSERT INTO members (club_id,uid,display_name,role,progress_pct,joined_at) VALUES (?1,?2,?3,'member',0,?4)").bind(inv.club_id, auth.uid, name, now),
    env.CLUBS_DB.prepare("UPDATE invites SET uses=uses+1 WHERE code=?1").bind(code),
  ]);
  return json({ ok: true, clubId: inv.club_id });
}
async function clubDetail(clubId: string, auth: { uid: string }, env: Env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const club = await env.CLUBS_DB.prepare("SELECT * FROM clubs WHERE id=?1").bind(clubId).first<any>();
  if (!club) return json({ error: "Club not found." }, 404);
  const members = (await env.CLUBS_DB.prepare("SELECT uid, display_name, role, progress_pct FROM members WHERE club_id=?1 ORDER BY progress_pct DESC").bind(clubId).all()).results as any[] || [];
  const invite = await env.CLUBS_DB.prepare("SELECT code FROM invites WHERE club_id=?1 LIMIT 1").bind(clubId).first<any>();
  return json({ club, me, members, joinCode: invite ? invite.code : null });
}
async function clubComments(clubId: string, auth: { uid: string }, env: Env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  // LEFT JOIN, not JOIN: leaving a club deletes the member row, and an inner
  // join then dropped every comment that person had written out of everyone
  // else's feed. The discussion outlives the membership.
  // The blocked-author filter rides alongside the spoiler gate. A club is six
  // people who chose each other, so this is rarer here than on the public board
  // — but "I don't want to read this person any more" shouldn't force you to
  // abandon the book.
  const comments = (await env.CLUBS_DB.prepare(
    "SELECT c.id,c.uid,COALESCE(m.display_name,'Former member') AS display_name,c.pos_pct,c.chapter,c.label,c.body,c.created_at " +
    "FROM comments c LEFT JOIN members m ON m.club_id=c.club_id AND m.uid=c.uid " +
    "WHERE c.club_id=?1 AND c.deleted=0 AND c.pos_pct<=?2 " +
    "AND c.uid NOT IN (SELECT blocked_uid FROM blocks WHERE uid=?3) " +
    "ORDER BY c.pos_pct ASC, c.created_at ASC"
  ).bind(clubId, me.progress_pct, auth.uid).all()).results as any[] || [];
  // Reactions for the comments this member is allowed to see (same gate).
  const reacts = (await env.CLUBS_DB.prepare(
    "SELECT r.comment_id, r.emoji, r.uid FROM reactions r JOIN comments c ON c.id=r.comment_id " +
    "WHERE c.club_id=?1 AND c.deleted=0 AND c.pos_pct<=?2"
  ).bind(clubId, me.progress_pct).all()).results as any[] || [];
  const byComment: Record<string, { counts: Record<string, number>; mine: string[] }> = {};
  for (const r of reacts) {
    const e = (byComment[r.comment_id] = byComment[r.comment_id] || { counts: {}, mine: [] });
    e.counts[r.emoji] = (e.counts[r.emoji] || 0) + 1;
    if (r.uid === auth.uid) e.mine.push(r.emoji);
  }
  for (const c of comments) c.reactions = byComment[c.id] || { counts: {}, mine: [] };
  const lockedAhead = (await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM comments WHERE club_id=?1 AND deleted=0 AND pos_pct>?2").bind(clubId, me.progress_pct).first<any>()).n;
  return json({ comments, lockedAhead, myProgress: me.progress_pct });
}
async function clubPostComment(request: Request, clubId: string, auth: { uid: string }, env: Env, ctx: ExecutionContext) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json<any>().catch(() => ({}));
  const body = String(b.body || "").trim().slice(0, 2000);
  if (!body) return json({ error: "Empty comment." }, 400);
  const bad = contentProblem(body);
  if (bad) return json({ error: bad }, 422);
  await env.CLUBS_DB.prepare("INSERT INTO comments (id,club_id,uid,pos_pct,chapter,label,body,created_at,deleted) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,0)")
    .bind(crypto.randomUUID(), clubId, auth.uid, clampPct(b.posPct), (b.chapter != null ? Number(b.chapter) : null), (b.label ? String(b.label).slice(0, 60) : null), body, new Date().toISOString()).run();
  await touchClub(env, clubId);
  notifyClub(env, ctx, clubId, { type: "comment" });
  return json({ ok: true });
}
async function clubProgress(request: Request, clubId: string, auth: { uid: string }, env: Env, ctx: ExecutionContext) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json<any>().catch(() => ({}));
  // forward-only, so a re-read or sync hiccup can never un-reveal a spoiler
  await env.CLUBS_DB.prepare("UPDATE members SET progress_pct=MAX(progress_pct,?3) WHERE club_id=?1 AND uid=?2").bind(clubId, auth.uid, clampPct(b.progressPct)).run();
  notifyClub(env, ctx, clubId, { type: "progress" });
  return json({ ok: true });
}
async function clubReact(request: Request, clubId: string, auth: { uid: string }, env: Env, ctx: ExecutionContext) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json<any>().catch(() => ({}));
  const emoji = String(b.emoji || "").slice(0, 8);
  const commentId = String(b.commentId || "");
  if (!emoji || !commentId) return json({ error: "Missing reaction." }, 400);
  // Can only react to a comment you're allowed to see (at/below your progress).
  const c = await env.CLUBS_DB.prepare("SELECT pos_pct FROM comments WHERE id=?1 AND club_id=?2 AND deleted=0").bind(commentId, clubId).first<any>();
  if (!c || c.pos_pct > me.progress_pct) return json({ error: "Comment not available." }, 403);
  const existing = await env.CLUBS_DB.prepare("SELECT 1 FROM reactions WHERE comment_id=?1 AND uid=?2 AND emoji=?3").bind(commentId, auth.uid, emoji).first<any>();
  if (existing) {
    await env.CLUBS_DB.prepare("DELETE FROM reactions WHERE comment_id=?1 AND uid=?2 AND emoji=?3").bind(commentId, auth.uid, emoji).run();
    notifyClub(env, ctx, clubId, { type: "reaction" });
    return json({ ok: true, reacted: false });
  }
  await env.CLUBS_DB.prepare("INSERT INTO reactions (comment_id,uid,emoji,created_at) VALUES (?1,?2,?3,?4)").bind(commentId, auth.uid, emoji, new Date().toISOString()).run();
  notifyClub(env, ctx, clubId, { type: "reaction" });
  return json({ ok: true, reacted: true });
}
async function clubLeave(clubId: string, auth: { uid: string }, env: Env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  await env.CLUBS_DB.prepare("DELETE FROM members WHERE club_id=?1 AND uid=?2").bind(clubId, auth.uid).run();
  return json({ ok: true });
}
async function clubsRouter(url: URL, request: Request, env: Env, ctx: ExecutionContext) {
  if (!env.CLUBS_DB) return json({ error: "Reading clubs aren't enabled on this server yet." }, 503);
  const parts = url.pathname.split("/").filter(Boolean); // ["api","clubs", id?, sub?, sub2?, sub3?]
  const id = parts[2], sub = parts[3], sub2 = parts[4], sub3 = parts[5];
  const m = request.method;
  // Realtime WebSocket — a browser can't set an Authorization header on the WS
  // handshake, so the token arrives as a query param and is verified in clubWs.
  if (id && sub === "ws") return clubWs(url, request, env, id);
  const auth = await requireAuth(request, env);
  if (!auth) return json({ error: "Not signed in." }, 401);
  if (id && sub === "ws-ticket" && m === "POST") return clubWsTicket(id, auth, env);
  if (!id) {
    if (m === "GET") return clubsList(auth, env);
    if (m === "POST") return clubCreate(request, auth, env);
  } else if (id === "join" && m === "POST") {
    return clubJoin(request, auth, env);
  } else if (id && !sub && m === "GET") {
    return clubDetail(id, auth, env);
  } else if (sub === "comments" && m === "GET") {
    return clubComments(id, auth, env);
  } else if (sub === "comments" && sub2 && sub3 === "report" && m === "POST") {
    return reportCreate(request, "comment", sub2, id, auth, env);
  } else if (sub === "comments" && m === "POST") {
    return clubPostComment(request, id, auth, env, ctx);
  } else if (sub === "progress" && m === "PUT") {
    return clubProgress(request, id, auth, env, ctx);
  } else if (sub === "reactions" && m === "POST") {
    return clubReact(request, id, auth, env, ctx);
  } else if (sub === "leave" && m === "POST") {
    return clubLeave(id, auth, env);
  }
  return json({ error: "Not found" }, 404);
}

// ---- Community recommendations (D1, shares CLUBS_DB) ------------------------
// One global, public board. Reading the board needs no account; recommending
// and voting do. Votes are 1 (worth reading) or -1 (not worth it), one per user
// per book, and clicking the same vote again clears it (toggle off).
// The board is public and unbounded, so page it: newest N, and tally votes for
// just that page instead of GROUP BY-ing the whole rec_votes table.
const RECS_PAGE = 200;
const RECS_PER_HOUR = 20;
async function recsList(env: Env, auth: { uid: string } | null) {
  // Blocking is applied here, per viewer, rather than by deleting anything: the
  // blocked person's recs stay on everyone else's board and they're never told.
  const cols = "SELECT id,category,book_title,book_author,book_isbn,cover_url,note,created_by,created_name,created_at FROM recs WHERE deleted=0";
  const tail = " ORDER BY created_at DESC LIMIT ?1";
  const q = auth
    ? env.CLUBS_DB.prepare(cols + " AND created_by NOT IN (SELECT blocked_uid FROM blocks WHERE uid=?2)" + tail).bind(RECS_PAGE, auth.uid)
    : env.CLUBS_DB.prepare(cols + tail).bind(RECS_PAGE);
  const recs = (await q.all()).results as any[] || [];
  if (!recs.length) return json({ recs, signedIn: !!auth, capped: false });
  const ids = recs.map((r) => r.id);
  const holes = ids.map((_, i) => "?" + (i + 1)).join(",");
  const tallies = (await env.CLUBS_DB.prepare(
    `SELECT rec_id, SUM(CASE WHEN vote=1 THEN 1 ELSE 0 END) AS up, SUM(CASE WHEN vote=-1 THEN 1 ELSE 0 END) AS down FROM rec_votes WHERE rec_id IN (${holes}) GROUP BY rec_id`
  ).bind(...ids).all()).results as any[] || [];
  const byId: Record<string, { up: number; down: number }> = {};
  for (const t of tallies) byId[t.rec_id] = { up: Number(t.up) || 0, down: Number(t.down) || 0 };
  const mine: Record<string, number> = {};
  if (auth) {
    // uid is ?1, so this page's ids start at ?2.
    const mineHoles = ids.map((_, i) => "?" + (i + 2)).join(",");
    const mv = (await env.CLUBS_DB.prepare(`SELECT rec_id, vote FROM rec_votes WHERE uid=?1 AND rec_id IN (${mineHoles})`).bind(auth.uid, ...ids).all()).results as any[] || [];
    for (const v of mv) mine[v.rec_id] = v.vote;
  }
  for (const r of recs) {
    const t = byId[r.id] || { up: 0, down: 0 };
    r.up = t.up; r.down = t.down; r.score = t.up - t.down;
    r.myVote = mine[r.id] || 0;
    r.mine = auth ? r.created_by === auth.uid : false;
  }
  // Tell the client when it's only seeing a page, so it can say so rather than
  // implying the board is this small.
  return json({ recs, signedIn: !!auth, capped: recs.length >= RECS_PAGE });
}
async function recsCreate(request: Request, auth: { uid: string }, env: Env) {
  const b = await request.json<any>().catch(() => ({}));
  const title = String(b.bookTitle || "").trim().slice(0, 200);
  const category = String(b.category || "").trim().slice(0, 60) || "General";
  if (!title) return json({ error: "A book title is required." }, 400);
  // The board is public and permanent-ish; check what a stranger will read.
  const bad = contentProblem(title) || contentProblem(String(b.note || "")) || contentProblem(String(b.bookAuthor || ""));
  if (bad) return json({ error: bad }, 422);
  const now = new Date().toISOString();
  // Recommending the same book to the same shelf twice is a double-tap, not a
  // second recommendation — hand back the original instead of cluttering the
  // public board with duplicates.
  const dup = await env.CLUBS_DB.prepare(
    "SELECT id FROM recs WHERE deleted=0 AND created_by=?1 AND lower(book_title)=lower(?2) AND lower(category)=lower(?3)"
  ).bind(auth.uid, title, category).first<any>();
  if (dup) return json({ ok: true, id: dup.id, duplicate: true });
  // The board is shared and public: cap how fast one account can fill it.
  const since = new Date(Date.now() - 3600000).toISOString();
  const recent = (await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM recs WHERE created_by=?1 AND created_at>?2").bind(auth.uid, since).first<any>()).n;
  if (Number(recent) >= RECS_PER_HOUR) return json({ error: "That's a lot of recommendations at once — try again a little later." }, 429);
  const id = crypto.randomUUID();
  await env.CLUBS_DB.prepare(
    "INSERT INTO recs (id,category,book_title,book_author,book_isbn,cover_url,note,created_by,created_name,created_at,deleted) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,0)"
  ).bind(id, category, title, String(b.bookAuthor || "").slice(0, 200), String(b.bookIsbn || "").slice(0, 20), String(b.coverUrl || "").slice(0, 500), String(b.note || "").slice(0, 500), auth.uid, String(b.displayName || "").slice(0, 60), now).run();
  // Recommending a book counts as endorsing it — auto-cast a "worth reading" vote.
  await env.CLUBS_DB.prepare("INSERT OR REPLACE INTO rec_votes (rec_id,uid,vote,created_at) VALUES (?1,?2,1,?3)").bind(id, auth.uid, now).run();
  return json({ ok: true, id });
}
async function recsVote(request: Request, id: string, auth: { uid: string }, env: Env) {
  const b = await request.json<any>().catch(() => ({}));
  const vote = Number(b.vote) === -1 ? -1 : 1;
  const rec = await env.CLUBS_DB.prepare("SELECT id FROM recs WHERE id=?1 AND deleted=0").bind(id).first<any>();
  if (!rec) return json({ error: "That recommendation no longer exists." }, 404);
  const existing = await env.CLUBS_DB.prepare("SELECT vote FROM rec_votes WHERE rec_id=?1 AND uid=?2").bind(id, auth.uid).first<any>();
  if (existing && existing.vote === vote) {
    await env.CLUBS_DB.prepare("DELETE FROM rec_votes WHERE rec_id=?1 AND uid=?2").bind(id, auth.uid).run();
    return json({ ok: true, myVote: 0 });
  }
  await env.CLUBS_DB.prepare("INSERT OR REPLACE INTO rec_votes (rec_id,uid,vote,created_at) VALUES (?1,?2,?3,?4)").bind(id, auth.uid, vote, new Date().toISOString()).run();
  return json({ ok: true, myVote: vote });
}
async function recsDelete(id: string, auth: { uid: string }, env: Env) {
  const rec = await env.CLUBS_DB.prepare("SELECT created_by FROM recs WHERE id=?1 AND deleted=0").bind(id).first<any>();
  if (!rec) return json({ error: "Not found." }, 404);
  if (rec.created_by !== auth.uid) return json({ error: "You can only remove your own recommendation." }, 403);
  await env.CLUBS_DB.batch([
    env.CLUBS_DB.prepare("UPDATE recs SET deleted=1 WHERE id=?1").bind(id),
    env.CLUBS_DB.prepare("DELETE FROM rec_votes WHERE rec_id=?1").bind(id),
  ]);
  return json({ ok: true });
}
async function recsRouter(url: URL, request: Request, env: Env) {
  if (!env.CLUBS_DB) return json({ error: "Recommendations aren't enabled on this server yet." }, 503);
  const parts = url.pathname.split("/").filter(Boolean); // ["api","recs", id?, sub?]
  const id = parts[2], sub = parts[3];
  const m = request.method;
  const auth = await requireAuth(request, env); // may be null — viewing is public
  if (!id) {
    if (m === "GET") return recsList(env, auth);
    if (m === "POST") return auth ? recsCreate(request, auth, env) : json({ error: "Not signed in." }, 401);
  } else if (sub === "vote" && m === "POST") {
    return auth ? recsVote(request, id, auth, env) : json({ error: "Not signed in." }, 401);
  } else if (sub === "delete" && m === "POST") {
    return auth ? recsDelete(id, auth, env) : json({ error: "Not signed in." }, 401);
  } else if (sub === "report" && m === "POST") {
    return auth ? reportCreate(request, "rec", id, null, auth, env) : json({ error: "Not signed in." }, 401);
  }
  return json({ error: "Not found" }, 404);
}

// ---- Moderation: filter, report, block --------------------------------------
// The community board is public, unmoderated, user-generated content, which needs
// three things that didn't exist: something stopping the worst posts at the door,
// a way to flag what gets through, and a way to never see one person again.
//
// The three are deliberately different in kind. The filter is narrow and dumb.
// Reports are the real mechanism, and they take an item down automatically —
// waiting for a human to wake up is not a takedown policy for a project with no
// one on call. Blocking is per-viewer and changes nothing for anyone else.

const REPORT_REASONS = new Set(["spam", "harassment", "sexual", "violence", "hate", "spoiler", "other"]);
/** Distinct reporters that hide an item outright, pending review. */
const REPORT_AUTOHIDE = 3;
const REPORTS_PER_HOUR = 20;

/**
 * The write-side filter, kept deliberately narrow.
 *
 * A book board is precisely where a frank note about Lolita, Beloved or American
 * Psycho is the whole point, so this does not try to be a profanity net —
 * over-filtering a recommendation board is its own failure, and a false positive
 * on someone's honest review is worse than a slur that three people then report.
 * It catches the two things that are never a real recommendation: unambiguous
 * slurs used as slurs, and links.
 */
const BLOCKED_TERMS = [
  "nigger", "niggers", "faggot", "faggots", "kike", "kikes",
  "spic", "spics", "chink", "chinks", "tranny", "trannies", "retard", "retards",
];
const LINK_RE = /(?:https?:\/\/|\bwww\.)\S/i;
function contentProblem(text: string): string | null {
  const raw = String(text || "");
  if (!raw.trim()) return null;
  // Links: the board has a cover-image field of its own, so a URL in prose is
  // either spam or an affiliate tag. One rule, easy to explain, no judgement call.
  if (LINK_RE.test(raw)) return "Please leave out web links — just tell people about the book.";
  // Collapse to letters-and-spaces and match on whole words, so Scunthorpe,
  // "Dick Francis" and "classic" all survive.
  const padded = " " + raw.toLowerCase().replace(/[^a-z]+/g, " ").trim() + " ";
  for (const term of BLOCKED_TERMS) {
    if (padded.indexOf(" " + term + " ") >= 0) return "That wording isn't allowed here. Please rephrase.";
  }
  return null;
}

/**
 * File a report against a rec or a club comment.
 *
 * The visibility check is not a formality: without it, "report comment X" answers
 * whether comment X exists, which hands anyone an oracle for the spoiler gate the
 * clubs feature is built around. You can only report what you can already see.
 */
async function reportCreate(request: Request, kind: "rec" | "comment", targetId: string, clubId: string | null, auth: { uid: string }, env: Env) {
  const b = await smallJson(request);
  const reason = String(b.reason || "").trim().toLowerCase();
  if (!REPORT_REASONS.has(reason)) return json({ error: "Please choose a reason for the report." }, 400);
  const detail = String(b.detail || "").slice(0, 500);
  // Reporting is itself abusable — a script filing three reports on everything
  // would be a takedown button. Cap it, and require distinct accounts to hide.
  const since = new Date(Date.now() - 3600000).toISOString();
  const recent = Number((await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE reporter_uid=?1 AND created_at>?2").bind(auth.uid, since).first<any>()).n) || 0;
  if (recent >= REPORTS_PER_HOUR) return json({ error: "That's a lot of reports at once — please try again a little later." }, 429);

  let targetUid = "";
  if (kind === "rec") {
    const rec = await env.CLUBS_DB.prepare("SELECT created_by FROM recs WHERE id=?1 AND deleted=0").bind(targetId).first<any>();
    if (!rec) return json({ error: "That post no longer exists." }, 404);
    targetUid = rec.created_by;
  } else {
    const me = await clubMember(env, String(clubId), auth.uid);
    if (!me) return json({ error: "Not a member of this club." }, 403);
    const c = await env.CLUBS_DB.prepare("SELECT uid, pos_pct FROM comments WHERE id=?1 AND club_id=?2 AND deleted=0").bind(targetId, clubId).first<any>();
    // Same answer for "doesn't exist" and "is past your progress", so the 404
    // can't be used to probe what's written ahead of you.
    if (!c || c.pos_pct > me.progress_pct) return json({ error: "That comment isn't available." }, 404);
    targetUid = c.uid;
  }

  // INSERT OR IGNORE plus the UNIQUE(kind,target_id,reporter_uid) constraint makes
  // reporting idempotent, and the response is identical either way — telling
  // someone "you already reported this" is noise, not information.
  await env.CLUBS_DB.prepare(
    "INSERT OR IGNORE INTO reports (id,kind,target_id,target_uid,reporter_uid,reason,detail,created_at,status) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'open')"
  ).bind(crypto.randomUUID(), kind, targetId, targetUid, auth.uid, reason, detail, new Date().toISOString()).run();

  const n = Number((await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE kind=?1 AND target_id=?2").bind(kind, targetId).first<any>()).n) || 0;
  let hidden = false;
  if (n >= REPORT_AUTOHIDE) {
    hidden = true;
    await env.CLUBS_DB.prepare(
      kind === "rec" ? "UPDATE recs SET deleted=1 WHERE id=?1" : "UPDATE comments SET deleted=1 WHERE id=?1"
    ).bind(targetId).run();
  }
  return json({ ok: true, hidden });
}

async function blocksList(auth: { uid: string }, env: Env) {
  const blocks = (await env.CLUBS_DB.prepare("SELECT blocked_uid, created_at FROM blocks WHERE uid=?1 ORDER BY created_at DESC").bind(auth.uid).all()).results as any[] || [];
  return json({ blocks });
}
async function blockCreate(request: Request, auth: { uid: string }, env: Env) {
  const b = await smallJson(request);
  const target = String(b.uid || "").trim().slice(0, 64);
  if (!target) return json({ error: "Nobody to block." }, 400);
  if (target === auth.uid) return json({ error: "You can't block yourself." }, 400);
  // No existence check on purpose: confirming whether a uid is real would turn
  // this into a membership lookup, and blocking a stranger costs one dead row.
  await env.CLUBS_DB.prepare("INSERT OR IGNORE INTO blocks (uid,blocked_uid,created_at) VALUES (?1,?2,?3)")
    .bind(auth.uid, target, new Date().toISOString()).run();
  return json({ ok: true });
}
async function blockDelete(target: string, auth: { uid: string }, env: Env) {
  await env.CLUBS_DB.prepare("DELETE FROM blocks WHERE uid=?1 AND blocked_uid=?2").bind(auth.uid, target).run();
  return json({ ok: true });
}
async function blocksRouter(url: URL, request: Request, env: Env) {
  if (!env.CLUBS_DB) return json({ error: "Not available on this server yet." }, 503);
  const parts = url.pathname.split("/").filter(Boolean); // ["api","blocks", uid?]
  const auth = await requireAuth(request, env);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const m = request.method;
  if (!parts[2]) {
    if (m === "GET") return blocksList(auth, env);
    if (m === "POST") return blockCreate(request, auth, env);
  } else if (m === "DELETE") {
    return blockDelete(parts[2], auth, env);
  }
  return json({ error: "Not found" }, 404);
}

/**
 * The review queue. Gated on ADMIN_UIDS, and answers 404 rather than 403 to
 * anyone else — a 403 confirms the endpoint is here and worth attacking.
 * Unset ADMIN_UIDS means nobody can review, which is a deliberate default:
 * reports still accumulate and auto-hide still fires without it.
 */
function isAdmin(env: Env, uid: string) {
  return String(env.ADMIN_UIDS || "").split(",").map((s) => s.trim()).filter(Boolean).indexOf(uid) >= 0;
}
async function moderationList(auth: { uid: string }, env: Env) {
  if (!isAdmin(env, auth.uid)) return json({ error: "Not found" }, 404);
  // Join the content in, so reviewing doesn't mean a second query per row.
  const reports = (await env.CLUBS_DB.prepare(
    "SELECT r.*, COALESCE(rc.book_title, '') AS rec_title, COALESCE(rc.note, '') AS rec_note, " +
    "COALESCE(cm.body, '') AS comment_body, COALESCE(rc.deleted, cm.deleted, 0) AS target_hidden " +
    "FROM reports r LEFT JOIN recs rc ON r.kind='rec' AND rc.id=r.target_id " +
    "LEFT JOIN comments cm ON r.kind='comment' AND cm.id=r.target_id " +
    "WHERE r.status='open' ORDER BY r.created_at DESC LIMIT 200"
  ).all()).results as any[] || [];
  return json({ reports, autoHideAt: REPORT_AUTOHIDE });
}
async function moderationAction(request: Request, id: string, auth: { uid: string }, env: Env) {
  if (!isAdmin(env, auth.uid)) return json({ error: "Not found" }, 404);
  const b = await smallJson(request);
  const action = String(b.action || "");
  if (["hide", "restore", "dismiss"].indexOf(action) < 0) return json({ error: "Unknown action." }, 400);
  const rep = await env.CLUBS_DB.prepare("SELECT kind, target_id FROM reports WHERE id=?1").bind(id).first<any>();
  if (!rep) return json({ error: "Not found." }, 404);
  const table = rep.kind === "rec" ? "recs" : "comments";
  const stmts: any[] = [];
  if (action === "hide") stmts.push(env.CLUBS_DB.prepare(`UPDATE ${table} SET deleted=1 WHERE id=?1`).bind(rep.target_id));
  if (action === "restore") stmts.push(env.CLUBS_DB.prepare(`UPDATE ${table} SET deleted=0 WHERE id=?1`).bind(rep.target_id));
  // Resolve every report on the same item, not just the one that was clicked —
  // otherwise a reviewed item comes back up the queue once per reporter.
  stmts.push(env.CLUBS_DB.prepare("UPDATE reports SET status=?3 WHERE kind=?1 AND target_id=?2")
    .bind(rep.kind, rep.target_id, action === "dismiss" ? "dismissed" : "actioned"));
  await env.CLUBS_DB.batch(stmts);
  return json({ ok: true });
}
async function moderationRouter(url: URL, request: Request, env: Env) {
  if (!env.CLUBS_DB) return json({ error: "Not found" }, 404);
  const parts = url.pathname.split("/").filter(Boolean); // ["api","moderation","reports", id?]
  const auth = await requireAuth(request, env);
  if (!auth) return json({ error: "Not found" }, 404);
  if (parts[2] !== "reports") return json({ error: "Not found" }, 404);
  if (!parts[3] && request.method === "GET") return moderationList(auth, env);
  if (parts[3] && request.method === "POST") return moderationAction(request, parts[3], auth, env);
  return json({ error: "Not found" }, 404);
}

// A 30-day token is only as strong as the key that signs it: with a short secret,
// forging one is a brute force away and every account is open. `openssl rand -hex 32`
// gives 64 chars — refuse to serve rather than pretend to be authenticated.
const MIN_SECRET_CHARS = 32;

async function route(url: URL, request: Request, env: Env, ctx: ExecutionContext) {
  const m = request.method;
  if (url.pathname === "/api/register" && m === "POST") return register(request, env, env.AUTH_SECRET);
  if (url.pathname === "/api/login" && m === "POST") return login(request, env, env.AUTH_SECRET);
  if (url.pathname === "/api/password/change" && m === "POST") return passwordChange(request, env, env.AUTH_SECRET);
  if (url.pathname === "/api/password/forgot" && m === "POST") return passwordForgot(request, env, ctx);
  if (url.pathname === "/api/password/reset" && m === "POST") return passwordReset(request, env, env.AUTH_SECRET);
  if (url.pathname === "/api/data" && m === "GET") return getData(request, env);
  if (url.pathname === "/api/data" && m === "PUT") return putData(request, env);
  if (url.pathname === "/api/account" && m === "DELETE") return accountDelete(request, env, ctx);
  if (url.pathname === "/api/clubs" || url.pathname.indexOf("/api/clubs/") === 0) return clubsRouter(url, request, env, ctx);
  if (url.pathname === "/api/recs" || url.pathname.indexOf("/api/recs/") === 0) return recsRouter(url, request, env);
  if (url.pathname === "/api/blocks" || url.pathname.indexOf("/api/blocks/") === 0) return blocksRouter(url, request, env);
  if (url.pathname.indexOf("/api/moderation/") === 0) return moderationRouter(url, request, env);
  if (url.pathname === "/" || url.pathname === "/api") {
    return json({
      ok: true, service: "enkelas-bookshelf-sync",
      clubs: !!env.CLUBS_DB, recs: !!env.CLUBS_DB, realtime: !!env.CLUB_ROOMS,
      // The client hides "Forgot password?" when nothing can deliver the link,
      // rather than promising an email that will never arrive.
      passwordReset: mailerReady(env),
      // Deleting an account needs no binding beyond KV, so it's always on. Report
      // and block need the D1 tables, so the client can tell whether to offer them.
      accountDelete: true,
      moderation: !!env.CLUBS_DB,
    });
  }
  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const cors = corsHeaders(request, env);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (!env.AUTH_SECRET) return json({ error: "Server not configured (missing AUTH_SECRET)." }, 500, cors);
    if (env.AUTH_SECRET.length < MIN_SECRET_CHARS) {
      console.error("AUTH_SECRET is only " + env.AUTH_SECRET.length + " characters; need at least " + MIN_SECRET_CHARS + ". See DEPLOY.md.");
      return json({ error: "Server misconfigured (weak AUTH_SECRET) — see the deploy notes." }, 500, cors);
    }
    const url = new URL(request.url);
    let res: Response;
    try {
      res = await route(url, request, env, ctx);
    } catch (e) {
      // Log the cause — a bare "Server error" with nothing in the tail log makes
      // these impossible to diagnose (`wrangler tail` is free).
      console.error("worker error", request.method, url.pathname, e instanceof Error ? (e.stack || e.message) : String(e));
      res = json({ error: "Server error" }, 500);
    }
    // CORS and the security headers get bolted on here, once, so a handler can't
    // ship a response without them. A 101 carries a live socket and must be
    // returned untouched — rebuilding it would drop the WebSocket.
    if (res.status === 101 || (res as any).webSocket) return res;
    const out = new Response(res.body, res);
    for (const k in cors) out.headers.set(k, cors[k]);
    return out;
  },
};

// One Durable Object per club = a realtime hub. Members open a WebSocket to it;
// when the worker writes to D1 it pings /broadcast and the DO relays a small nudge
// ("something changed") to every connected socket, which then re-fetches from D1
// (so the spoiler gate stays server-enforced — the socket carries no book content).
export class ClubRoom {
  state: DurableObjectState;
  constructor(state: DurableObjectState) { this.state = state; }
  async fetch(request: Request) {
    const url = new URL(request.url);
    if (url.pathname.endsWith("/ws")) {
      if ((request.headers.get("Upgrade") || "").toLowerCase() !== "websocket") return new Response("expected websocket", { status: 426 });
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.state.acceptWebSocket(server); // hibernation API: survives DO sleep
      return new Response(null, { status: 101, webSocket: client });
    }
    if (url.pathname.endsWith("/broadcast") && request.method === "POST") {
      const msg = await request.text();
      for (const ws of this.state.getWebSockets()) { try { ws.send(msg); } catch (e) { /* drop dead sockets */ } }
      return new Response("ok");
    }
    return new Response("not found", { status: 404 });
  }
  webSocketMessage() { /* clients don't send; ignore */ }
  webSocketClose(ws: WebSocket) { try { ws.close(); } catch (e) { /* already closed */ } }
  webSocketError() { /* socket dropped; nothing to do */ }
}
