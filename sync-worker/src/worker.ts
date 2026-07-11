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
function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json", ...corsHeaders() },
  });
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

// ---- HMAC session tokens ----------------------------------------------------
async function hmacKey(secret: string) {
  return crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}
async function makeToken(uid: string, secret: string, days = 30) {
  const payload = { uid, exp: Math.floor(Date.now() / 1000) + days * 86400 };
  const body = b64url(enc.encode(JSON.stringify(payload)));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(secret), enc.encode(body));
  return body + "." + b64url(sig);
}
async function verifyToken(token: string, secret: string) {
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
async function requireAuth(request: Request, secret: string) {
  const h = request.headers.get("Authorization") || "";
  const token = h.indexOf("Bearer ") === 0 ? h.slice(7) : "";
  return verifyToken(token, secret);
}

// ---- handlers ---------------------------------------------------------------
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

async function register(request: Request, env: Env, secret: string) {
  const b = await request.json<any>().catch(() => ({}));
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

async function login(request: Request, env: Env, secret: string) {
  const b = await request.json<any>().catch(() => ({}));
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

async function getData(request: Request, env: Env, secret: string) {
  const auth = await requireAuth(request, secret);
  if (!auth) return json({ error: "Not signed in." }, 401);
  const raw = await env.BOOKSHELF.get("data:" + auth.uid);
  return json(raw ? JSON.parse(raw) : { blob: null, updatedAt: null });
}

async function putData(request: Request, env: Env, secret: string) {
  const auth = await requireAuth(request, secret);
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
function clampPct(n: any) { n = Math.round(Number(n) || 0); return n < 0 ? 0 : n > 100 ? 100 : n; }
function clubMember(env: Env, clubId: string, uid: string) {
  return env.CLUBS_DB.prepare("SELECT * FROM members WHERE club_id=?1 AND uid=?2").bind(clubId, uid).first<any>();
}
function touchClub(env: Env, clubId: string) {
  return env.CLUBS_DB.prepare("UPDATE clubs SET last_activity=?2 WHERE id=?1").bind(clubId, new Date().toISOString()).run();
}
// Realtime is best-effort: nudge the club's Durable Object to broadcast to any
// connected members. D1 stays the source of truth (and the spoiler gate).
function notifyClub(env: Env, clubId: string, payload: unknown) {
  if (!env.CLUB_ROOMS) return;
  try {
    const stub = env.CLUB_ROOMS.get(env.CLUB_ROOMS.idFromName(clubId));
    stub.fetch(new Request("https://club/broadcast", { method: "POST", body: JSON.stringify(payload || {}) }));
  } catch (e) { /* realtime unavailable — clients still poll */ }
}
async function clubWs(url: URL, request: Request, env: Env, clubId: string) {
  if (!env.CLUB_ROOMS) return new Response("realtime unavailable", { status: 503 });
  const auth = await verifyToken(url.searchParams.get("token") || "", env.AUTH_SECRET);
  if (!auth) return new Response("unauthorized", { status: 401 });
  if (!(await clubMember(env, clubId, auth.uid))) return new Response("forbidden", { status: 403 });
  const stub = env.CLUB_ROOMS.get(env.CLUB_ROOMS.idFromName(clubId));
  return stub.fetch(new Request("https://club/ws", request));
}

async function clubsList(auth: { uid: string }, env: Env) {
  const clubs = (await env.CLUBS_DB.prepare(
    "SELECT c.* FROM clubs c JOIN members m ON m.club_id=c.id WHERE m.uid=?1 AND c.archived=0 ORDER BY c.created_at DESC"
  ).bind(auth.uid).all()).results as any[] || [];
  for (const c of clubs) {
    c.members = (await env.CLUBS_DB.prepare("SELECT uid, display_name, role, progress_pct FROM members WHERE club_id=?1 ORDER BY progress_pct DESC").bind(c.id).all()).results as any[] || [];
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
  const comments = (await env.CLUBS_DB.prepare(
    "SELECT c.id,c.uid,m.display_name,c.pos_pct,c.chapter,c.label,c.body,c.created_at " +
    "FROM comments c JOIN members m ON m.club_id=c.club_id AND m.uid=c.uid " +
    "WHERE c.club_id=?1 AND c.deleted=0 AND c.pos_pct<=?2 ORDER BY c.pos_pct ASC, c.created_at ASC"
  ).bind(clubId, me.progress_pct).all()).results as any[] || [];
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
async function clubPostComment(request: Request, clubId: string, auth: { uid: string }, env: Env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json<any>().catch(() => ({}));
  const body = String(b.body || "").trim().slice(0, 2000);
  if (!body) return json({ error: "Empty comment." }, 400);
  await env.CLUBS_DB.prepare("INSERT INTO comments (id,club_id,uid,pos_pct,chapter,label,body,created_at,deleted) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,0)")
    .bind(crypto.randomUUID(), clubId, auth.uid, clampPct(b.posPct), (b.chapter != null ? Number(b.chapter) : null), (b.label ? String(b.label).slice(0, 60) : null), body, new Date().toISOString()).run();
  await touchClub(env, clubId);
  notifyClub(env, clubId, { type: "comment" });
  return json({ ok: true });
}
async function clubProgress(request: Request, clubId: string, auth: { uid: string }, env: Env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  const b = await request.json<any>().catch(() => ({}));
  // forward-only, so a re-read or sync hiccup can never un-reveal a spoiler
  await env.CLUBS_DB.prepare("UPDATE members SET progress_pct=MAX(progress_pct,?3) WHERE club_id=?1 AND uid=?2").bind(clubId, auth.uid, clampPct(b.progressPct)).run();
  notifyClub(env, clubId, { type: "progress" });
  return json({ ok: true });
}
async function clubReact(request: Request, clubId: string, auth: { uid: string }, env: Env) {
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
    notifyClub(env, clubId, { type: "reaction" });
    return json({ ok: true, reacted: false });
  }
  await env.CLUBS_DB.prepare("INSERT INTO reactions (comment_id,uid,emoji,created_at) VALUES (?1,?2,?3,?4)").bind(commentId, auth.uid, emoji, new Date().toISOString()).run();
  notifyClub(env, clubId, { type: "reaction" });
  return json({ ok: true, reacted: true });
}
async function clubLeave(clubId: string, auth: { uid: string }, env: Env) {
  const me = await clubMember(env, clubId, auth.uid);
  if (!me) return json({ error: "Not a member of this club." }, 403);
  await env.CLUBS_DB.prepare("DELETE FROM members WHERE club_id=?1 AND uid=?2").bind(clubId, auth.uid).run();
  return json({ ok: true });
}
async function clubsRouter(url: URL, request: Request, env: Env) {
  if (!env.CLUBS_DB) return json({ error: "Reading clubs aren't enabled on this server yet." }, 503);
  const parts = url.pathname.split("/").filter(Boolean); // ["api","clubs", id?, sub?]
  const id = parts[2], sub = parts[3];
  const m = request.method;
  // Realtime WebSocket — a browser can't set an Authorization header on the WS
  // handshake, so the token arrives as a query param and is verified in clubWs.
  if (id && sub === "ws") return clubWs(url, request, env, id);
  const auth = await requireAuth(request, env.AUTH_SECRET);
  if (!auth) return json({ error: "Not signed in." }, 401);
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

// ---- Community recommendations (D1, shares CLUBS_DB) ------------------------
// One global, public board. Reading the board needs no account; recommending
// and voting do. Votes are 1 (worth reading) or -1 (not worth it), one per user
// per book, and clicking the same vote again clears it (toggle off).
async function recsList(env: Env, auth: { uid: string } | null) {
  const recs = (await env.CLUBS_DB.prepare(
    "SELECT id,category,book_title,book_author,book_isbn,cover_url,note,created_by,created_name,created_at FROM recs WHERE deleted=0"
  ).all()).results as any[] || [];
  const tallies = (await env.CLUBS_DB.prepare(
    "SELECT rec_id, SUM(CASE WHEN vote=1 THEN 1 ELSE 0 END) AS up, SUM(CASE WHEN vote=-1 THEN 1 ELSE 0 END) AS down FROM rec_votes GROUP BY rec_id"
  ).all()).results as any[] || [];
  const byId: Record<string, { up: number; down: number }> = {};
  for (const t of tallies) byId[t.rec_id] = { up: Number(t.up) || 0, down: Number(t.down) || 0 };
  const mine: Record<string, number> = {};
  if (auth) {
    const mv = (await env.CLUBS_DB.prepare("SELECT rec_id, vote FROM rec_votes WHERE uid=?1").bind(auth.uid).all()).results as any[] || [];
    for (const v of mv) mine[v.rec_id] = v.vote;
  }
  for (const r of recs) {
    const t = byId[r.id] || { up: 0, down: 0 };
    r.up = t.up; r.down = t.down; r.score = t.up - t.down;
    r.myVote = mine[r.id] || 0;
    r.mine = auth ? r.created_by === auth.uid : false;
  }
  return json({ recs, signedIn: !!auth });
}
async function recsCreate(request: Request, auth: { uid: string }, env: Env) {
  const b = await request.json<any>().catch(() => ({}));
  const title = String(b.bookTitle || "").trim().slice(0, 200);
  const category = String(b.category || "").trim().slice(0, 60) || "General";
  if (!title) return json({ error: "A book title is required." }, 400);
  const id = crypto.randomUUID();
  const now = new Date().toISOString();
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
  const auth = await requireAuth(request, env.AUTH_SECRET); // may be null — viewing is public
  if (!id) {
    if (m === "GET") return recsList(env, auth);
    if (m === "POST") return auth ? recsCreate(request, auth, env) : json({ error: "Not signed in." }, 401);
  } else if (sub === "vote" && m === "POST") {
    return auth ? recsVote(request, id, auth, env) : json({ error: "Not signed in." }, 401);
  } else if (sub === "delete" && m === "POST") {
    return auth ? recsDelete(id, auth, env) : json({ error: "Not signed in." }, 401);
  }
  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(request: Request, env: Env) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });
    if (!env.AUTH_SECRET) return json({ error: "Server not configured (missing AUTH_SECRET)." }, 500);
    const url = new URL(request.url);
    try {
      if (url.pathname === "/api/register" && request.method === "POST") return await register(request, env, env.AUTH_SECRET);
      if (url.pathname === "/api/login" && request.method === "POST") return await login(request, env, env.AUTH_SECRET);
      if (url.pathname === "/api/data" && request.method === "GET") return await getData(request, env, env.AUTH_SECRET);
      if (url.pathname === "/api/data" && request.method === "PUT") return await putData(request, env, env.AUTH_SECRET);
      if (url.pathname === "/api/clubs" || url.pathname.indexOf("/api/clubs/") === 0) return await clubsRouter(url, request, env);
      if (url.pathname === "/api/recs" || url.pathname.indexOf("/api/recs/") === 0) return await recsRouter(url, request, env);
      if (url.pathname === "/" || url.pathname === "/api") return json({ ok: true, service: "enkelas-bookshelf-sync", clubs: !!env.CLUBS_DB, recs: !!env.CLUBS_DB, realtime: !!env.CLUB_ROOMS });
      return json({ error: "Not found" }, 404);
    } catch (e) {
      return json({ error: "Server error" }, 500);
    }
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
