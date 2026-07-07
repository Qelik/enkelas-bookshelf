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
function clampPct(n) { n = Math.round(Number(n) || 0); return n < 0 ? 0 : n > 100 ? 100 : n; }
function clubMember(env, clubId, uid) {
  return env.CLUBS_DB.prepare("SELECT * FROM members WHERE club_id=?1 AND uid=?2").bind(clubId, uid).first();
}

async function clubsList(auth, env) {
  const clubs = (await env.CLUBS_DB.prepare(
    "SELECT c.* FROM clubs c JOIN members m ON m.club_id=c.id WHERE m.uid=?1 AND c.archived=0 ORDER BY c.created_at DESC"
  ).bind(auth.uid).all()).results || [];
  for (const c of clubs) {
    c.members = (await env.CLUBS_DB.prepare("SELECT uid, display_name, role, progress_pct FROM members WHERE club_id=?1 ORDER BY progress_pct DESC").bind(c.id).all()).results || [];
    c.me = c.members.find((m) => m.uid === auth.uid) || null;
  }
  return json({ clubs });
}
async function clubCreate(request, auth, env) {
  const b = await request.json().catch(() => ({}));
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
async function clubJoin(request, auth, env) {
  const b = await request.json().catch(() => ({}));
  const code = String(b.joinCode || "").trim().toUpperCase();
  const name = String(b.displayName || "You").trim().slice(0, 60);
  const inv = await env.CLUBS_DB.prepare("SELECT * FROM invites WHERE code=?1").bind(code).first();
  if (!inv) return json({ error: "That join code doesn't exist." }, 404);
  if (await clubMember(env, inv.club_id, auth.uid)) return json({ ok: true, clubId: inv.club_id }); // already in
  const count = (await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM members WHERE club_id=?1").bind(inv.club_id).first()).n;
  if (count >= (inv.max_uses || MAX_MEMBERS)) return json({ error: "This club is full." }, 403);
  const now = new Date().toISOString();
  await env.CLUBS_DB.batch([
    env.CLUBS_DB.prepare("INSERT INTO members (club_id,uid,display_name,role,progress_pct,joined_at) VALUES (?1,?2,?3,'member',0,?4)").bind(inv.club_id, auth.uid, name, now),
    env.CLUBS_DB.prepare("UPDATE invites SET uses=uses+1 WHERE code=?1").bind(code),
  ]);
  return json({ ok: true, clubId: inv.club_id });
}
async function clubDetail(clubId, auth, env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const club = await env.CLUBS_DB.prepare("SELECT * FROM clubs WHERE id=?1").bind(clubId).first();
  if (!club) return json({ error: "Club not found." }, 404);
  const members = (await env.CLUBS_DB.prepare("SELECT uid, display_name, role, progress_pct FROM members WHERE club_id=?1 ORDER BY progress_pct DESC").bind(clubId).all()).results || [];
  const invite = await env.CLUBS_DB.prepare("SELECT code FROM invites WHERE club_id=?1 LIMIT 1").bind(clubId).first();
  return json({ club, me, members, joinCode: invite ? invite.code : null });
}
async function clubComments(clubId, auth, env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const comments = (await env.CLUBS_DB.prepare(
    "SELECT c.id,c.uid,m.display_name,c.pos_pct,c.chapter,c.label,c.body,c.created_at " +
    "FROM comments c JOIN members m ON m.club_id=c.club_id AND m.uid=c.uid " +
    "WHERE c.club_id=?1 AND c.deleted=0 AND c.pos_pct<=?2 ORDER BY c.pos_pct ASC, c.created_at ASC"
  ).bind(clubId, me.progress_pct).all()).results || [];
  // Reactions for the comments this member is allowed to see (same gate).
  const reacts = (await env.CLUBS_DB.prepare(
    "SELECT r.comment_id, r.emoji, r.uid FROM reactions r JOIN comments c ON c.id=r.comment_id " +
    "WHERE c.club_id=?1 AND c.deleted=0 AND c.pos_pct<=?2"
  ).bind(clubId, me.progress_pct).all()).results || [];
  const byComment = {};
  for (const r of reacts) {
    const e = (byComment[r.comment_id] = byComment[r.comment_id] || { counts: {}, mine: [] });
    e.counts[r.emoji] = (e.counts[r.emoji] || 0) + 1;
    if (r.uid === auth.uid) e.mine.push(r.emoji);
  }
  for (const c of comments) c.reactions = byComment[c.id] || { counts: {}, mine: [] };
  const lockedAhead = (await env.CLUBS_DB.prepare("SELECT COUNT(*) AS n FROM comments WHERE club_id=?1 AND deleted=0 AND pos_pct>?2").bind(clubId, me.progress_pct).first()).n;
  return json({ comments, lockedAhead, myProgress: me.progress_pct });
}
async function clubPostComment(request, clubId, auth, env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json().catch(() => ({}));
  const body = String(b.body || "").trim().slice(0, 2000);
  if (!body) return json({ error: "Empty comment." }, 400);
  await env.CLUBS_DB.prepare("INSERT INTO comments (id,club_id,uid,pos_pct,chapter,label,body,created_at,deleted) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,0)")
    .bind(crypto.randomUUID(), clubId, auth.uid, clampPct(b.posPct), (b.chapter != null ? Number(b.chapter) : null), (b.label ? String(b.label).slice(0, 60) : null), body, new Date().toISOString()).run();
  return json({ ok: true });
}
async function clubProgress(request, clubId, auth, env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json().catch(() => ({}));
  // forward-only, so a re-read or sync hiccup can never un-reveal a spoiler
  await env.CLUBS_DB.prepare("UPDATE members SET progress_pct=MAX(progress_pct,?3) WHERE club_id=?1 AND uid=?2").bind(clubId, auth.uid, clampPct(b.progressPct)).run();
  return json({ ok: true });
}
async function clubReact(request, clubId, auth, env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json().catch(() => ({}));
  const emoji = String(b.emoji || "").slice(0, 8);
  const commentId = String(b.commentId || "");
  if (!emoji || !commentId) return json({ error: "Missing reaction." }, 400);
  // Can only react to a comment you're allowed to see (at/below your progress).
  const c = await env.CLUBS_DB.prepare("SELECT pos_pct FROM comments WHERE id=?1 AND club_id=?2 AND deleted=0").bind(commentId, clubId).first();
  if (!c || c.pos_pct > me.progress_pct) return json({ error: "Comment not available." }, 403);
  const existing = await env.CLUBS_DB.prepare("SELECT 1 FROM reactions WHERE comment_id=?1 AND uid=?2 AND emoji=?3").bind(commentId, auth.uid, emoji).first();
  if (existing) {
    await env.CLUBS_DB.prepare("DELETE FROM reactions WHERE comment_id=?1 AND uid=?2 AND emoji=?3").bind(commentId, auth.uid, emoji).run();
    return json({ ok: true, reacted: false });
  }
  await env.CLUBS_DB.prepare("INSERT INTO reactions (comment_id,uid,emoji,created_at) VALUES (?1,?2,?3,?4)").bind(commentId, auth.uid, emoji, new Date().toISOString()).run();
  return json({ ok: true, reacted: true });
}
async function clubLeave(clubId, auth, env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  await env.CLUBS_DB.prepare("DELETE FROM members WHERE club_id=?1 AND uid=?2").bind(clubId, auth.uid).run();
  return json({ ok: true });
}
async function clubsRouter(url, request, env) {
  const auth = await requireAuth(request, env.AUTH_SECRET);
  if (!auth) return json({ error: "Not signed in." }, 401);
  if (!env.CLUBS_DB) return json({ error: "Reading clubs aren't enabled on this server yet." }, 503);
  const parts = url.pathname.split("/").filter(Boolean); // ["api","clubs", id?, sub?]
  const id = parts[2], sub = parts[3];
  const m = request.method;
  if (!id) {
    if (m === "GET") return clubsList(auth, env);
    if (m === "POST") return clubCreate(request, auth, env);
  } else if (id === "join" && m === "POST") {
    return clubJoin(request, auth, env);
  } else if (id && !sub && m === "GET") {
    return clubDetail(id, auth, env);
  } else if (sub === "comments" && m === "GET") {
    return clubComments(id, auth, env);
  } else if (sub === "comments" && m === "POST") {
    return clubPostComment(request, id, auth, env);
  } else if (sub === "progress" && m === "PUT") {
    return clubProgress(request, id, auth, env);
  } else if (sub === "reactions" && m === "POST") {
    return clubReact(request, id, auth, env);
  } else if (sub === "leave" && m === "POST") {
    return clubLeave(id, auth, env);
  }
  return json({ error: "Not found" }, 404);
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
      if (url.pathname === "/api/clubs" || url.pathname.indexOf("/api/clubs/") === 0) return await clubsRouter(url, request, env);
      if (url.pathname === "/" || url.pathname === "/api") return json({ ok: true, service: "enkelas-bookshelf-sync", clubs: !!env.CLUBS_DB });
      return json({ error: "Not found" }, 404);
    } catch (e) {
      return json({ error: "Server error" }, 500);
    }
  },
};
