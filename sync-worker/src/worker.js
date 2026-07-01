/* Enkela's Bookshelf — sync worker (Cloudflare Workers + KV).
 *
 * Per-user accounts (email + full name + password) and a private data blob per user.
 * No third-party libraries: password hashing via PBKDF2 (WebCrypto), sessions via
 * HMAC-signed tokens. KV keys:
 *   user:<email-lowercased>  -> { id, email, fullName, salt, hash, iterations, createdAt }
 *   data:<userId>            -> { blob, updatedAt }
 */

const enc = new TextEncoder();
const dec = new TextDecoder();

// ---- CORS -------------------------------------------------------------------
function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*", // token auth, no cookies → wildcard is safe
    "Access-Control-Allow-Methods": "GET,POST,PUT,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
  };
}
function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders() },
  });
}

// ---- base64url --------------------------------------------------------------
function b64url(bytes) {
  const b = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : bytes;
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToBytes(str) {
  str = String(str).replace(/-/g, "+").replace(/_/g, "/");
  while (str.length % 4) str += "=";
  const bin = atob(str);
  const arr = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
  return arr;
}
function randomBytes(n) { const a = new Uint8Array(n); crypto.getRandomValues(a); return a; }

// ---- password hashing (PBKDF2-SHA256) ---------------------------------------
async function pbkdf2(password, salt, iterations) {
  const key = await crypto.subtle.importKey("raw", enc.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations, hash: "SHA-256" }, key, 256);
  return new Uint8Array(bits);
}
async function makePasswordRecord(password) {
  const salt = randomBytes(16);
  const iterations = 100000; // Cloudflare Workers caps PBKDF2 at 100k
  const hash = await pbkdf2(password, salt, iterations);
  return { salt: b64url(salt), hash: b64url(hash), iterations };
}
async function verifyPassword(password, rec) {
  const salt = b64urlToBytes(rec.salt);
  const hash = await pbkdf2(password, salt, rec.iterations || 100000);
  const expected = b64urlToBytes(rec.hash);
  if (hash.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < hash.length; i++) diff |= hash[i] ^ expected[i];
  return diff === 0;
}

// ---- HMAC session tokens ----------------------------------------------------
async function hmacKey(secret) {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}
async function makeToken(uid, secret, days = 30) {
  const payload = { uid, exp: Math.floor(Date.now() / 1000) + days * 86400 };
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(body));
  return body + "." + b64url(sig);
}
async function verifyToken(token, secret) {
  if (!token || token.indexOf(".") < 0) return null;
  const [body, sig] = token.split(".");
  const ok = await crypto.subtle.verify("HMAC", await hmacKey(secret), b64urlToBytes(sig), enc.encode(body)).catch(() => false);
  if (!ok) return null;
  try {
    const payload = JSON.parse(dec.decode(b64urlToBytes(body)));
    if (!payload.exp || payload.exp < Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch (e) { return null; }
}
async function requireAuth(request, secret) {
  const h = request.headers.get("Authorization") || "";
  const token = h.indexOf("Bearer ") === 0 ? h.slice(7) : "";
  return verifyToken(token, secret);
}

// ---- handlers ---------------------------------------------------------------
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

async function register(request, env, secret) {
  const b = await request.json().catch(() => ({}));
  const email = String(b.email || "").trim().toLowerCase();
  const fullName = String(b.fullName || "").trim();
  const password = String(b.password || "");
  if (!EMAIL_RE.test(email)) return json({ error: "Please enter a valid email address." }, 400);
  if (!fullName) return json({ error: "Please enter your full name." }, 400);
  if (password.length < 8) return json({ error: "Password must be at least 8 characters." }, 400);
  if (await env.BOOKSHELF.get("user:" + email)) return json({ error: "An account with this email already exists." }, 409);
  const rec = await makePasswordRecord(password);
  const id = crypto.randomUUID();
  await env.BOOKSHELF.put("user:" + email, JSON.stringify({ id, email, fullName, ...rec, createdAt: new Date().toISOString() }));
  return json({ token: await makeToken(id, secret), user: { id, email, fullName } });
}

async function login(request, env, secret) {
  const b = await request.json().catch(() => ({}));
  const email = String(b.email || "").trim().toLowerCase();
  const password = String(b.password || "");
  // Light throttle: max 10 failed attempts per email per 15 min.
  const tKey = "throttle:" + email;
  const attempts = Number(await env.BOOKSHELF.get(tKey)) || 0;
  if (attempts >= 10) return json({ error: "Too many attempts. Please wait a few minutes." }, 429);
  const raw = await env.BOOKSHELF.get("user:" + email);
  const user = raw ? JSON.parse(raw) : null;
  const ok = user ? await verifyPassword(password, user) : false;
  if (!ok) {
    await env.BOOKSHELF.put(tKey, String(attempts + 1), { expirationTtl: 900 });
    return json({ error: raw ? "Wrong password." : "No account found with that email." }, 401);
  }
  return json({ token: await makeToken(user.id, secret), user: { id: user.id, email: user.email, fullName: user.fullName } });
}

async function getData(request, env, secret) {
  const auth = await requireAuth(request, secret);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const raw = await env.BOOKSHELF.get("data:" + auth.uid);
  return json(raw ? JSON.parse(raw) : { blob: null, updatedAt: null });
}

async function putData(request, env, secret) {
  const auth = await requireAuth(request, secret);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const b = await request.json().catch(() => ({}));
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
  await env.BOOKSHELF.put("data:" + auth.uid, JSON.stringify({ blob: b.blob, updatedAt }));
  return json({ ok: true, updatedAt });
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });
    if (!env.AUTH_SECRET) return json({ error: "Server not configured (missing AUTH_SECRET)." }, 500);
    const url = new URL(request.url);
    try {
      if (url.pathname === "/api/register" && request.method === "POST") return await register(request, env, env.AUTH_SECRET);
      if (url.pathname === "/api/login" && request.method === "POST") return await login(request, env, env.AUTH_SECRET);
      if (url.pathname === "/api/data" && request.method === "GET") return await getData(request, env, env.AUTH_SECRET);
      if (url.pathname === "/api/data" && request.method === "PUT") return await putData(request, env, env.AUTH_SECRET);
      if (url.pathname === "/" || url.pathname === "/api") return json({ ok: true, service: "enkelas-bookshelf-sync" });
      return json({ error: "Not found" }, 404);
    } catch (e) {
      return json({ error: "Server error" }, 500);
    }
  },
};
