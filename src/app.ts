/* Enkela's Bookshelf — a no-backend reading tracker.
 * Data lives in a single JSON object, auto-saved to localStorage, and
 * optionally synced to a real bookshelf.json file via the File System Access API.
 */

import { EReader, initReader } from "./reader.js";
import type { AppState, Auth, Book, BookStatus, ChartItem, Club, ClubComment, ClubMember, OLDoc, ReadingLog, RecRow, SyncStatus } from "./types.js";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
const STORAGE_KEY = "enkelas-bookshelf-v1";
const THEME_KEY = "enkelas-bookshelf-theme";
const AUTH_KEY = "enkelas-bookshelf-auth";
const SYNCBASE_KEY = "enkelas-bookshelf-syncbase";
const LASTSYNC_KEY = "enkelas-bookshelf-lastsync";
const LASTEXPORT_KEY = "enkelas-last-export";
const BACKUPNAG_KEY = "enkelas-backup-nag";
const CONFLICTLOG_KEY = "enkelas-conflict-log";
const SCHEMA_VERSION = 1;
const APP_VERSION = "2026.07.10c"; // bump alongside the sw.js CACHE version on each release
const DAY = 86400000;
// URL of the Cloudflare sync worker. Empty = no accounts/sync (app stays fully local).
// Set after deploy; a per-device override can be set via localStorage "enkelas-sync-api".
let SYNC_API = "https://enkelas-bookshelf-sync.enkela.workers.dev";
try { SYNC_API = localStorage.getItem("enkelas-sync-api") || SYNC_API; } catch (e: any) { /* ignore */ }
const FORMAT_ICON = { physical: "📖", ebook: "📱", audio: "🎧" };

const PAGE_MILESTONES = [
  { n: 100,   emoji: "🌱", title: "First Chapter",   desc: "100 pages read" },
  { n: 200,   emoji: "📖", title: "Page Turner",     desc: "200 pages read" },
  { n: 500,   emoji: "🔖", title: "Bookmark Worthy",  desc: "500 pages read" },
  { n: 1000,  emoji: "📚", title: "Avid Reader",      desc: "1,000 pages read" },
  { n: 2500,  emoji: "🦉", title: "Night Owl",        desc: "2,500 pages read" },
  { n: 5000,  emoji: "🏛️", title: "Scholar",          desc: "5,000 pages read" },
  { n: 10000, emoji: "🐉", title: "Page Dragon",      desc: "10,000 pages read" },
  { n: 25000, emoji: "🌌", title: "Lost in Worlds",   desc: "25,000 pages read" },
  { n: 50000, emoji: "👑", title: "Reading Royalty",  desc: "50,000 pages read" },
];
const BOOK_MILESTONES = [
  { n: 1,   emoji: "🎉", title: "First Book",     desc: "Finished your 1st book" },
  { n: 5,   emoji: "⭐", title: "High Five",       desc: "Finished 5 books" },
  { n: 10,  emoji: "🏅", title: "Bookworm",        desc: "Finished 10 books" },
  { n: 25,  emoji: "🎖️", title: "Bibliophile",     desc: "Finished 25 books" },
  { n: 50,  emoji: "🏆", title: "Shelf Master",    desc: "Finished 50 books" },
  { n: 100, emoji: "💎", title: "Centurion",       desc: "Finished 100 books" },
];

// Goodreads "Bookshelves" are folders (statuses, "why-did-i-read-this",
// "serie:…"), not genres. Keep them out of tags — normalize() also applies
// this to already-imported data, so old junk tags heal on next load.
// NOTE: must be declared before `state = loadState()` below (normalize uses it).
const JUNK_TAG = /^(to-read|currently-reading|read|did-not-finish|dnf|abandoned|why-did-i(-.*)?)$/i;
const SERIES_TAG = /^series?[-_: ]+(.+)$/i;
function isJunkTag(tag: string) { return JUNK_TAG.test(tag) || SERIES_TAG.test(tag); }

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let state: AppState = loadState();
let fileHandle: FileSystemFileHandle | null = null;
let knownBadges = new Set<string>();
let activeView = "reading";
let storagePersisted = false;
let readingQuery = "", wantQuery = "", libraryQuery = "", ownedQuery = "";
let ownedLocation = "", ownedUnreadOnly = false;
let libraryTag = "", libraryCollection = "", libraryView = "grid";
let libraryFormat = "", libraryRating = 0;
let currentDetailId: string | null = null;
let yearReviewYear = new Date().getFullYear();

const supportsFS = "showSaveFilePicker" in window && "showOpenFilePicker" in window;
// Dev-mode perf logging: run `localStorage.setItem("enkelas-perf","1")` then reload.
const PERF = (() => { try { return localStorage.getItem("enkelas-perf") === "1"; } catch (e: any) { return false; } })();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const $ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = document) => root.querySelector(sel) as T;
const $$ = <T extends HTMLElement = HTMLElement>(sel: string, root: ParentNode = document) => Array.from(root.querySelectorAll(sel)) as T[];

function uid() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return "id-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1e9).toString(36);
}
function todayISODate() { return new Date().toISOString().slice(0, 10); }
function nowLocalInput() {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}
function toLocalInput(iso: string | null | undefined) {
  const d = new Date(iso as any);
  if (isNaN(d.getTime())) return nowLocalInput();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 16);
}
function startOfDay(date: string | number | Date) { const d = new Date(date); d.setHours(0, 0, 0, 0); return d.getTime(); }
function fmtDate(iso: string | null | undefined) {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}
function fmtDateTime(iso: string | null | undefined) {
  if (!iso) return "";
  const d = new Date(iso);
  return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}
function esc(s: unknown) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
    ((({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }) as Record<string, string>)[c]));
}
function num(n: unknown) { return Number(n || 0).toLocaleString(); }
function unitLabel(book: Book) { return book && book.format === "audio" ? "min" : "pages"; }
function unitShort(book: Book) { return book && book.format === "audio" ? "m" : "p"; }
function hashHue(str: string) { let h = 0; for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) >>> 0; return h % 360; }

function parseList(str: string) {
  const seen = new Set<string>(), out: string[] = [];
  String(str || "").split(",").forEach((t) => {
    const v = t.trim(), key = v.toLowerCase();
    if (v && !seen.has(key)) { seen.add(key); out.push(v); }
  });
  return out;
}
const parseTags = parseList;
function uniqueValues(getter: (b: Book) => string[]) {
  const seen = new Map();
  state.books.forEach((b) => (getter(b) || []).forEach((t) => {
    const key = String(t).toLowerCase();
    if (!seen.has(key)) seen.set(key, t);
  }));
  return Array.from(seen.values()).sort((a, b) => a.localeCompare(b));
}
function allTags() { return uniqueValues((b) => b.tags); }
function allCollections() { return uniqueValues((b) => b.collections); }
function allLocations() {
  const seen = new Map();
  state.books.forEach((b) => { const l = (b.location || "").trim(); if (l) { const k = l.toLowerCase(); if (!seen.has(k)) seen.set(k, l); } });
  return Array.from(seen.values()).sort((a, b) => a.localeCompare(b));
}

function bookMatches(book: Book, q: string) {
  if (!q) return true;
  q = q.toLowerCase();
  return book.title.toLowerCase().includes(q)
    || (book.author || "").toLowerCase().includes(q)
    || (book.seriesName || "").toLowerCase().includes(q)
    || (book.isbn || "").toLowerCase().includes(q)
    || (book.description || "").toLowerCase().includes(q)
    || (book.review || "").toLowerCase().includes(q)
    || (book.tags || []).some((t) => t.toLowerCase().includes(q))
    || (book.collections || []).some((t) => t.toLowerCase().includes(q));
}
function fmtIcon(b: Book) { return `<span class="fmt" title="${b.format || "physical"}">${FORMAT_ICON[b.format] || FORMAT_ICON.physical}</span> `; }
function seriesLabel(b: Book) { return b.seriesName ? ` · <span class="series">${esc(b.seriesName)}${b.seriesNumber ? " #" + b.seriesNumber : ""}</span>` : ""; }
function chipsHTML(book: Book, clickable: boolean) {
  const t = (book.tags || []).map((x) =>
    `<span class="tag${clickable ? " clickable" : ""}"${clickable ? ` data-tag="${esc(x)}"` : ""}>${esc(x)}</span>`);
  const c = (book.collections || []).map((x) =>
    `<span class="tag coll${clickable ? " clickable" : ""}"${clickable ? ` data-collection="${esc(x)}"` : ""}>📁 ${esc(x)}</span>`);
  const all = t.concat(c);
  return all.length ? `<div class="tags">${all.join("")}</div>` : "";
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------
function defaultState(): AppState {
  return {
    version: SCHEMA_VERSION,
    updatedAt: new Date().toISOString(),
    settings: { goal: { year: new Date().getFullYear(), target: 12, pagesTarget: 0, dailyPages: 0 } },
    shelfOrder: [],
    books: [],
  };
}
function loadState() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return defaultState();
    return normalize(JSON.parse(raw));
  } catch (e: any) {
    console.warn("Could not load saved data, starting fresh.", e);
    return defaultState();
  }
}
function normalize(data: any): AppState {
  const base = defaultState();
  if (!data || typeof data !== "object") return base;
  if (data.updatedAt) base.updatedAt = data.updatedAt;
  base.settings.goal = Object.assign(base.settings.goal, (data.settings && data.settings.goal) || {});
  base.shelfOrder = Array.isArray(data.shelfOrder) ? data.shelfOrder.map(String) : [];
  const STATUSES = ["want", "reading", "finished", "dnf"];
  base.books = Array.isArray(data.books) ? data.books.map((b: any) => ({
    id: b.id || uid(),
    title: b.title || "Untitled",
    author: b.author || "",
    totalPages: Number(b.totalPages) || 0,
    coverUrl: b.coverUrl || "",
    isbn: b.isbn || "",
    review: b.review || "",
    description: b.description || "",
    tags: Array.isArray(b.tags) ? b.tags.map((t: any) => String(t).trim()).filter((t: any) => t && !isJunkTag(t)) : [],
    collections: Array.isArray(b.collections) ? b.collections.map((t: any) => String(t).trim()).filter(Boolean) : [],
    format: ["physical", "ebook", "audio"].indexOf(b.format) >= 0 ? b.format : "physical",
    seriesName: b.seriesName || "",
    seriesNumber: b.seriesNumber != null && b.seriesNumber !== "" ? Number(b.seriesNumber) : null,
    publishedYear: b.publishedYear ? Number(b.publishedYear) : null,
    quotes: Array.isArray(b.quotes) ? b.quotes.map((q: any) => ({ id: q.id || uid(), text: q.text || "", page: q.page != null ? Number(q.page) : null, at: q.at || null })) : [],
    readCount: Number(b.readCount) || 1,
    finishHistory: Array.isArray(b.finishHistory) ? b.finishHistory.map((f: any) =>
      typeof f === "string" ? { date: f, rating: null } : { date: f.date || null, rating: f.rating ? Number(f.rating) : null }) : [],
    journal: Array.isArray(b.journal) ? b.journal.map((j: any) => ({ id: j.id || uid(), date: j.date || new Date().toISOString(), page: j.page != null && j.page !== "" ? Number(j.page) : null, text: j.text || "" })) : [],
    characters: Array.isArray(b.characters) ? b.characters.map((c: any) => ({ id: c.id || uid(), name: c.name || "", desc: c.desc || "" })) : [],
    vocab: Array.isArray(b.vocab) ? b.vocab.map((v: any) => ({ id: v.id || uid(), word: v.word || "", def: v.def || "", page: v.page != null && v.page !== "" ? Number(v.page) : null })) : [],
    bookmark: b.bookmark && (b.bookmark.note || b.bookmark.page != null) ? { page: b.bookmark.page != null && b.bookmark.page !== "" ? Number(b.bookmark.page) : null, note: String(b.bookmark.note || ""), date: b.bookmark.date || null } : null,
    dnfReason: b.dnfReason || "",
    pickReason: b.pickReason || "",
    expectation: b.expectation ? Number(b.expectation) : null,
    loanDue: b.loanDue || "",
    owned: !!b.owned,
    location: b.location || "",
    coverTriedAt: b.coverTriedAt || null,
    lentTo: b.lentTo || "",
    lentAt: b.lentAt || null,
    status: STATUSES.indexOf(b.status) >= 0 ? b.status : "reading",
    rating: b.rating ? Number(b.rating) : null,
    startedAt: b.startedAt || null,
    finishedAt: b.finishedAt || null,
    addedAt: b.addedAt || new Date().toISOString(),
    logs: Array.isArray(b.logs) ? b.logs.map((l: any) => ({
      id: l.id || uid(),
      date: l.date || new Date().toISOString(),
      pages: Number(l.pages) || 0,
      minutes: Number(l.minutes) || 0,
      mood: l.mood || "",
      note: l.note || "",
    })) : [],
  })) : [];
  // Heal an old import quirk: "read" books without a Goodreads Date Read were
  // stamped finished-on-import-day plus a same-moment log, inflating that
  // year's goals. Signature: finishedAt within a minute of addedAt, plus
  // exactly one "Imported from Goodreads" log at that same moment.
  base.books.forEach((b) => {
    if (b.status !== "finished" || !b.finishedAt || !b.addedAt) return;
    if (Math.abs(new Date(b.finishedAt!).getTime() - new Date(b.addedAt).getTime()) > 60000) return;
    const l = b.logs.length === 1 ? b.logs[0] : null;
    if (!l || l.note !== "Imported from Goodreads" || Math.abs(new Date(l.date).getTime() - new Date(b.finishedAt!).getTime()) > 60000) return;
    b.finishedAt = null;
    b.logs = [];
  });
  return base;
}

async function persist() {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch (e: any) { console.warn(e); }
  if (fileHandle) {
    try {
      const writable = await fileHandle.createWritable();
      await writable.write(JSON.stringify(state, null, 2));
      await writable.close();
    } catch (e: any) {
      console.warn("File write failed:", e);
      toast("⚠️", "Couldn't write file", "Falling back to in-browser storage.");
      fileHandle = null;
      renderStorageStatus();
    }
  }
}
function commit() { state.updatedAt = new Date().toISOString(); render(); persist(); schedulePush(); }

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------
function loadTheme() { try { return localStorage.getItem(THEME_KEY) === "dark" ? "dark" : "light"; } catch (e: any) { return "light"; } }
function applyTheme(theme: string) {
  document.documentElement.setAttribute("data-theme", theme);
  const btn = $<HTMLButtonElement>("#btn-theme");
  if (btn) { btn.textContent = theme === "dark" ? "☀️" : "🌙"; btn.title = theme === "dark" ? "Switch to light mode" : "Switch to dark mode"; }
}
function toggleTheme() {
  const next = loadTheme() === "dark" ? "light" : "dark";
  try { localStorage.setItem(THEME_KEY, next); } catch (e: any) { /* ignore */ }
  applyTheme(next);
}

// ---------------------------------------------------------------------------
// Accounts + cross-device sync (optional; active only when SYNC_API is set)
// ---------------------------------------------------------------------------
let auth: Auth | null = loadAuth();
let pushTimer: ReturnType<typeof setTimeout> | null = null;
let authMode: "login" | "register" = "login";
let lastPushAt = 0, lastPullAt = 0;
// Free Workers KV tier is tight on writes (~1k/day). Coalesce cloud writes so
// the eReader's per-minute session logging + rapid edits don't each cost a write.
const PUSH_MIN_MS = 120000; // ≥2 min between cloud writes
const PULL_MIN_MS = 60000;  // ≥1 min between automatic pulls
function isDirty() { return (state.updatedAt || "") > (loadSyncBase() || ""); }

function syncEnabled() { return !!SYNC_API; }
function loadAuth(): Auth | null { try { return JSON.parse(localStorage.getItem(AUTH_KEY) || "null") || null; } catch (e: any) { return null; } }
function saveAuth(a: Auth | null) { auth = a; try { a ? localStorage.setItem(AUTH_KEY, JSON.stringify(a)) : localStorage.removeItem(AUTH_KEY); } catch (e: any) { /* ignore */ } }
function loadSyncBase() { try { return localStorage.getItem(SYNCBASE_KEY) || null; } catch (e: any) { return null; } }
function saveSyncBase(v: string | null) { try { v ? localStorage.setItem(SYNCBASE_KEY, v) : localStorage.removeItem(SYNCBASE_KEY); } catch (e: any) { /* ignore */ } }

// Sync status surfaced in the header + Settings: idle | syncing | offline | error | needslogin
let syncStatus: SyncStatus = (typeof navigator !== "undefined" && navigator.onLine === false) ? "offline" : "idle";
function setSyncStatus(s: SyncStatus) {
  syncStatus = s;
  renderStorageStatus();
  const sm = $("#settings-modal");
  if (sm && !sm.hidden) renderSettings();
}
function loadLastSync() { try { return localStorage.getItem(LASTSYNC_KEY) || null; } catch (e: any) { return null; } }
function markSynced() { try { localStorage.setItem(LASTSYNC_KEY, new Date().toISOString()); } catch (e: any) { /* ignore */ } }
function loadLastExport() { try { return localStorage.getItem(LASTEXPORT_KEY) || null; } catch (e: any) { return null; } }
function markExported() {
  try { localStorage.setItem(LASTEXPORT_KEY, new Date().toISOString()); } catch (e: any) { /* ignore */ }
  if (!$("#settings-modal").hidden) renderSettings();
}
// Every sync conflict (two devices disagreeing) is remembered, so "wait, where
// did that change go?" always has an answer. Capped, newest first.
function loadConflictLog() { try { return JSON.parse(localStorage.getItem(CONFLICTLOG_KEY) || "null") || []; } catch (e: any) { return []; } }
function logConflict(where: string, choice: string) {
  try {
    const log = loadConflictLog();
    log.unshift({ at: new Date().toISOString(), where, choice, books: state.books.length });
    localStorage.setItem(CONFLICTLOG_KEY, JSON.stringify(log.slice(0, 20)));
  } catch (e: any) { /* ignore */ }
}
function relTimeShort(iso: string | null | undefined) {
  if (!iso) return "";
  const diff = Date.now() - new Date(iso).getTime();
  if (isNaN(diff) || diff < 0) return "";
  if (diff < 45000) return "just now";
  const m = Math.round(diff / 60000); if (m < 60) return m + "m ago";
  const h = Math.round(diff / 3600000); if (h < 24) return h + "h ago";
  const d = Math.round(diff / 86400000); if (d < 7) return d + "d ago";
  return fmtDate(iso);
}
function relTimeLong(iso: string | null | undefined) {
  if (!iso) return "";
  const diff = Date.now() - new Date(iso).getTime();
  if (isNaN(diff) || diff < 0) return "";
  if (diff < 45000) return "just now";
  const m = Math.round(diff / 60000); if (m < 60) return m + " minute" + (m === 1 ? "" : "s") + " ago";
  const h = Math.round(diff / 3600000); if (h < 24) return h + " hour" + (h === 1 ? "" : "s") + " ago";
  const d = Math.round(diff / 86400000); if (d < 7) return d + " day" + (d === 1 ? "" : "s") + " ago";
  return "on " + fmtDate(iso);
}

async function apiFetch(path: string, opts?: RequestInit): Promise<{ res: Response; data: any }> {
  opts = opts || {};
  const headers = Object.assign({ "Content-Type": "application/json" } as Record<string, string>, (opts && opts.headers) || {});
  if (auth && auth.token) headers["Authorization"] = "Bearer " + auth.token;
  const res = await fetch(SYNC_API.replace(/\/$/, "") + path, Object.assign({}, opts, { headers }));
  let data = null; try { data = await res.json(); } catch (e: any) { /* ignore */ }
  return { res, data };
}

async function doAuth(mode: string, creds: { email: string; fullName?: string; password: string }) {
  const path = mode === "register" ? "/api/register" : "/api/login";
  const body = mode === "register"
    ? { email: creds.email, fullName: creds.fullName, password: creds.password }
    : { email: creds.email, password: creds.password };
  const { res, data } = await apiFetch(path, { method: "POST", body: JSON.stringify(body) });
  if (!res.ok) throw new Error((data && data.error) || "Something went wrong. Please try again.");
  saveAuth({ token: data.token, user: data.user });
  saveSyncBase(null);
  return data.user;
}

// Replace local state with the account's copy.
function adoptServer(blob: any, updatedAt?: string | null) {
  state = normalize(blob);
  if (updatedAt) state.updatedAt = updatedAt;
  saveSyncBase(updatedAt || null);
  knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
  persist();
  render();
}

// After sign-in, reconcile this device's data with the account.
async function afterSignIn(mode: string) {
  try {
    const { data } = await apiFetch("/api/data", { method: "GET" });
    const serverBlob = data && data.blob;
    const localHasBooks = state.books.length > 0;
    if (mode === "register") {
      await pushData(true);
    } else if (serverBlob && !localHasBooks) {
      adoptServer(serverBlob, data.updatedAt);
    } else if (serverBlob && localHasBooks) {
      const useServer = confirm("This account already has a saved bookshelf.\n\nOK = load your account's books here (replaces what's on this device).\nCancel = keep this device's books and upload them to the account.");
      logConflict("sign-in", useServer ? "kept the account's copy" : "kept this device's copy");
      if (useServer) adoptServer(serverBlob, data.updatedAt); else await pushData(true);
    } else {
      await pushData(true);
    }
  } catch (e: any) { /* offline; will sync on next change/load */ }
  renderAccount();
  renderStorageStatus();
  maybePendingClubJoin(); // an invite link may have been waiting on this sign-in
}

function schedulePush() {
  if (!syncEnabled() || !auth) return;
  clearTimeout(pushTimer!);
  const since = Date.now() - lastPushAt;
  pushTimer = setTimeout(() => pushData(false), since >= PUSH_MIN_MS ? 1200 : (PUSH_MIN_MS - since));
}
// Resolves true when the account now holds this device's latest data
// (or a consciously chosen version) — logout uses this before wiping.
async function pushData(force: boolean) {
  if (!syncEnabled() || !auth) return false;
  setSyncStatus("syncing");
  lastPushAt = Date.now();
  const body: { blob: AppState; updatedAt: string; force?: boolean; baseUpdatedAt?: string | null } = { blob: state, updatedAt: state.updatedAt };
  if (force) body.force = true; else body.baseUpdatedAt = loadSyncBase();
  try {
    const { res, data } = await apiFetch("/api/data", { method: "PUT", body: JSON.stringify(body) });
    if (res.status === 401) { handleAuthExpired(); return false; }
    if (res.status === 409 && data && data.blob) {
      const useServer = confirm("Your bookshelf was changed on another device.\n\nOK = use that newer version here.\nCancel = overwrite it with this device's version.");
      logConflict("sync push", useServer ? "took the other device's newer copy" : "overwrote with this device's copy");
      if (useServer) { adoptServer(data.blob, data.updatedAt); markSynced(); setSyncStatus("idle"); return true; }
      return pushData(true);
    }
    if (res.ok && data) { saveSyncBase(data.updatedAt); markSynced(); setSyncStatus("idle"); return true; }
    setSyncStatus("error");
    return false;
  } catch (e: any) { setSyncStatus(navigator.onLine === false ? "offline" : "error"); return false; /* saved locally; retries on next change */ }
}
async function pullData() {
  if (!syncEnabled() || !auth) return;
  setSyncStatus("syncing");
  lastPullAt = Date.now();
  try {
    const { res, data } = await apiFetch("/api/data", { method: "GET" });
    if (res.status === 401) { handleAuthExpired(); return; }
    if (!res.ok || !data) { setSyncStatus("error"); return; }
    if (data.blob) {
      const serverU = data.updatedAt || "";
      if (serverU > (state.updatedAt || "")) adoptServer(data.blob, serverU);
      else if ((state.updatedAt || "") > serverU) { await pushData(false); return; } // pushData sets status + markSynced
      else saveSyncBase(serverU);
    } else if (state.books.length) {
      await pushData(true); return;
    }
    markSynced();
    setSyncStatus("idle");
  } catch (e: any) { setSyncStatus(navigator.onLine === false ? "offline" : "error"); }
}

// Autosync. Every commit already pushes (debounced 1.2s). On top of that:
// flush the pending push the moment the app is backgrounded (iOS may kill a
// PWA before a debounce fires), pull fresh data when it returns to the
// foreground or comes back online, and refresh every few minutes while open.
function setupAutoSync() {
  const maybePull = () => { if (syncEnabled() && auth && Date.now() - lastPullAt >= PULL_MIN_MS) pullData(); };
  document.addEventListener("visibilitychange", () => {
    if (!syncEnabled() || !auth) return;
    // Only flush on background when there's actually something new — avoids a
    // wasted KV write every time the app is switched away with nothing changed.
    if (document.hidden) { clearTimeout(pushTimer!); if (isDirty()) pushData(false); }
    else maybePull();
  });
  window.addEventListener("online", () => { if (syncEnabled() && auth) pullData(); });
  window.addEventListener("offline", () => { if (syncEnabled() && auth) setSyncStatus("offline"); });
  setInterval(() => { if (!document.hidden) maybePull(); }, 15 * 60 * 1000);
}

function handleAuthExpired() { saveAuth(null); saveSyncBase(null); renderAccount(); setSyncStatus("needslogin"); toast("🔑", "Please sign in again", "Your session expired."); }
// Signing out is a privacy boundary: back the data up to the account,
// then leave this device as a blank shelf (nothing of the previous user).
async function logout() {
  closeAccountMenu();
  if (!confirm("Sign out on this device?\n\nYour books stay safely in your account, but they'll be removed from this device until you sign in again.")) return;
  clearTimeout(pushTimer!);
  const backedUp = await pushData(false);
  if (!backedUp && !confirm("Couldn't back up your latest changes — are you offline?\n\nSign out anyway? Changes made since the last sync will be lost.")) return;
  saveAuth(null);
  saveSyncBase(null);
  try { localStorage.removeItem(STORAGE_KEY); } catch (e: any) { /* ignore */ }
  state = loadState(); // fresh, empty shelf
  fileHandle = null;
  knownBadges = new Set();
  currentDetailId = null;
  coverBackfillRan = false;
  leaveBookPage();
  switchView("reading");
  render();
  renderAccount();
  renderStorageStatus();
  toast("👋", "Signed out", "This device is a blank shelf now — sign in to bring your books back.");
}

function openAuthModal(mode: "login" | "register") {
  setAuthMode(mode || "login");
  $<HTMLInputElement>("#auth-name").value = ""; $<HTMLInputElement>("#auth-email").value = ""; $<HTMLInputElement>("#auth-password").value = ""; $("#auth-error").textContent = "";
  showModal("auth-modal");
  setTimeout(() => $<HTMLInputElement>("#auth-email").focus(), 50);
}
function setAuthMode(mode: "login" | "register") {
  authMode = mode;
  $<HTMLButtonElement>("#tab-login").classList.toggle("active", mode === "login");
  $<HTMLButtonElement>("#tab-register").classList.toggle("active", mode === "register");
  $("#auth-name-row").hidden = mode !== "register";
  $("#auth-title").textContent = mode === "register" ? "Create your account" : "Log in";
  $<HTMLButtonElement>("#auth-submit").textContent = mode === "register" ? "Create account" : "Log in";
  $("#auth-error").textContent = "";
}
async function onAuthSubmit(e: SubmitEvent) {
  e.preventDefault();
  const creds = { email: $<HTMLInputElement>("#auth-email").value.trim(), password: $<HTMLInputElement>("#auth-password").value, fullName: $<HTMLInputElement>("#auth-name").value.trim() };
  $("#auth-error").textContent = "";
  const submit = $<HTMLButtonElement>("#auth-submit"); submit.disabled = true;
  try {
    const user = await doAuth(authMode, creds);
    closeModals();
    await afterSignIn(authMode);
    toast("✅", authMode === "register" ? "Account created" : "Signed in", user.fullName);
  } catch (err: any) {
    $("#auth-error").textContent = err.message || "Something went wrong.";
  } finally { submit.disabled = false; }
}

function closeAccountMenu() { const m = $("#account-menu"); if (m) m.hidden = true; }
function renderTitle() {
  const first = auth && auth.user ? (auth.user.fullName || "").trim().split(/\s+/)[0] : "";
  const title = first ? first + "'s Bookshelf" : "Enkela's Bookshelf";
  const h1 = $("#app-title");
  if (h1) h1.textContent = title;
  document.title = title;
}
function renderAccount() {
  renderTitle();
  const wrap = $("#account-wrap");
  if (!wrap) return;
  if (!syncEnabled()) { wrap.style.display = "none"; return; }
  wrap.style.display = "";
  const btn = $<HTMLButtonElement>("#btn-account");
  if (auth && auth.user) {
    const first = (auth.user.fullName || "").split(" ")[0] || "Account";
    btn.textContent = "☁️ " + first;
    btn.title = "Signed in as " + auth.user.fullName + " (" + auth.user.email + ")";
    $("#am-name").textContent = auth.user.fullName + " · " + auth.user.email;
  } else {
    btn.textContent = "👤 Sign in";
    btn.title = "Sign in to sync your books across devices";
  }
  closeAccountMenu();
}

// ---------------------------------------------------------------------------
// Offline + persistent storage
// ---------------------------------------------------------------------------
async function setupOfflineAndPersistence() {
  if ("serviceWorker" in navigator && location.protocol.indexOf("http") === 0) {
    try { await navigator.serviceWorker.register("sw.js"); } catch (e: any) { /* ignore */ }
  }
  if (navigator.storage && navigator.storage.persist) {
    try {
      storagePersisted = await navigator.storage.persisted();
      if (!storagePersisted) storagePersisted = await navigator.storage.persist();
    } catch (e: any) { /* ignore */ }
  }
  renderStorageStatus();
}

// ---------------------------------------------------------------------------
// Derived values
// ---------------------------------------------------------------------------
function pagesRead(book: Book) { return book.logs.reduce((s, l) => s + (Number(l.pages) || 0), 0); }
// Cumulative pages read *before* a given session — i.e. the page you were on
// when that session began. For a brand-new log (log == null) that's everything
// read so far. For an edit, it's the sum of every earlier session by date.
function pagesBefore(book: Book, log?: ReadingLog | null) {
  if (!log) return pagesRead(book);
  const sorted = [...book.logs].sort((a, b) => new Date(a.date).getTime() - new Date(b.date).getTime());
  let sum = 0;
  for (const l of sorted) { if (l.id === log.id) break; sum += Number(l.pages) || 0; }
  return sum;
}
function totalPagesRead() { return state.books.reduce((s, b) => s + pagesRead(b), 0); }
function booksFinished() { return state.books.filter((b) => b.status === "finished"); }
function libraryBooks() { return state.books.filter((b) => b.status === "finished" || b.status === "dnf"); }
function booksFinishedInYear(year: number) {
  return booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt!).getFullYear() === year).length;
}
function pagesReadInYear(year: number) {
  let s = 0;
  state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d.getTime()) && d.getFullYear() === year) s += Number(l.pages) || 0; }));
  return s;
}
function pagesOnDay(t: number) {
  let s = 0;
  state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d.getTime()) && startOfDay(d) === t) s += Number(l.pages) || 0; }));
  return s;
}
function perDayMap(): Record<number, number> {
  const m: Record<number, number> = {};
  state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d.getTime())) { const k = startOfDay(d); m[k] = (m[k] || 0) + (Number(l.pages) || 0); } }));
  return m;
}
function readingDaySet() {
  const days = new Set<number>();
  state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d.getTime())) days.add(startOfDay(d)); }));
  return days;
}
function readingStreak() {
  const days = readingDaySet();
  if (days.size === 0) return { current: 0, longest: 0 };
  const sorted = Array.from(days).sort((a, b) => a - b);
  let longest = 1, run = 1;
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i] - sorted[i - 1] === DAY) { run++; longest = Math.max(longest, run); }
    else run = 1;
  }
  const today = startOfDay(new Date());
  let current = 0;
  if (days.has(today) || days.has(today - DAY)) {
    let cursor = days.has(today) ? today : today - DAY;
    while (days.has(cursor)) { current++; cursor -= DAY; }
  }
  return { current, longest };
}
// Estimated finish date for a book being read, based on recent pace.
function estimateFinish(book: Book) {
  if (book.status !== "reading" || !book.totalPages) return null;
  const read = pagesRead(book);
  const remaining = book.totalPages - read;
  if (remaining <= 0) return null;
  const days = Array.from(new Set(book.logs.map((l) => startOfDay(new Date(l.date))))).filter((n) => !isNaN(n)).sort((a, b) => a - b);
  if (days.length < 2) return null;
  const spanDays = Math.max(1, Math.round((days[days.length - 1] - days[0]) / DAY) + 1);
  const pace = read / spanDays;
  if (pace <= 0) return null;
  const daysLeft = Math.ceil(remaining / pace);
  if (daysLeft > 3650) return null;
  const d = new Date(); d.setDate(d.getDate() + daysLeft);
  return { date: d, daysLeft };
}

function computeBadges() {
  const tp = totalPagesRead();
  const bf = booksFinished().length;
  const goal = state.settings.goal;
  const goalDone = goal && goal.target > 0 && booksFinishedInYear(goal.year) >= goal.target;
  const list = [];
  PAGE_MILESTONES.forEach((m) => list.push({ id: "pages-" + m.n, group: "pages", ...m, value: tp, target: m.n, unlocked: tp >= m.n }));
  BOOK_MILESTONES.forEach((m) => list.push({ id: "books-" + m.n, group: "books", ...m, value: bf, target: m.n, unlocked: bf >= m.n }));
  list.push({ id: "goal-" + goal.year, group: "special", emoji: "🎯", title: "Goal Crusher", desc: "Hit your " + goal.year + " reading goal", value: booksFinishedInYear(goal.year), target: goal.target, unlocked: !!goalDone });
  const firstRated = state.books.some((b) => b.rating);
  list.push({ id: "first-rating", group: "special", emoji: "🌟", title: "Critic", desc: "Rated your first book", value: firstRated ? 1 : 0, target: 1, unlocked: firstRated });
  const streak = readingStreak();
  [
    { d: 3, emoji: "🔥", title: "On a Roll", desc: "3-day reading streak" },
    { d: 7, emoji: "📅", title: "Weekly Habit", desc: "7-day reading streak" },
    { d: 30, emoji: "🚀", title: "Unstoppable", desc: "30-day reading streak" },
  ].forEach((s) => list.push({ id: "streak-" + s.d, group: "special", emoji: s.emoji, title: s.title, desc: s.desc, value: streak.longest, target: s.d, unlocked: streak.longest >= s.d }));
  return list;
}
function checkNewBadges() {
  const badges = computeBadges();
  if (knownBadges.size === 0) { badges.forEach((b) => { if (b.unlocked) knownBadges.add(b.id); }); return; }
  badges.forEach((b) => {
    if (b.unlocked && !knownBadges.has(b.id)) {
      knownBadges.add(b.id);
      toast(b.emoji, "Achievement unlocked!", b.title + " — " + b.desc, true);
      if (b.id.indexOf("goal-") === 0) confetti();
    }
  });
}

// Reading challenges (computed, like badges).
function computeChallenges() {
  const year = state.settings.goal.year || new Date().getFullYear();
  const finishedYr = booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt!).getFullYear() === year);
  const genresYr = new Set(); finishedYr.forEach((b) => (b.tags || []).forEach((t) => genresYr.add(t.toLowerCase())));
  const chunky = state.books.some((b) => b.status === "finished" && b.totalPages >= 500);
  const decades = new Set(); state.books.filter((b) => b.status === "finished" && b.publishedYear).forEach((b) => decades.add(Math.floor(b.publishedYear! / 10)));
  const reviews = state.books.filter((b) => b.status === "finished" && b.review && b.review.trim()).length;
  const monthsRead = new Set(); finishedYr.forEach((b) => monthsRead.add(new Date(b.finishedAt!).getMonth()));
  const fiveStar = state.books.some((b) => b.status === "finished" && b.rating === 5);
  const speed = state.books.some((b) => b.status === "finished" && b.startedAt && b.finishedAt && (() => { const d = (new Date(b.finishedAt!).getTime() - new Date(b.startedAt).getTime()) / DAY; return d >= 0 && d <= 7; })());
  const monthTarget = new Date().getFullYear() === year ? new Date().getMonth() + 1 : 12;
  const list = [
    { id: "genres5", emoji: "🌈", title: "Well-Rounded", desc: "Read 5 genres in " + year, value: genresYr.size, target: 5 },
    { id: "chunky", emoji: "🧱", title: "Chunky Read", desc: "Finish a 500+ page book", value: chunky ? 1 : 0, target: 1 },
    { id: "decades3", emoji: "🕰️", title: "Time Traveler", desc: "Books from 3 decades", value: decades.size, target: 3 },
    { id: "reviews5", emoji: "✍️", title: "The Reviewer", desc: "Write 5 reviews", value: reviews, target: 5 },
    { id: "months", emoji: "📆", title: "Every Month", desc: "A book each month of " + year, value: monthsRead.size, target: monthTarget },
    { id: "fivestar", emoji: "💯", title: "Instant Classic", desc: "Give a 5-star rating", value: fiveStar ? 1 : 0, target: 1 },
    { id: "speed", emoji: "⚡", title: "Speed Reader", desc: "Finish a book in ≤7 days", value: speed ? 1 : 0, target: 1 },
  ];
  return list.map((c) => ({ ...c, unlocked: c.value >= c.target }));
}

// ---------------------------------------------------------------------------
// Confetti 🎉
// ---------------------------------------------------------------------------
function confetti() {
  if (typeof window.matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const colors = ["#9c5b3a", "#c98a4b", "#4f7d56", "#c0392b", "#e0a960", "#6a8caf"];
  for (let i = 0; i < 90; i++) {
    const p = document.createElement("div");
    p.className = "confetti-bit";
    const size = 6 + Math.random() * 8;
    p.style.left = (Math.random() * 100) + "vw";
    p.style.background = colors[i % colors.length];
    p.style.width = size + "px";
    p.style.height = (size * 0.5) + "px";
    p.style.animationDelay = (Math.random() * 0.3) + "s";
    p.style.animationDuration = (2.4 + Math.random() * 1.6) + "s";
    document.body.appendChild(p);
    setTimeout(() => p.remove(), 4200);
  }
}

// ---------------------------------------------------------------------------
// Open Library
// ---------------------------------------------------------------------------
function coverFromId(id: number | string, size?: string) { return `https://covers.openlibrary.org/b/id/${id}-${size || "L"}.jpg`; }
// default=false makes unknown ISBNs 404 (so <img onerror> shows the title tile)
// instead of silently serving a blank 1×1 GIF.
function coverFromIsbn(isbn: string, size?: string) { return `https://covers.openlibrary.org/b/isbn/${encodeURIComponent(isbn)}-${size || "L"}.jpg?default=false`; }
// Does an Open Library doc's author agree with what the user typed? Used to
// stop a same-title book by a DIFFERENT author winning the lookup. Matches on
// whole-string containment or a shared surname (last name token, ≥3 chars).
function normName(s: unknown) { return String(s || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim(); }
function lastNameTok(s: unknown) { const p = normName(s).split(" ").filter(Boolean); return p.length ? p[p.length - 1] : ""; }
function authorMatches(query: string, names?: string[]) {
  const q = normName(query);
  if (!q) return true; // no author given → nothing to disagree with
  const qTok = new Set(q.split(" ").filter((w) => w.length >= 3));
  const qLast = lastNameTok(query);
  return (names || []).some((n) => {
    const a = normName(n);
    if (!a) return false;
    if (a === q || a.includes(q) || q.includes(a)) return true;
    // Surname agreement, handling "First Last" vs "Last, First" ordering.
    const aTok = a.split(" ").filter((w) => w.length >= 3);
    if (qLast.length >= 3 && aTok.indexOf(qLast) >= 0) return true;
    const aLast = lastNameTok(n);
    return aLast.length >= 3 && qTok.has(aLast);
  });
}
window.__authorMatches = authorMatches; // test hook (no network needed)
async function searchOpenLibrary(title: string, author: string, isbn: string) {
  const params = new URLSearchParams();
  if (isbn) params.set("isbn", isbn.replace(/[^0-9Xx]/g, ""));
  if (title) params.set("title", title);
  if (author) params.set("author", author);
  params.set("limit", "10");
  params.set("fields", "key,title,author_name,cover_i,number_of_pages_median,first_publish_year,isbn,subject");
  const res = await fetch("https://openlibrary.org/search.json?" + params.toString());
  if (!res.ok) throw new Error("Search failed");
  const data = await res.json();
  let docs: OLDoc[] = (data.docs || []).filter((d: OLDoc) => d.cover_i || (d.isbn && d.isbn.length));
  // Float author matches to the top so downstream callers pick the right one.
  if (author) docs = docs.slice().sort((a, b) => (authorMatches(author, b.author_name) ? 1 : 0) - (authorMatches(author, a.author_name) ? 1 : 0));
  return docs;
}

// Cover backfill — Goodreads exports often lack ISBNs, and Open Library's
// ISBN endpoint doesn't know every edition, so imported libraries end up
// with a chunk of coverless books. Quietly re-find those in the background:
// OL title/author search first (best coverage), then the ISBN image
// (validated), then Google Books (unauthenticated → rate-limited → last).
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
function imgOk(url: string): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const im = new Image();
    im.onload = () => resolve(im.naturalWidth > 10); // OL's "missing" image is 1×1
    im.onerror = () => resolve(false);
    im.src = url;
  });
}
// Goodreads titles carry "(Series, #1)" / "[Series]" suffixes and long
// ": subtitle" tails that break OL search — search progressively barer forms.
function bareTitle(b: Book) { return (b.title || "").replace(/\s*\[.*?\]\s*$/, "").replace(/\s*\(.*?\)\s*$/, "").trim(); }
function coreTitle(b: Book) { const t = bareTitle(b), i = t.indexOf(":"); return i > 0 ? t.slice(0, i).trim() : ""; }
async function findCoverFor(book: Book) {
  for (const t of new Set([bareTitle(book), coreTitle(book)].filter(Boolean))) {
    try {
      const docs = await searchOpenLibrary(t, book.author, "");
      const hit = docs.find((d) => d.cover_i);
      if (hit) return coverFromId(hit.cover_i!);
    } catch (e: any) { /* offline or OL hiccup — try the next form/source */ }
  }
  if (book.isbn && (await imgOk(coverFromIsbn(book.isbn)))) return coverFromIsbn(book.isbn);
  // Fuzzy OL search: translated books are indexed under their original-
  // language title (e.g. "Emerald Green" lives as "Smaragdgrün"), which
  // strict title= search misses. Guard with an author match so a fuzzy hit
  // can't attach a random wrong cover.
  try {
    const norm = (s: unknown) => String(s || "").toLowerCase().replace(/[^a-z0-9]/g, "");
    const params = new URLSearchParams({ q: (coreTitle(book) || bareTitle(book)) + " " + (book.author || ""), limit: "5", fields: "cover_i,author_name" });
    const res = await fetch("https://openlibrary.org/search.json?" + params.toString());
    if (res.ok) {
      const data = await res.json();
      const a = norm(book.author);
      const hit = (data.docs || []).find((d: OLDoc) => d.cover_i && (!a || (d.author_name || []).some((x) => norm(x).includes(a) || a.includes(norm(x)))));
      if (hit) return coverFromId(hit.cover_i!);
    }
  } catch (e: any) { /* fall through */ }
  try {
    const q = book.isbn ? "isbn:" + book.isbn.replace(/[^0-9Xx]/g, "")
      : "intitle:" + bareTitle(book) + (book.author ? " inauthor:" + book.author : "");
    const res = await fetch("https://www.googleapis.com/books/v1/volumes?q=" + encodeURIComponent(q) + "&maxResults=3&fields=items(volumeInfo(imageLinks))");
    if (res.ok) {
      const data = await res.json();
      const link = (data.items || []).map((it: any) => (it.volumeInfo || {}).imageLinks || {}).map((l: any) => l.thumbnail || l.smallThumbnail).find(Boolean);
      if (link) return link.replace(/^http:/, "https:").replace("&edge=curl", "");
    }
  } catch (e: any) { /* rate-limited or offline */ }
  return "";
}
let coverBackfillBusy = false, coverBackfillRan = false;
async function backfillCovers(force?: boolean) {
  if (coverBackfillBusy || (coverBackfillRan && !force) || navigator.onLine === false) return;
  coverBackfillBusy = true;
  coverBackfillRan = true;
  try {
    const WEEK = 7 * 24 * 3600 * 1000;
    const isbnCover = /covers\.openlibrary\.org\/b\/isbn\//;
    const todo = [];
    for (const b of state.books) {
      if (!force && b.coverTriedAt && Date.now() - new Date(b.coverTriedAt).getTime() < WEEK) continue;
      if (!b.coverUrl) todo.push(b);
      else if (isbnCover.test(b.coverUrl) && !(await imgOk(b.coverUrl))) todo.push(b);
    }
    let found = 0;
    for (const b of todo) {
      if (!state.books.includes(b)) continue; // a sync pull may have replaced the list
      const url = await findCoverFor(b);
      if (url) { b.coverUrl = url; found++; }
      else {
        // A confirmed-blank ISBN cover would keep rendering as an empty
        // image; drop it so the title tile shows instead.
        if (isbnCover.test(b.coverUrl || "")) b.coverUrl = "";
        b.coverTriedAt = new Date().toISOString();
      }
      await sleep(350);
    }
    if (todo.length) commit();
    if (found) toast("🖼", "Covers found", found + " missing cover" + (found === 1 ? "" : "s") + " filled in");
  } finally { coverBackfillBusy = false; }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------
function render() {
  const perfT0 = PERF ? performance.now() : 0;
  renderStats();
  renderReading();
  renderWant();
  renderLibrary();
  renderOwned();
  renderJourney();
  renderAchievements();
  renderGoal();
  renderStatsView();
  renderInsights();
  renderStorageStatus();
  const sm = $("#settings-modal");
  if (sm && !sm.hidden) renderSettings(); // keep Settings live if it's open
  refreshDetail(); // keep the open book page in sync with data changes
  if (PERF) console.log("[perf] render " + Math.round(performance.now() - perfT0) + "ms · " + state.books.length + " books");
}

function renderStats() {
  const streak = readingStreak();
  $("#stats-strip").innerHTML = `
      <div class="stat"><div class="num">${num(booksFinished().length)}</div><div class="lbl">Books read</div></div>
      <div class="stat"><div class="num">${num(totalPagesRead())}</div><div class="lbl">Pages read</div></div>
      <div class="stat"><div class="num">${num(state.books.filter((b) => b.status === "reading").length)}</div><div class="lbl">Reading now</div></div>
      <div class="stat"><div class="num">${num(streak.current)}</div><div class="lbl">Day streak 🔥</div></div>
      <div class="stat"><div class="num">${num(state.books.filter((b) => b.owned).length)}</div><div class="lbl">Books owned 🏠</div></div>
      <div class="stat"><div class="num">${num(computeBadges().filter((b) => b.unlocked).length)}</div><div class="lbl">Badges earned</div></div>`;
}

// --- Insights: reading rhythm (#9), taste profile (#6), gentle coach (#3) ---
function sessionInsights() {
  const logs: { date: string; pages: number; minutes: number; format: string }[] = [];
  state.books.forEach((b) => (b.logs || []).forEach((l) => { if (l.date) logs.push({ date: l.date, pages: l.pages || 0, minutes: l.minutes || 0, format: b.format }); }));
  if (!logs.length) return null;
  const buckets: Record<string, number> = { Morning: 0, Afternoon: 0, Evening: 0, Night: 0 };
  const bucketOf = (h: number): "Morning" | "Afternoon" | "Evening" | "Night" => (h < 5 ? "Night" : h < 12 ? "Morning" : h < 17 ? "Afternoon" : h < 22 ? "Evening" : "Night");
  const dow = [0, 0, 0, 0, 0, 0, 0];
  let totalMin = 0, sessWithMin = 0, audioPages = 0, totalPages = 0;
  logs.forEach((l) => {
    const d = new Date(l.date);
    const weight = l.pages || 1;
    if (!isNaN(d.getTime())) { buckets[bucketOf(d.getHours())] += weight; dow[d.getDay()] += weight; }
    if (l.minutes > 0) { totalMin += l.minutes; sessWithMin++; }
    totalPages += l.pages || 0;
    if (l.format === "audio") audioPages += l.pages || 0;
  });
  const DOW = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const bucketSum = Object.keys(buckets).reduce((a, k) => a + buckets[k], 0);
  const dowSum = dow.reduce((a, b) => a + b, 0);
  return {
    bestTime: bucketSum ? Object.keys(buckets).sort((a, b) => buckets[b] - buckets[a])[0] : "",
    bestDay: dowSum ? DOW[dow.indexOf(Math.max.apply(null, dow))] : "",
    avgMin: sessWithMin ? Math.round(totalMin / sessWithMin) : 0,
    audioPct: totalPages ? Math.round((audioPages / totalPages) * 100) : 0,
    totalMin: totalMin,
  };
}
function tasteProfile() {
  const finished = state.books.filter((b) => b.status === "finished");
  if (finished.length < 2) return null;
  const genre: Record<string, number> = {};
  finished.forEach((b) => (b.tags || []).forEach((t) => { genre[t] = (genre[t] || 0) + 1; }));
  const topGenres = Object.keys(genre).sort((a, b) => genre[b] - genre[a]).slice(0, 3);
  const byAuthor: Record<string, number[]> = {};
  finished.forEach((b) => { if (b.rating && b.author) (byAuthor[b.author] = byAuthor[b.author] || []).push(b.rating); });
  let bestAuthor = null, bestAvg = 0;
  Object.keys(byAuthor).forEach((a) => { if (byAuthor[a].length >= 2) { const avg = byAuthor[a].reduce((s, r) => s + r, 0) / byAuthor[a].length; if (avg > bestAvg) { bestAvg = avg; bestAuthor = a; } } });
  const withPages = finished.filter((b) => b.totalPages);
  const longest = withPages.slice().sort((a, b) => b.totalPages - a.totalPages)[0];
  const avgLen = withPages.length ? Math.round(withPages.reduce((s, b) => s + b.totalPages, 0) / withPages.length) : 0;
  return { topGenres, bestAuthor, bestAvg, longest, avgLen };
}
function coachNudges() {
  const nudges = [];
  const unreadOwned = state.books.filter((b) => b.owned && b.status !== "finished" && b.status !== "dnf" && pagesRead(b) === 0);
  if (unreadOwned.length >= 3) nudges.push(`You already own <strong>${unreadOwned.length}</strong> unread books — a ready-made shelf, no shopping needed. 📚`);
  const tbr = state.books.filter((b) => b.status === "want").slice().sort((a, b) => new Date(a.addedAt || 0).getTime() - new Date(b.addedAt || 0).getTime())[0];
  if (tbr) { const days = Math.floor((Date.now() - new Date(tbr.addedAt).getTime()) / DAY); if (days >= 120) nudges.push(`“${esc(tbr.title)}” has waited <strong>${days} days</strong> on your list. Read it soon, or let it go — both are fine. 🕊️`); }
  const dnf = state.books.filter((b) => b.status === "dnf");
  if (dnf.length >= 2) nudges.push(`You set aside <strong>${dnf.length}</strong> books this year — that's time saved for books you'll love, not something to feel bad about. ✨`);
  return nudges;
}
function insightCard(emoji: string, title: string, lines: string[]) {
  const items = lines.filter(Boolean).map((l) => `<p>${l}</p>`).join("");
  if (!items) return "";
  return `<div class="insight-card"><div class="insight-emoji">${emoji}</div><div><h4>${esc(title)}</h4>${items}</div></div>`;
}
// ---- Shelf intelligence: what's sitting on the shelf, and what's missing --
function unreadOwnedBooks() {
  return state.books.filter((b) => b.owned && b.status !== "finished" && b.status !== "dnf" && pagesRead(b) === 0);
}
function shelfInsightLines() {
  const lines = [];
  const unread = unreadOwnedBooks();
  if (unread.length) {
    const oldest = unread.slice().sort((a, b) => new Date(a.addedAt || 0).getTime() - new Date(b.addedAt || 0).getTime())[0];
    const months = Math.floor((Date.now() - new Date(oldest.addedAt || Date.now()).getTime()) / (30.44 * DAY));
    lines.push(`<strong>${unread.length}</strong> owned book${unread.length === 1 ? "" : "s"} still unread${months >= 3 ? ` — <strong>${esc(oldest.title)}</strong> has waited longest (${months} months)` : ""}`);
  }
  // Series started but not finished — with the concrete next step.
  const bySeries: Record<string, Book[]> = {};
  state.books.forEach((b) => { if (b.seriesName) { const k = b.seriesName.toLowerCase(); (bySeries[k] = bySeries[k] || []).push(b); } });
  let openSeries = 0, ex: Book | null = null;
  Object.values(bySeries).forEach((list) => {
    if (!list.some((b) => b.status === "finished")) return;
    const next = list.filter((b) => b.status !== "finished" && b.status !== "dnf")
      .sort((a, b) => (a.seriesNumber == null ? 999 : a.seriesNumber) - (b.seriesNumber == null ? 999 : b.seriesNumber))[0];
    if (next) { openSeries++; if (!ex) ex = next; }
  });
  if (openSeries) lines.push(`<strong>${openSeries}</strong> series waiting to be continued${ex ? ` — next up: <strong>${esc((ex as Book).title)}</strong>` : ""}`);
  const dupes = duplicateGroups();
  if (dupes.length) lines.push(`<strong>${dupes.length}</strong> possible duplicate edition${dupes.length === 1 ? "" : "s"} — Shelf Doctor can merge them`);
  // Genre gap: a favourite genre with nothing waiting on the TBR/shelf.
  const finished = state.books.filter((b) => b.status === "finished");
  if (finished.length >= 3) {
    const tally: Record<string, number> = {};
    finished.forEach((b) => (b.tags || []).forEach((t) => { tally[t] = (tally[t] || 0) + 1; }));
    const waiting = new Set();
    state.books.filter((b) => b.status === "want").concat(unread).forEach((b) => (b.tags || []).forEach((t) => waiting.add(t.toLowerCase())));
    const gap = Object.entries(tally).sort((a, b) => b[1] - a[1]).slice(0, 3).find(([t]) => !waiting.has(t.toLowerCase()));
    if (gap) lines.push(`You've finished <strong>${gap[1]} ${esc(gap[0])}</strong> books but have none waiting — a gap on your shelf`);
    // Author gap: someone you rate highly with nothing of theirs queued.
    const byAuthor: Record<string, number[]> = {};
    finished.forEach((b) => { const k = (b.author || "").trim(); if (k && b.rating) { (byAuthor[k] = byAuthor[k] || []).push(Number(b.rating)); } });
    const tbrAuthors = new Set(state.books.filter((b) => b.status === "want").concat(unread).map((b) => (b.author || "").trim().toLowerCase()));
    const fav = Object.entries(byAuthor)
      .filter(([, rs]) => rs.length >= 2 && rs.reduce((a, r) => a + r, 0) / rs.length >= 4)
      .sort((a, b) => b[1].length - a[1].length)
      .find(([a]) => !tbrAuthors.has(a.toLowerCase()));
    if (fav) lines.push(`You rate <strong>${esc(fav[0])}</strong> ${(fav[1].reduce((a, r) => a + r, 0) / fav[1].length).toFixed(1)}★ on average — nothing of theirs is on your list`);
  }
  return lines;
}
// A pick that fits HOW the reader is reading right now (recent session size),
// with the mood of recent sessions as colour.
function moodMatchLine() {
  const cutoff = Date.now() - 21 * DAY;
  const recent: ReadingLog[] = [];
  state.books.forEach((b) => (b.logs || []).forEach((l) => { if (new Date(l.date).getTime() >= cutoff && l.pages > 0) recent.push(l); }));
  if (recent.length < 3) return "";
  const avg = recent.reduce((a, l) => a + l.pages, 0) / recent.length;
  const moods = recent.map((l) => l.mood).filter(Boolean);
  const topMood = moods.length ? moods.sort((a, b) => moods.filter((m) => m === b).length - moods.filter((m) => m === a).length)[0] : "";
  const pool = state.books.filter((b) => (b.status === "want" || (b.owned && b.status !== "finished" && b.status !== "dnf" && pagesRead(b) === 0)) && b.totalPages);
  if (!pool.length) return "";
  const short = avg < 22;
  const pick = pool.slice().sort((a, b) => short ? a.totalPages - b.totalPages : b.totalPages - a.totalPages)[0];
  return `Lately you read in ${short ? "short bursts" : "long, deep sessions"}${topMood ? ` (mostly feeling ${esc(topMood)})` : ""} — <strong>${esc(pick.title)}</strong> (${num(pick.totalPages)}p) fits that rhythm`;
}

function renderInsights() {
  const el = $("#insights");
  if (!el) return;
  const s = sessionInsights(), t = tasteProfile(), nudges = coachNudges();
  const cards = [];
  const shelf = shelfInsightLines();
  const mood = moodMatchLine();
  if (shelf.length) cards.push(insightCard("🧭", "Shelf insights", shelf));
  if (mood) cards.push(insightCard("🎯", "For right now", [mood]));
  if (s) cards.push(insightCard("⏰", "Your reading rhythm", [
    s.bestTime ? `You read most in the <strong>${s.bestTime.toLowerCase()}</strong>` : "",
    s.bestDay ? `Your biggest reading day is <strong>${s.bestDay}</strong>` : "",
    s.avgMin ? `A typical session runs <strong>${s.avgMin} min</strong>` : "",
    s.audioPct ? `<strong>${s.audioPct}%</strong> of your pages come from audiobooks` : "",
  ]));
  if (t) cards.push(insightCard("🧬", "Your book DNA", [
    t.topGenres.length ? `You gravitate toward <strong>${t.topGenres.map(esc).join(", ")}</strong>` : "",
    t.bestAuthor ? `Your highest-rated author is <strong>${esc(t.bestAuthor)}</strong> (${t.bestAvg.toFixed(1)}★ avg)` : "",
    t.avgLen ? `You usually finish <strong>~${num(t.avgLen)}-page</strong> books` : "",
    t.longest ? `Your longest finish: <strong>${esc(t.longest.title)}</strong> · ${num(t.longest.totalPages)}p` : "",
  ]));
  if (nudges.length) cards.push(`<div class="insight-card coach"><div class="insight-emoji">🌱</div><div><h4>A gentle nudge</h4>${nudges.map((n) => `<p>${n}</p>`).join("")}</div></div>`);
  el.innerHTML = cards.length ? `<h3 class="insights-h">Your reading, understood</h3><div class="insights-grid">${cards.join("")}</div>` : "";
}

function coverHTML(book: Book, cls?: string) {
  if (book.coverUrl) {
    return `<img class="cover ${cls || ""}" src="${esc(book.coverUrl)}" alt="Cover of ${esc(book.title)}" loading="lazy" decoding="async"
              onerror="this.outerHTML='<div class=\\'cover ${cls || ""}\\'>${esc(book.title)}</div>'" />`;
  }
  return `<div class="cover ${cls || ""}">${esc(book.title)}</div>`;
}
function starsHTML(rating: number | null | undefined) {
  const r = Number(rating) || 0;
  let out = "";
  for (let i = 1; i <= 5; i++) {
    if (r >= i) out += `<span>★</span>`;
    else if (r >= i - 0.5) out += `<span class="half">★</span>`;
    else out += `<span class="off">★</span>`;
  }
  return `<span class="stars">${out}</span>`;
}
function fmtRating(r: number | null | undefined) { return r == null ? "" : (r % 1 === 0 ? String(r) : r.toFixed(1)); }

// Small per-book badges used across cards
function lentBadgeHTML(b: Book) {
  if (!b.lentTo) return "";
  const days = b.lentAt ? Math.floor((Date.now() - new Date(b.lentAt).getTime()) / DAY) : 0;
  const long = days >= 45; // gentle nudge once it's been out ~6 weeks
  return `<span class="lent-badge${long ? " overdue" : ""}" title="Lent out${b.lentAt ? " " + fmtDate(b.lentAt) : ""}${long ? " — maybe ask for it back?" : ""}">📤 ${esc(b.lentTo)}${days > 0 ? " · " + days + "d" : ""}</span>`;
}
function loanBadgeHTML(b: Book) {
  if (!b.loanDue) return "";
  const due = startOfDay(new Date(b.loanDue + "T12:00:00"));
  if (isNaN(due)) return "";
  const days = Math.round((due - startOfDay(new Date())) / DAY);
  const cls = days < 0 ? " overdue" : days <= 5 ? " soon" : "";
  const label = days < 0 ? `overdue by ${Math.abs(days)}d` : days === 0 ? "due back today" : days <= 14 ? `due back in ${days}d` : `due ${fmtDate(new Date(due).toISOString())}`;
  return `<span class="loan-badge${cls}" title="Borrowed copy — due back ${fmtDate(new Date(due).toISOString())}">📅 ${label}</span>`;
}
function tbrAgeHTML(b: Book) {
  const months = Math.floor((Date.now() - new Date(b.addedAt).getTime()) / (DAY * 30.44));
  if (!(months >= 6)) return "";
  return `<span class="tbr-badge" title="On your list since ${fmtDate(b.addedAt)}">🕰 ${months} months on your list</span>`;
}
function ownFlag(b: Book) { return b.owned ? `<span class="own-flag" title="On your home shelf">🏠</span>` : ""; }
function bookmarkHTML(b: Book) {
  if (!b.bookmark) return "";
  return `<p class="bookmark-line" title="Bookmark saved ${fmtDate(b.bookmark.date)}">🔖 ${b.bookmark.page ? "p." + b.bookmark.page : "Where I left off"}${b.bookmark.note ? " — “" + esc(b.bookmark.note) + "”" : ""}</p>`;
}

function renderReading() {
  const all = state.books.filter((b) => b.status === "reading");
  const list = all.filter((b) => bookMatches(b, readingQuery)).sort((a, b) => new Date(b.addedAt).getTime() - new Date(a.addedAt).getTime());
  const empty = $("#reading-empty");
  empty.hidden = list.length > 0;
  empty.textContent = all.length === 0 ? "You're not reading anything yet. Add a book to start logging your pages." : "No books match your search.";
  $("#reading-list").innerHTML = list.map((b) => {
    const read = pagesRead(b);
    const pct = b.totalPages ? Math.min(100, Math.round((read / b.totalPages) * 100)) : 0;
    const est = estimateFinish(b);
    return `<article class="book-card" data-id="${b.id}">
        ${coverHTML(b)}
        <div class="book-meta">
          <h3 class="book-title">${fmtIcon(b)}${esc(b.title)}${ownFlag(b)}</h3>
          <p class="book-author">${esc(b.author) || "Unknown author"}${seriesLabel(b)} ${lentBadgeHTML(b)}${loanBadgeHTML(b)}</p>
          <div class="progress"><span style="width:${pct}%"></span></div>
          <p class="progress-label">${num(read)}${b.totalPages ? " / " + num(b.totalPages) : ""} ${unitLabel(b)}${b.totalPages ? " · " + pct + "%" : ""}${est ? ` · <span class="eta">≈ done ${fmtDate(est.date.toISOString())}</span>` : ""}</p>
          ${bookmarkHTML(b)}
          ${chipsHTML(b, true)}
          <div class="card-actions">
            <button class="mini" data-action="log" data-id="${b.id}">＋ Log</button>
            <button class="mini" data-action="bookmark" data-id="${b.id}" title="Where did you leave off?">🔖</button>
            <button class="mini" data-action="detail" data-id="${b.id}">📈 Progress</button>
            <button class="mini" data-action="finish" data-id="${b.id}">✓ Finish</button>
            <button class="mini" data-action="dnf" data-id="${b.id}">✕ DNF</button>
            <button class="mini" data-action="edit" data-id="${b.id}">✎ Edit</button>
            <button class="mini danger" data-action="delete" data-id="${b.id}">🗑</button>
          </div>
          ${b.review ? `<details class="review"><summary>My notes</summary><p class="review-text">${esc(b.review)}</p></details>` : ""}
        </div>
      </article>`;
  }).join("");
}

// ---- "Read next" — a fully local recommender over the TBR ----------------
// Scores every want-list book against the reader's own history (ratings,
// genres, authors, series position, DNFs, ownership, expectations, TBR age).
// Nothing leaves the device; with too little history it stays quiet.
function readNextPicks(books?: Book[]) {
  const src = books || state.books;
  const finished = src.filter((b) => b.status === "finished");
  const dnf = src.filter((b) => b.status === "dnf");
  const want = src.filter((b) => b.status === "want");
  if (want.length < 2 || finished.length < 2) return [];

  // Taste weights: loved = +2 … hated = -2; an unrated finish is a mild +.
  const tasteOf = (b: Book) => (b.rating ? Number(b.rating) - 3 : 0.5);
  const genre: Record<string, { sum: number; n: number }> = {}; // tag -> {sum, n}
  const author: Record<string, { sum: number; n: number; dnf: number }> = {}; // author -> {sum, n, dnf}
  finished.forEach((b) => {
    const w = tasteOf(b);
    (b.tags || []).forEach((t) => { const k = t.toLowerCase(); const e = genre[k] = genre[k] || { sum: 0, n: 0 }; e.sum += w; e.n++; });
    const ak = (b.author || "").trim().toLowerCase();
    if (ak) { const e = author[ak] = author[ak] || { sum: 0, n: 0, dnf: 0 }; e.sum += w; e.n++; }
  });
  dnf.forEach((b) => {
    (b.tags || []).forEach((t) => { const k = t.toLowerCase(); const e = genre[k] = genre[k] || { sum: 0, n: 0 }; e.sum -= 1; e.n++; });
    const ak = (b.author || "").trim().toLowerCase();
    if (ak) { const e = author[ak] = author[ak] || { sum: 0, n: 0, dnf: 0 }; e.dnf++; }
  });
  // Furthest finished installment per series, for continuation boosts.
  const seriesDone: Record<string, number> = {};
  src.forEach((b) => {
    if (b.status === "finished" && b.seriesName) {
      const k = b.seriesName.toLowerCase();
      seriesDone[k] = Math.max(seriesDone[k] || 0, b.seriesNumber != null ? Number(b.seriesNumber) : 0.5);
    }
  });
  const dnfSeries = new Set(dnf.filter((b) => b.seriesName).map((b) => b.seriesName.toLowerCase()));

  const now = Date.now();
  const picks = want.map((b) => {
    let score = 0; const why = [];
    // Genres: confidence-scaled average taste per tag (one 5★ book shouldn't dominate).
    let bestTag = null, bestTagScore = 0;
    (b.tags || []).forEach((t) => {
      const e = genre[t.toLowerCase()];
      if (!e || !e.n) return;
      const s = (e.sum / e.n) * Math.min(1, e.n / 3);
      score += s * 2;
      if (s > bestTagScore) { bestTag = t; bestTagScore = s; }
    });
    if (bestTag && bestTagScore >= 0.3) why.push(`you rate ${bestTag} highly`);
    // Author: your average with them, minus a penalty per DNF of theirs.
    const ae = author[(b.author || "").trim().toLowerCase()];
    if (ae) {
      const s = (ae.n ? ae.sum / ae.n : 0) * Math.min(1, ae.n / 2) - ae.dnf * 1.5;
      score += s * 3;
      if (s >= 0.5) why.push(`more from ${b.author}`);
    }
    // Series: the very next installment is the strongest signal there is.
    if (b.seriesName) {
      const k = b.seriesName.toLowerCase();
      const done = seriesDone[k] || 0;
      if (done && b.seriesNumber != null && Number(b.seriesNumber) === Math.floor(done) + 1) { score += 4; why.push(`next in ${b.seriesName}`); }
      else if (done) { score += 0.5; }
      if (dnfSeries.has(k)) score -= 2;
    }
    if (b.owned) { score += 1.5; why.push("already on your shelf"); }
    if (b.expectation) { score += Number(b.expectation) - 3; if (Number(b.expectation) >= 4) why.push("you had high hopes for it"); }
    const months = (now - new Date(b.addedAt || now).getTime()) / (30.44 * 24 * 3600 * 1000);
    if (months >= 6) { score += Math.min(2, months / 12); why.push(`${Math.round(months)} months on your list`); }
    return { book: b, score: Math.round(score * 100) / 100, why };
  });
  picks.sort((a, b) => b.score - a.score);
  return picks.filter((p) => p.score > 0.5).slice(0, 3);
}

function renderReadNext() {
  const box = $("#read-next");
  if (!box) return;
  const picks = readNextPicks();
  if (!picks.length) { box.innerHTML = ""; return; }
  box.innerHTML = `<div class="read-next">
      <h3 class="rn-title">✨ Read next? <span class="muted rn-sub">picked from your list, just for you — nothing leaves this device</span></h3>
      <div class="rn-row">${picks.map(({ book: b, why }) => `
        <div class="rn-card" data-id="${b.id}">
          ${coverHTML(b)}
          <div class="rn-meta">
            <strong class="rn-book">${esc(b.title)}</strong>
            <span class="muted">${esc(b.author) || "Unknown author"}</span>
            <div class="rn-why">${why.slice(0, 3).map((w) => `<span class="rn-chip">${esc(w)}</span>`).join("")}</div>
            <button class="mini primary" data-action="start" data-id="${b.id}">▶ Start reading</button>
          </div>
        </div>`).join("")}</div>
    </div>`;
}

function renderWant() {
  renderReadNext();
  const all = state.books.filter((b) => b.status === "want");
  const list = all.filter((b) => bookMatches(b, wantQuery)).sort((a, b) => new Date(b.addedAt).getTime() - new Date(a.addedAt).getTime());
  const empty = $("#want-empty");
  empty.hidden = list.length > 0;
  empty.textContent = all.length === 0 ? "Nothing on your list yet. Add books you'd like to read next." : "No books match your search.";
  $("#want-list").innerHTML = list.map((b) => `
      <article class="book-card" data-id="${b.id}">
        ${coverHTML(b)}
        <div class="book-meta">
          <h3 class="book-title">${fmtIcon(b)}${esc(b.title)}${ownFlag(b)}</h3>
          <p class="book-author">${esc(b.author) || "Unknown author"}${seriesLabel(b)} ${tbrAgeHTML(b)}${lentBadgeHTML(b)}${loanBadgeHTML(b)}</p>
          ${b.pickReason ? `<p class="pick-reason">💭 ${esc(b.pickReason)}</p>` : ""}
          ${b.expectation ? `<p class="pick-reason">Hoping for ${starsHTML(b.expectation)}</p>` : ""}
          ${chipsHTML(b, true)}
          <div class="card-actions">
            <button class="mini" data-action="start" data-id="${b.id}">▶ Start reading</button>
            <button class="mini" data-action="detail" data-id="${b.id}">ℹ️ Details</button>
            <button class="mini" data-action="edit" data-id="${b.id}">✎ Edit</button>
            <button class="mini danger" data-action="delete" data-id="${b.id}">🗑</button>
          </div>
        </div>
      </article>`).join("");
}

function libDate(b: Book) {
  if (b.status === "dnf") return `<span class="dnf-badge" title="${b.dnfReason ? esc(b.dnfReason) : "Did not finish"}">Did not finish${b.dnfReason ? " · " + esc(b.dnfReason.length > 40 ? b.dnfReason.slice(0, 38) + "…" : b.dnfReason) : ""}</span>`;
  return `Finished${b.finishedAt ? " " + fmtDate(b.finishedAt) : ""}${b.readCount > 1 ? " · " + b.readCount + "× read" : ""} · ${num(pagesRead(b) || b.totalPages)}${unitShort(b)}${b.loanDue ? " " + loanBadgeHTML(b) : ""}`;
}

function renderLibrary() {
  const tagSel = $<HTMLSelectElement>("#library-tag"), tags = allTags();
  if (libraryTag && !tags.some((t) => t.toLowerCase() === libraryTag.toLowerCase())) libraryTag = "";
  tagSel.innerHTML = `<option value="">All genres</option>` + tags.map((t) => `<option value="${esc(t)}">${esc(t)}</option>`).join("");
  tagSel.value = libraryTag;

  const colSel = $<HTMLSelectElement>("#library-collection"), cols = allCollections();
  if (libraryCollection && !cols.some((t) => t.toLowerCase() === libraryCollection.toLowerCase())) libraryCollection = "";
  colSel.innerHTML = `<option value="">All shelves</option>` + cols.map((t) => `<option value="${esc(t)}">📁 ${esc(t)}</option>`).join("");
  colSel.value = libraryCollection;

  $$("#library-view-toggle button").forEach((btn) => btn.classList.toggle("active", btn.dataset.libview === libraryView));

  $<HTMLSelectElement>("#library-format").value = libraryFormat;
  $<HTMLSelectElement>("#library-rating").value = libraryRating ? String(libraryRating) : "";

  const done = libraryBooks();
  let list = done
    .filter((b) => bookMatches(b, libraryQuery))
    .filter((b) => !libraryTag || (b.tags || []).some((t) => t.toLowerCase() === libraryTag.toLowerCase()))
    .filter((b) => !libraryCollection || (b.collections || []).some((t) => t.toLowerCase() === libraryCollection.toLowerCase()))
    .filter((b) => !libraryFormat || (b.format || "physical") === libraryFormat)
    .filter((b) => !libraryRating || (b.rating || 0) >= libraryRating);
  const sort = $<HTMLSelectElement>("#library-sort").value;
  list.sort((a, b) => {
    if (sort === "finished-asc") return new Date(a.finishedAt || 0).getTime() - new Date(b.finishedAt || 0).getTime();
    if (sort === "rating-desc") return (b.rating || 0) - (a.rating || 0);
    if (sort === "pages-desc") return (b.totalPages || 0) - (a.totalPages || 0);
    if (sort === "title-asc") return a.title.localeCompare(b.title);
    return new Date(b.finishedAt || 0).getTime() - new Date(a.finishedAt || 0).getTime();
  });

  const empty = $("#library-empty");
  empty.hidden = list.length > 0;
  empty.textContent = done.length === 0 ? "No finished books yet. Add books you've already read, or finish one you're reading." : "No books match your search or filter.";

  const wrap = $("#library-list");
  if (libraryView === "shelf") { wrap.innerHTML = shelfHTML(list); if (list.length) empty.hidden = true; }
  else if (libraryView === "author") wrap.innerHTML = `<div class="author-view">${authorHTML(list)}</div>`;
  else if (libraryView === "series") { wrap.innerHTML = seriesHTML(); empty.hidden = true; }
  else wrap.innerHTML = `<div class="card-grid library">${list.map(libraryCardHTML).join("")}</div>`;
}

function libraryCardHTML(b: Book) {
  return `<article class="book-card lib-card ${b.status === "dnf" ? "is-dnf" : ""}" data-id="${b.id}">
      ${coverHTML(b)}
      <h3 class="book-title">${fmtIcon(b)}${esc(b.title)}${ownFlag(b)}</h3>
      <p class="book-author">${esc(b.author) || "Unknown author"}${seriesLabel(b)} ${lentBadgeHTML(b)}</p>
      ${starsHTML(b.rating)}
      <p class="lib-date">${libDate(b)}</p>
      ${chipsHTML(b, true)}
      <div class="card-actions">
        <button class="mini" data-action="detail" data-id="${b.id}">📈 Progress</button>
        <button class="mini" data-action="rate" data-id="${b.id}">★ Rate</button>
        <button class="mini" data-action="edit" data-id="${b.id}">✎ Edit</button>
        <button class="mini danger" data-action="delete" data-id="${b.id}">🗑</button>
      </div>
      ${b.review ? `<details class="review"><summary>My review</summary><p class="review-text">${esc(b.review)}</p></details>` : ""}
    </article>`;
}
function shelfHTML(list: Book[]) {
  if (!list.length) return "";
  // Custom order: the user arranges their own shelf by dragging.
  const idx: Record<string, number> = {};
  (state.shelfOrder || []).forEach((id, i) => (idx[id] = i));
  const ordered = list.slice().sort((a, b) => (idx[a.id] != null ? idx[a.id] : 1e9) - (idx[b.id] != null ? idx[b.id] : 1e9));
  const slots = ordered.map((b, i) => {
    const hue = hashHue(b.title + b.author);
    const h = Math.max(118, Math.min(205, 118 + (b.totalPages || 200) / 6));
    const w = 34 + (hashHue(b.id) % 14); // varied thickness, stable per book
    const lean = i % 11 === 4 ? " lean-l" : i % 7 === 5 ? " lean-r" : "";
    return `<div class="shelf-slot" draggable="true" data-shelf-id="${b.id}">
        <button class="spine${lean}" data-action="detail" data-id="${b.id}" style="--hue:${hue}; height:${h}px; width:${w}px" title="${esc(b.title)} — ${esc(b.author)}"><span class="spine-title">${esc(b.title)}</span></button>
      </div>`;
  }).join("");
  return `<p class="shelf-hint muted">🖐 Drag books to arrange your shelf however you like — your order is saved.</p><div class="bookshelf">${slots}</div>`;
}

// Drag & drop shelf rearranging (mouse via HTML5 DnD, touch via long-press).
function saveShelfOrderFromDOM(shelf: HTMLElement) {
  state.shelfOrder = $$(".shelf-slot", shelf).map((s) => s.dataset.shelfId as string);
  commit();
}
function setupShelfDnD(root: HTMLElement) {
  let dragEl: HTMLElement | null = null;
  root.addEventListener("dragstart", (e) => {
    const slot = (e.target as HTMLElement).closest<HTMLElement>(".shelf-slot");
    if (!slot) return;
    dragEl = slot;
    slot.classList.add("dragging");
    e.dataTransfer!.effectAllowed = "move";
    try { e.dataTransfer!.setData("text/plain", slot.dataset.shelfId!); } catch (err: any) { /* old browsers */ }
  });
  root.addEventListener("dragover", (e) => {
    if (!dragEl) return;
    e.preventDefault();
    const over = (e.target as HTMLElement).closest<HTMLElement>(".shelf-slot");
    if (!over || over === dragEl || !over.parentNode) return;
    const r = over.getBoundingClientRect();
    over.parentNode.insertBefore(dragEl, e.clientX < r.left + r.width / 2 ? over : over.nextSibling);
  });
  root.addEventListener("drop", (e) => { if (dragEl) e.preventDefault(); });
  root.addEventListener("dragend", () => {
    if (!dragEl) return;
    dragEl.classList.remove("dragging");
    const shelf = dragEl.closest<HTMLElement>(".bookshelf");
    dragEl = null;
    if (shelf) saveShelfOrderFromDOM(shelf);
  });
  // Touch: hold a book for a moment, then drag it along the shelf.
  let touchDrag: HTMLElement | null = null, holdTimer: ReturnType<typeof setTimeout> | null = null, suppressClick = false;
  root.addEventListener("pointerdown", (e) => {
    if (e.pointerType === "mouse") return;
    const slot = (e.target as HTMLElement).closest<HTMLElement>(".shelf-slot");
    if (!slot) return;
    holdTimer = setTimeout(() => { touchDrag = slot; slot.classList.add("dragging"); }, 350);
  });
  root.addEventListener("pointermove", (e) => {
    if (!touchDrag) { clearTimeout(holdTimer!); return; }
    const el = document.elementFromPoint(e.clientX, e.clientY);
    const over = el && el.closest<HTMLElement>(".shelf-slot");
    if (!over || over === touchDrag || !over.parentNode) return;
    const r = over.getBoundingClientRect();
    over.parentNode.insertBefore(touchDrag, e.clientX < r.left + r.width / 2 ? over : over.nextSibling);
  });
  const endTouch = () => {
    clearTimeout(holdTimer!);
    if (!touchDrag) return;
    touchDrag.classList.remove("dragging");
    const shelf = touchDrag.closest<HTMLElement>(".bookshelf");
    touchDrag = null;
    suppressClick = true;
    setTimeout(() => (suppressClick = false), 350);
    if (shelf) saveShelfOrderFromDOM(shelf);
  };
  root.addEventListener("pointerup", endTouch);
  root.addEventListener("pointercancel", endTouch);
  root.addEventListener("click", (e) => { if (suppressClick) { e.stopPropagation(); e.preventDefault(); } }, true);
}

// Series progress: every series you've touched, how far you are, what's next.
function seriesHTML() {
  const groups: Record<string, Book[]> = {};
  state.books.forEach((b) => { if (b.seriesName) (groups[b.seriesName] = groups[b.seriesName] || []).push(b); });
  const names = Object.keys(groups).sort((a, b) => a.localeCompare(b));
  if (!names.length) return `<p class="empty">No series yet — set “Series” on a book and your progress will show up here.</p>`;
  const STATUS_ICON = { finished: "✅", reading: "📖", want: "⏳", dnf: "🚧" };
  return `<div class="series-view">` + names.map((name) => {
    const books = groups[name].slice().sort((a, b) => (a.seriesNumber || 999) - (b.seriesNumber || 999) || a.title.localeCompare(b.title));
    const read = books.filter((b) => b.status === "finished").length;
    const owned = books.filter((b) => b.owned).length;
    const next = books.find((b) => b.status !== "finished" && b.status !== "dnf");
    const pct = Math.round((read / books.length) * 100);
    // Gaps in the numbering you hold, e.g. you have #1, #2, #4 → #3 is missing.
    const nums = books.map((b) => b.seriesNumber).filter((n): n is number => n != null && Number.isInteger(n)).sort((a, b) => a - b);
    const missing = [];
    if (nums.length) for (let n = nums[0]; n < nums[nums.length - 1]; n++) if (nums.indexOf(n) === -1) missing.push(n);
    // Own a later book but haven't read the one right before it.
    const gapWarn = books.find((b) => b.owned && b.status !== "finished" && b.seriesNumber != null && books.some((p) => p.seriesNumber === b.seriesNumber! - 1 && p.status !== "finished"));
    return `<div class="series-group">
        <h3 class="series-head">${esc(name)} <span class="muted">· ${read} of ${books.length} read${owned ? " · " + owned + " owned" : ""}</span></h3>
        <div class="progress series-progress"><span style="width:${pct}%"></span></div>
        ${next ? `<p class="series-next">👉 Next up: ${next.seriesNumber ? "#" + next.seriesNumber + " · " : ""}${esc(next.title)}${next.owned ? " 🏠" : ` <span class="series-flag">· you don't own this yet</span>`}</p>` : `<p class="series-next done">🎉 Series complete!</p>`}
        ${missing.length ? `<p class="series-flag">🧩 Missing from your shelf: ${missing.map((n) => "#" + n).join(", ")}</p>` : ""}
        ${gapWarn ? `<p class="series-flag">⚠️ You own #${gapWarn.seriesNumber} but haven't read #${gapWarn.seriesNumber! - 1} yet.</p>` : ""}
        <div class="author-books">${books.map((b) => `
          <button class="author-book" data-action="detail" data-id="${b.id}">${coverHTML(b)}<span class="ab-title">${STATUS_ICON[b.status] || ""} ${b.seriesNumber ? "#" + b.seriesNumber + " · " : ""}${esc(b.title)}${b.owned ? " 🏠" : ""}</span></button>`).join("")}</div>
      </div>`;
  }).join("") + `</div>`;
}
function authorHTML(list: Book[]) {
  const groups: Record<string, Book[]> = {};
  list.forEach((b) => { const a = b.author || "Unknown author"; (groups[a] = groups[a] || []).push(b); });
  return Object.keys(groups).sort((a, b) => a.localeCompare(b)).map((a) => `
      <div class="author-group">
        <h3 class="author-name">${esc(a)} <span class="muted">· ${groups[a].length} book${groups[a].length === 1 ? "" : "s"}</span></h3>
        <div class="author-books">${groups[a].sort((x, y) => (x.seriesNumber || 0) - (y.seriesNumber || 0) || x.title.localeCompare(y.title)).map((b) => `
          <button class="author-book" data-action="detail" data-id="${b.id}">${coverHTML(b)}<span class="ab-title">${esc(b.title)}</span>${b.rating ? starsHTML(b.rating) : ""}</button>`).join("")}</div>
      </div>`).join("");
}

function renderAchievements() {
  const badges = computeBadges();
  const groups: Record<string, HTMLElement> = { pages: $("#badges-pages"), books: $("#badges-books"), special: $("#badges-special") };
  Object.values(groups).forEach((el) => (el.innerHTML = ""));
  badges.forEach((b) => {
    const next = b.unlocked ? "" : `<div class="b-prog">${num(b.value)} / ${num(b.target)}</div>`;
    groups[b.group].insertAdjacentHTML("beforeend", `
        <div class="badge ${b.unlocked ? "unlocked" : "locked"}">
          <div class="emoji">${b.emoji}</div><div class="b-title">${esc(b.title)}</div>
          <div class="b-desc">${esc(b.desc)}</div>${next}
        </div>`);
  });
  $("#ach-pages-value").textContent = "· " + num(totalPagesRead()) + " total";
  $("#ach-books-value").textContent = "· " + num(booksFinished().length) + " total";
}

// ---------------------------------------------------------------------------
// Goals + challenges
// ---------------------------------------------------------------------------
function renderGoal() {
  const goal = state.settings.goal;
  const done = booksFinishedInYear(goal.year);
  const target = goal.target || 0;
  const pct = target ? Math.min(100, (done / target) * 100) : 0;
  const circ = 2 * Math.PI * 52;
  const fg = $("#goal-ring-fg");
  fg.style.strokeDasharray = circ.toFixed(1);
  fg.style.strokeDashoffset = (circ * (1 - pct / 100)).toFixed(1);
  $("#goal-count").textContent = String(done);
  $("#goal-of").textContent = "of " + target;
  if (document.activeElement !== $<HTMLInputElement>("#goal-year")) $<HTMLInputElement>("#goal-year").value = String(goal.year);
  if (document.activeElement !== $<HTMLInputElement>("#goal-target")) $<HTMLInputElement>("#goal-target").value = String(target);
  if (document.activeElement !== $<HTMLInputElement>("#goal-pages")) $<HTMLInputElement>("#goal-pages").value = String(goal.pagesTarget || "");
  if (document.activeElement !== $<HTMLInputElement>("#goal-daily")) $<HTMLInputElement>("#goal-daily").value = String(goal.dailyPages || "");
  const hint = $("#goal-hint");
  if (target && done >= target) hint.textContent = `🎉 Goal smashed! ${done} books in ${goal.year}.`;
  else if (target) hint.textContent = `${target - done} to go in ${goal.year}.`;
  else hint.textContent = "";
  renderGoalExtra();
  renderChallenges();
}
function metricHTML(label: string, valTxt: string, pct: number, extra?: string) {
  return `<div class="goal-metric"><div class="gm-head"><span>${label}</span><span>${valTxt}</span></div>
      <div class="progress"><span style="width:${Math.min(100, pct)}%"></span></div>${extra ? `<p class="gm-sub">${extra}</p>` : ""}</div>`;
}
function renderGoalExtra() {
  const g = state.settings.goal;
  const isThisYear = g.year === new Date().getFullYear();
  let html = "";
  if (g.pagesTarget > 0) {
    const pr = pagesReadInYear(g.year);
    html += metricHTML(`Pages in ${g.year}`, `${num(pr)} / ${num(g.pagesTarget)}`, pr / g.pagesTarget * 100,
      pr >= g.pagesTarget ? "🎉 Page goal reached!" : `${num(g.pagesTarget - pr)} pages to go`);
  }
  if (g.dailyPages > 0) {
    const tp = pagesOnDay(startOfDay(new Date()));
    html += metricHTML("Today's reading", `${num(tp)} / ${num(g.dailyPages)} pages`, tp / g.dailyPages * 100,
      tp >= g.dailyPages ? "✅ Daily goal done — nice!" : "Read a little more to hit today's goal.");
  }
  if (isThisYear && g.target > 0) {
    const done = booksFinishedInYear(g.year);
    const now = new Date();
    const dayOfYear = Math.floor((now.getTime() - new Date(now.getFullYear(), 0, 0).getTime()) / DAY);
    const expected = g.target * (dayOfYear / 365);
    const diff = done - expected;
    const rounded = Math.abs(Math.round(diff * 10) / 10);
    let pace;
    if (diff >= 0.1) pace = `🟢 You're ${rounded} book${rounded === 1 ? "" : "s"} ahead of schedule.`;
    else if (diff <= -0.1) pace = `🟠 You're ${rounded} book${rounded === 1 ? "" : "s"} behind schedule.`;
    else pace = `🎯 Right on pace.`;
    html += `<div class="goal-metric pacing">${pace}</div>`;
  }
  $("#goal-extra").innerHTML = html;
}
function renderChallenges() {
  const ch = computeChallenges();
  $("#challenge-count").textContent = "· " + ch.filter((c) => c.unlocked).length + " / " + ch.length + " done";
  $("#challenges").innerHTML = ch.map((c) => `
      <div class="badge ${c.unlocked ? "unlocked" : "locked"}">
        <div class="emoji">${c.emoji}</div><div class="b-title">${esc(c.title)}</div>
        <div class="b-desc">${esc(c.desc)}</div>${c.unlocked ? "" : `<div class="b-prog">${num(c.value)} / ${num(c.target)}</div>`}
      </div>`).join("");
}

// ---------------------------------------------------------------------------
// Stats view
// ---------------------------------------------------------------------------
function renderStatsView() {
  const logs: { d: Date; pages: number }[] = [];
  state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d.getTime())) logs.push({ d, pages: Number(l.pages) || 0 }); }));
  const empty = logs.length === 0;
  $("#stats-empty").hidden = !empty;

  const streak = readingStreak();
  const perDay = perDayMap();
  const daysRead = Object.keys(perDay).length;
  const tp = totalPagesRead();
  const best = Object.values(perDay).reduce((m, v) => Math.max(m, v), 0);
  $("#stat-cards").innerHTML = `
      <div class="stat"><div class="num">${num(streak.current)}</div><div class="lbl">Current streak 🔥</div></div>
      <div class="stat"><div class="num">${num(streak.longest)}</div><div class="lbl">Longest streak</div></div>
      <div class="stat"><div class="num">${num(daysRead)}</div><div class="lbl">Days read</div></div>
      <div class="stat"><div class="num">${num(daysRead ? Math.round(tp / daysRead) : 0)}</div><div class="lbl">Avg pages / day read</div></div>
      <div class="stat"><div class="num">${num(best)}</div><div class="lbl">Best day</div></div>`;

  $("#cal-sub").textContent = "· last 6 months";
  $("#chart-calendar").innerHTML = empty ? "" : svgCalendar(perDay);
  $("#chart-daily").innerHTML = empty ? "" : svgBars(dailyItems(perDay), "pages");
  $("#chart-monthly").innerHTML = empty ? "" : svgBars(monthlyItems(logs), "pages");

  const gi = genreItems();
  $("#chart-genre").innerHTML = gi.length ? svgBars(gi, "books") : `<p class="muted">Add genres to your books to see this.</p>`;
  const ri = ratingItems();
  $("#chart-ratings").innerHTML = ri.some((r) => r.value) ? svgBars(ri, "books") : `<p class="muted">Rate some books to see this.</p>`;
}
function dailyItems(perDay: Record<number, number>): ChartItem[] {
  const today = startOfDay(new Date()), items = [];
  for (let i = 29; i >= 0; i--) {
    const t = today - i * DAY, d = new Date(t);
    items.push({ full: d.toLocaleDateString(undefined, { month: "short", day: "numeric" }), value: perDay[t] || 0, tick: i % 5 === 0 ? (d.getMonth() + 1) + "/" + d.getDate() : "" });
  }
  return items;
}
function monthlyItems(logs: { d: Date; pages: number }[]): ChartItem[] {
  const NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const now = new Date(), buckets: { y: number; m: number; value: number }[] = [];
  for (let i = 11; i >= 0; i--) { const d = new Date(now.getFullYear(), now.getMonth() - i, 1); buckets.push({ y: d.getFullYear(), m: d.getMonth(), value: 0 }); }
  logs.forEach((x) => { const b = buckets.find((bk) => bk.y === x.d.getFullYear() && bk.m === x.d.getMonth()); if (b) b.value += x.pages; });
  return buckets.map((b) => ({ full: NAMES[b.m] + " " + b.y, value: b.value, tick: NAMES[b.m] }));
}
function genreItems() {
  const counts: Record<string, number> = {};
  state.books.forEach((b) => (b.tags || []).forEach((t) => { counts[t] = (counts[t] || 0) + 1; }));
  return Object.keys(counts).map((k) => ({ full: k, value: counts[k], tick: k.length > 14 ? k.slice(0, 13) + "…" : k }))
    .sort((a, b) => b.value - a.value).slice(0, 8);
}
function ratingItems() {
  const counts = [0, 0, 0, 0, 0];
  state.books.forEach((b) => { const r = Math.round(b.rating || 0); if (r >= 1 && r <= 5) counts[r - 1]++; });
  return counts.map((v, i) => ({ full: (i + 1) + " star", value: v, tick: (i + 1) + "★" }));
}
function svgBars(items: ChartItem[], unit: string) {
  const slot = 26, padT = 16;
  // Long tick labels (genre names) overlap when drawn flat at 26px slots —
  // angle them instead, and budget bottom/left space for the slanted text.
  const maxTick = Math.max(0, ...items.map((i) => (i.tick || "").length));
  const angled = maxTick > 5;
  const padB = angled ? Math.min(72, 16 + Math.round(maxTick * 3.6)) : 26;
  const padXL = angled ? Math.min(60, 10 + Math.round(maxTick * 3.2)) : 8;
  const padXR = 8;
  const H = 144 + padB; // plot area stays 128px tall in both modes
  const W = Math.max(items.length * slot + padXL + padXR, 320);
  const areaH = H - padT - padB, maxV = Math.max(1, ...items.map((i) => i.value)), baseY = padT + areaH;
  let out = `<line class="grid-line" x1="${padXL}" y1="${padT}" x2="${W - padXR}" y2="${padT}"/>`;
  out += `<text class="val-label" x="${padXL}" y="${padT - 5}" font-size="9">${num(maxV)} ${unit}</text>`;
  out += `<line class="grid-line" x1="${padXL}" y1="${baseY}" x2="${W - padXR}" y2="${baseY}"/>`;
  items.forEach((it, i) => {
    const bh = it.value > 0 ? Math.max(2, (it.value / maxV) * areaH) : 0;
    const x = padXL + i * slot + slot * 0.18, bw = slot * 0.64, y = baseY - bh;
    out += `<rect class="bar" x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${bh.toFixed(1)}" rx="2"><title>${esc(it.full)}: ${num(it.value)} ${unit}</title></rect>`;
    if (it.tick) {
      const lx = (padXL + i * slot + slot / 2).toFixed(1);
      out += angled
        ? `<text class="axis-label" x="${lx}" y="${baseY + 10}" text-anchor="end" font-size="9" transform="rotate(-42 ${lx} ${baseY + 10})">${esc(it.tick)}</text>`
        : `<text class="axis-label" x="${lx}" y="${H - 9}" text-anchor="middle" font-size="9">${esc(it.tick)}</text>`;
    }
  });
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMinYMid meet" role="img" aria-label="bar chart">${out}</svg>`;
}
function svgCalendar(perDay: Record<number, number>) {
  const cell = 13, gap = 3, padT = 4, padL = 4, weeks = 26;
  const today = startOfDay(new Date());
  let start = today - (weeks * 7 - 1) * DAY;
  start -= new Date(start).getDay() * DAY; // align to Sunday
  const cols = Math.floor((today - start) / (7 * DAY)) + 1;
  const W = padL + cols * (cell + gap), H = padT + 7 * (cell + gap);
  let cells = "";
  for (let c = 0; c < cols; c++) {
    for (let r = 0; r < 7; r++) {
      const t = start + (c * 7 + r) * DAY;
      if (t > today) continue;
      const v = perDay[t] || 0;
      const lvl = v === 0 ? 0 : v < 25 ? 1 : v < 60 ? 2 : v < 120 ? 3 : 4;
      cells += `<rect x="${padL + c * (cell + gap)}" y="${padT + r * (cell + gap)}" width="${cell}" height="${cell}" rx="3" class="cal-cell cal-l${lvl}"><title>${fmtDate(new Date(t).toISOString())}: ${num(v)} pages</title></rect>`;
    }
  }
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMinYMid meet" role="img" aria-label="reading calendar">${cells}</svg>`;
}

// ---------------------------------------------------------------------------
// Book detail + per-book progress chart
// ---------------------------------------------------------------------------
// Full-page book view. Opened by tapping a book card; the phone's back
// button/gesture returns to the list via the #book/<id> history entry.
// History calls are wrapped: they can throw in sandboxed/file:// contexts,
// and the page must still work without them (back button falls back).
let bookReturnView = "reading", bookReturnScroll = 0;
function histPushBook(id: string) {
  try { history.pushState({ bookId: id, fromApp: true }, "", "#book/" + id); return true; } catch (e: any) { return false; }
}
function histState() { try { return history.state; } catch (e: any) { return null; } }
function histCleanHash() {
  try { if (location.hash) history.replaceState(null, "", location.pathname + location.search); } catch (e: any) { /* sandboxed */ }
}
function openBookPage(book: Book, opts?: { returnView?: string; returnScroll?: number; push?: boolean; keepScroll?: boolean }) {
  opts = opts || {};
  currentDetailId = book.id;
  const read = pagesRead(book);
  const pct = book.totalPages ? Math.min(100, Math.round((read / book.totalPages) * 100)) : 0;
  const logs = book.logs.slice().sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
  const statusLabels = { want: "Want to read", reading: "Currently reading", finished: "Finished", dnf: "Did not finish" };
  const dates = book.status === "finished" ? (book.finishedAt ? "Finished " + fmtDate(book.finishedAt) : "")
    : book.status === "reading" ? (book.startedAt ? "Started " + fmtDate(book.startedAt) : "") : "";
  const meta = [];
  meta.push(`${FORMAT_ICON[book.format] || "📖"} ${statusLabels[book.status]}${book.rating ? " · " + starsHTML(book.rating) : ""}`);
  if (book.seriesName) meta.push(`📚 ${esc(book.seriesName)}${book.seriesNumber ? " #" + book.seriesNumber : ""}`);
  meta.push(`${num(read)}${book.totalPages ? " / " + num(book.totalPages) : ""} ${unitLabel(book)}${book.totalPages ? " · " + pct + "%" : ""}`);
  if (book.publishedYear) meta.push(`First published ${book.publishedYear}`);
  if (dates) meta.push(dates);
  if (book.readCount > 1) meta.push(`Read ${book.readCount}×`);
  if (book.expectation && book.rating) {
    const diff = book.rating - book.expectation;
    meta.push(`🔮 Expected ${starsHTML(book.expectation)} → got ${starsHTML(book.rating)} ${diff > 0 ? "— better than hoped!" : diff < 0 ? "— not quite what you hoped" : "— exactly as expected"}`);
  } else if (book.expectation) {
    meta.push(`🔮 Hoping for ${starsHTML(book.expectation)}`);
  }
  if (book.owned) meta.push(`🏠 On your home shelf`);
  if (book.lentTo) meta.push(`📤 With ${esc(book.lentTo)}${book.lentAt ? " since " + fmtDate(book.lentAt) : ""}`);
  if (book.loanDue) meta.push(loanBadgeHTML(book));
  if (book.bookmark) meta.push(`🔖 ${book.bookmark.page ? "p." + book.bookmark.page : "Bookmark"}${book.bookmark.note ? " — “" + esc(book.bookmark.note) + "”" : ""}`);

  const quotes = book.quotes || [];
  const journal = (book.journal || []).slice().sort((a, b2) => new Date(b2.date).getTime() - new Date(a.date).getTime());
  const chars = book.characters || [];
  const vocab = book.vocab || [];
  const history = (book.finishHistory || []).filter((f) => f.date);
  $("#detail-body").innerHTML = `
      <div class="detail-top">
        ${coverHTML(book)}
        <div class="detail-info">
          <h4>${esc(book.title)}</h4>
          <p class="by">${esc(book.author) || "Unknown author"}</p>
          <div class="detail-meta">${meta.map((m) => `<span>${m}</span>`).join("")}</div>
          ${chipsHTML(book, false)}
        </div>
      </div>
      <div class="detail-actions">
        ${book.status === "reading" ? `<button class="mini act-main" data-detail-action="log">＋ Log pages</button>
        <button class="mini" data-detail-action="bookmark">🔖 Bookmark</button>
        <button class="mini" data-detail-action="finish">✓ Finish</button>
        <button class="mini" data-detail-action="dnf">✕ DNF</button>` : ""}
        ${book.status === "want" ? `<button class="mini act-main" data-detail-action="start">▶ Start reading</button>` : ""}
        ${book.status === "finished" ? `<button class="mini act-main" data-detail-action="reread">🔁 Read again</button>
        <button class="mini" data-detail-action="rate">★ Rate</button>
        <button class="mini" data-detail-action="recommend">🌟 Recommend</button>` : ""}
        ${book.status === "dnf" ? `<button class="mini act-main" data-detail-action="start">▶ Pick it up again</button>` : ""}
        <button class="mini" data-detail-action="toggle-owned">${book.owned ? "🏠 On my shelf ✓" : "🏠 I own this"}</button>
        <button class="mini" data-detail-action="${book.lentTo ? "lend-return" : "lend"}">${book.lentTo ? "↩ Got it back" : "📤 Lend out"}</button>
        <button class="mini" data-detail-action="share-card">🖼 Share card</button>
        <button class="mini" data-detail-action="export-md">⬇ Journal .md</button>
        <button class="mini" data-detail-action="edit">✎ Edit</button>
        <button class="mini danger" data-detail-action="delete">🗑 Remove</button>
      </div>
      ${book.description ? `<div class="detail-section"><h5>About</h5><p class="detail-desc">${esc(book.description)}</p></div>` : ""}
      ${book.pickReason ? `<div class="detail-section"><h5>💭 Why I picked it up</h5><p class="detail-desc">${esc(book.pickReason)}</p></div>` : ""}
      ${book.dnfReason ? `<div class="detail-section"><h5>🚧 Why I set it aside</h5><p class="detail-desc">${esc(book.dnfReason)}</p></div>` : ""}
      <div class="detail-section">
        <h5>📈 Reading progress</h5>
        <div class="progress-chart">${svgProgress(book)}</div>
      </div>
      <div class="detail-section">
        <h5>📓 Journal (${journal.length})</h5>
        <div class="journal-list">${journal.map((j) => `<div class="journal-entry">
          <div class="j-entry-head"><span class="j-entry-date">${fmtDateTime(j.date)}${j.page ? ` · p.${j.page}` : ""}</span>
          <button class="icon-btn" data-detail-action="del-journal" data-id="${book.id}" data-journal="${j.id}" title="Delete entry">🗑</button></div>
          <p class="j-entry-text">${esc(j.text)}</p>
        </div>`).join("") || `<p class="muted">No entries yet — this is your diary for this book. Thoughts, theories, feelings…</p>`}</div>
        <form id="journal-form" class="quote-form">
          <textarea id="j-text" class="input" rows="2" placeholder="What's happening in the story? What do you think so far?"></textarea>
          <div class="quote-form-row">
            <input type="number" id="j-page" class="input" placeholder="Page #" min="0" max="100000" />
            <button type="submit" class="primary">Add entry</button>
          </div>
        </form>
      </div>
      <div class="detail-section">
        <h5>❝ Quotes &amp; highlights (${quotes.length})</h5>
        <div class="quote-list">${quotes.map((q) => `<div class="quote"><span class="quote-text">“${esc(q.text)}”${q.page ? ` <span class="muted">— p.${q.page}</span>` : ""}</span><button class="icon-btn" data-detail-action="del-quote" data-id="${book.id}" data-quote="${q.id}" title="Delete">🗑</button></div>`).join("") || `<p class="muted">No quotes yet — add a favourite line below.</p>`}</div>
        <form id="quote-form" class="quote-form">
          <textarea id="q-text" class="input" rows="2" placeholder="Paste a quote or highlight…"></textarea>
          <div class="quote-form-row">
            <input type="number" id="q-page" class="input" placeholder="Page #" min="0" max="100000" />
            <button type="submit" class="primary">Add quote</button>
          </div>
        </form>
      </div>
      <div class="detail-section">
        <h5>👥 Characters (${chars.length})</h5>
        <div class="kv-list">${chars.map((c) => `<div class="kv-row"><span class="kv-key">${esc(c.name)}</span><span class="kv-val">${esc(c.desc)}</span><button class="icon-btn" data-detail-action="del-char" data-id="${book.id}" data-char="${c.id}" title="Delete">🗑</button></div>`).join("") || `<p class="muted">Keep track of who's who — handy for big casts and long series.</p>`}</div>
        <form id="char-form" class="kv-form">
          <input type="text" id="char-name" class="input" placeholder="Name" required />
          <input type="text" id="char-desc" class="input" placeholder="Who are they? (your own words)" />
          <button type="submit" class="primary">Add</button>
        </form>
      </div>
      <div class="detail-section">
        <h5>🔤 Vocabulary (${vocab.length})</h5>
        <div class="kv-list">${vocab.map((v) => `<div class="kv-row"><span class="kv-key">${esc(v.word)}</span><span class="kv-val">${esc(v.def)}${v.page ? ` <span class="muted">— p.${v.page}</span>` : ""}</span><button class="icon-btn" data-detail-action="del-vocab" data-id="${book.id}" data-vocab="${v.id}" title="Delete">🗑</button></div>`).join("") || `<p class="muted">New words you met in this book, with what they mean.</p>`}</div>
        <form id="vocab-form" class="kv-form">
          <input type="text" id="vocab-word" class="input" placeholder="Word" required />
          <input type="text" id="vocab-def" class="input" placeholder="Meaning" />
          <input type="number" id="vocab-page" class="input kv-page" placeholder="p." min="0" max="100000" />
          <button type="submit" class="primary">Add</button>
        </form>
      </div>
      ${history.length ? `<div class="detail-section">
        <h5>🔁 Read history</h5>
        <div class="kv-list">${history.map((f, i) => `<div class="kv-row"><span class="kv-key">Read #${i + 1}</span><span class="kv-val">${fmtDate(f.date)}${f.rating ? " · " + starsHTML(f.rating) : ""}</span></div>`).join("")}</div>
      </div>` : ""}
      <div class="detail-section">
        <h5>Sessions (${book.logs.length})</h5>
        <div class="logs detail-logs">
          ${logs.length ? logs.map((l) => `<div class="log-row">
            <span class="l-pages">+${num(l.pages)}${unitShort(book)}</span>
            <span class="l-when">${fmtDateTime(l.date)}${l.minutes ? " · " + l.minutes + "m" : ""}</span>
            <span class="l-note">${l.mood ? l.mood + " " : ""}${l.note ? "“" + esc(l.note) + "”" : ""}</span>
            <span class="log-actions">
              <button data-detail-action="edit-log" data-log="${l.id}" title="Edit log">✎</button>
              <button data-detail-action="del-log" data-log="${l.id}" title="Delete log">🗑</button>
            </span>
          </div>`).join("") : `<p class="muted">No sessions logged yet.</p>`}
        </div>
        <button class="primary add-session" data-detail-action="log">＋ Log a session</button>
      </div>
      ${book.review ? `<div class="detail-section"><h5>My notes</h5><p class="detail-review">${esc(book.review)}</p></div>` : ""}`;
  if (activeView !== "book") { bookReturnView = activeView; bookReturnScroll = window.scrollY; }
  switchView("book");
  if (!opts.keepScroll) window.scrollTo(0, 0);
  if (opts.push !== false) {
    const st = histState();
    if (!(st && st.bookId === book.id)) histPushBook(book.id);
  }
}
function closeBookPage() {
  if (activeView !== "book") return;
  switchView(bookReturnView);
  // Restore where you were in the list. Double-rAF: iOS applies its own
  // (now-disabled) scroll handling on popstate a frame late, and the list
  // needs a layout pass before the offset exists.
  requestAnimationFrame(() => requestAnimationFrame(() => window.scrollTo(0, bookReturnScroll)));
}
function goBackFromBook() {
  // If we pushed the #book/<id> entry ourselves, real history.back() keeps
  // the phone's back gesture consistent; otherwise (opened from a direct
  // link) just close and clean the hash.
  const st = histState();
  if (st && st.fromApp) history.back();
  else { closeBookPage(); histCleanHash(); }
}
// Synchronous exit for flows that immediately navigate elsewhere (tag chips
// etc.) — closes the page now and cleans the URL without waiting on popstate.
function leaveBookPage() {
  if (activeView !== "book") return;
  closeBookPage();
  histCleanHash();
}
function refreshDetail() {
  if (!currentDetailId || activeView !== "book") return;
  const b = state.books.find((x) => x.id === currentDetailId);
  if (b) openBookPage(b, { push: false, keepScroll: true });
}
// A cumulative pages-over-time line only tells a story once there are a couple
// of days to plot; on day one it's a flat sliver pinned to the bottom of the
// box. Until then, show a clean progress meter toward the goal instead.
function progressMeter(book: Book, logs: ReadingLog[]) {
  const read = logs.reduce((s, l) => s + (Number(l.pages) || 0), 0);
  const total = book.totalPages || 0;
  const unit = unitLabel(book);
  const pct = total ? Math.max(0, Math.min(100, Math.round((read / total) * 100))) : 0;
  const left = total ? Math.max(0, total - read) : 0;
  const startedISO = book.startedAt || logs[0].date;
  const started = !isNaN(new Date(startedISO).getTime()) ? "started " + fmtDate(startedISO) : "";
  const head = total
    ? `<span>${num(read)} / ${num(total)} ${unit}</span><span>${pct}%</span>`
    : `<span>${num(read)} ${unit} read</span><span></span>`;
  const ticks = total ? [25, 50, 75].map((p) => `<span class="pm-tick" style="left:${p}%"></span>`).join("") : "";
  const sub = total
    ? `${num(left)} ${unit} to go${started ? " · " + started : ""}`
    : started;
  return `<div class="progress-meter">
      <div class="pm-head">${head}</div>
      <div class="progress pm-bar">${ticks}<span style="width:${pct}%"></span></div>
      ${sub ? `<p class="gm-sub">${sub}</p>` : ""}
      <p class="pm-note">Log a session on another day to chart your pace and a finish estimate.</p>
    </div>`;
}
function svgProgress(book: Book) {
  const logs = book.logs.slice().filter((l) => !isNaN(new Date(l.date).getTime())).sort((a, b) => new Date(a.date).getTime() - new Date(b.date).getTime());
  if (!logs.length) return `<p class="muted">No reading sessions yet — log some pages to see your progress.</p>`;
  const distinctDays = new Set(logs.map((l) => startOfDay(new Date(l.date)))).size;
  if (distinctDays < 2) return progressMeter(book, logs);
  const W = 520, H = 200, padL = 44, padR = 16, padT = 14, padB = 30;
  const aw = W - padL - padR, ah = H - padT - padB;
  let cum = 0;
  const pts = logs.map((l) => { cum += Number(l.pages) || 0; return { t: new Date(l.date).getTime(), y: cum, date: l.date }; });
  const total = book.totalPages || cum, maxY = Math.max(total, cum, 1);
  const t0 = pts[0].t, t1 = pts[pts.length - 1].t, span = t1 - t0;
  const xOf = (t: number, i: number) => span > 0 ? padL + ((t - t0) / span) * aw : padL + (pts.length === 1 ? aw : (i / (pts.length - 1)) * aw);
  const yOf = (v: number) => padT + ah - (v / maxY) * ah, baseY = padT + ah;
  const linePath = pts.map((p, i) => (i ? "L" : "M") + xOf(p.t, i).toFixed(1) + " " + yOf(p.y).toFixed(1)).join(" ");
  const areaPath = `M${xOf(pts[0].t, 0).toFixed(1)} ${baseY.toFixed(1)} ` + pts.map((p, i) => "L" + xOf(p.t, i).toFixed(1) + " " + yOf(p.y).toFixed(1)).join(" ") + ` L${xOf(t1, pts.length - 1).toFixed(1)} ${baseY.toFixed(1)} Z`;
  const dots = pts.map((p, i) => `<circle class="prog-dot" cx="${xOf(p.t, i).toFixed(1)}" cy="${yOf(p.y).toFixed(1)}" r="3.5"><title>${fmtDate(p.date)}: ${num(p.y)}${book.totalPages ? " / " + num(book.totalPages) : ""} ${unitLabel(book)}</title></circle>`).join("");
  let target = "";
  if (book.totalPages) {
    const ty = yOf(book.totalPages);
    target = `<line class="prog-target" x1="${padL}" y1="${ty.toFixed(1)}" x2="${W - padR}" y2="${ty.toFixed(1)}"/><text class="prog-axis" x="${W - padR}" y="${(ty - 4).toFixed(1)}" text-anchor="end" font-size="9">goal ${num(book.totalPages)}${unitShort(book)}</text>`;
  }
  const axis = `<line x1="${padL}" y1="${baseY}" x2="${W - padR}" y2="${baseY}" stroke="var(--line)" stroke-width="1"/>`
    + `<text class="prog-axis" x="${padL - 6}" y="${(padT + 4).toFixed(1)}" text-anchor="end" font-size="9">${num(maxY)}</text>`
    + `<text class="prog-axis" x="${padL - 6}" y="${baseY.toFixed(1)}" text-anchor="end" font-size="9">0</text>`
    + `<text class="prog-axis" x="${padL}" y="${H - 10}" font-size="9">${fmtDate(pts[0].date)}</text>`
    + (pts.length > 1 ? `<text class="prog-axis" x="${W - padR}" y="${H - 10}" text-anchor="end" font-size="9">${fmtDate(pts[pts.length - 1].date)}</text>` : "");
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="reading progress over time">${axis}${target}<path class="prog-area" d="${areaPath}"/><path class="prog-line" d="${linePath}"/>${dots}</svg>`;
}

// ---------------------------------------------------------------------------
// Year in Review
// ---------------------------------------------------------------------------
function openYearReview(year: number) {
  yearReviewYear = year;
  const finished = booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt!).getFullYear() === year);
  const pages = pagesReadInYear(year);
  const rated = finished.filter((b) => b.rating);
  const avg = rated.length ? (rated.reduce((s, b) => s + b.rating!, 0) / rated.length) : 0;
  const fav = rated.slice().sort((a, b) => (b.rating! - a.rating!) || (new Date(b.finishedAt!).getTime() - new Date(a.finishedAt!).getTime()))[0];
  const longest = finished.slice().sort((a, b) => (b.totalPages || 0) - (a.totalPages || 0))[0];
  const genres: Record<string, number> = {}; finished.forEach((b) => (b.tags || []).forEach((t) => genres[t] = (genres[t] || 0) + 1));
  const topGenre = Object.keys(genres).sort((a, b) => genres[b] - genres[a])[0];
  const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const monthCounts = new Array(12).fill(0); finished.forEach((b) => monthCounts[new Date(b.finishedAt!).getMonth()]++);
  const bestMonthIdx = monthCounts.indexOf(Math.max(...monthCounts));
  const daysThisYear = Array.from(readingDaySet()).filter((t) => new Date(t).getFullYear() === year).length;

  const tile = (n: number | string, l: string) => `<div class="yr-tile"><div class="yr-num">${n}</div><div class="yr-lbl">${l}</div></div>`;
  const hasData = finished.length || pages;
  $("#year-title").textContent = "🎉 " + year + " in Review";
  $("#year-body").innerHTML = `
      <div class="yr-nav">
        <button class="ghost" data-year-nav="${year - 1}">◀ ${year - 1}</button>
        <strong>${year}</strong>
        <button class="ghost" data-year-nav="${year + 1}"${year >= new Date().getFullYear() ? " disabled" : ""}>${year + 1} ▶</button>
      </div>
      ${hasData ? `
      <div class="yr-tiles">
        ${tile(num(finished.length), "books finished")}
        ${tile(num(pages), "pages read")}
        ${tile(daysThisYear ? num(daysThisYear) : "0", "days reading")}
        ${tile(avg ? avg.toFixed(1) + "★" : "—", "avg rating")}
        ${tile(topGenre ? esc(topGenre) : "—", "top genre")}
        ${tile(finished.length ? months[bestMonthIdx] : "—", "busiest month")}
      </div>
      ${fav ? `<div class="yr-highlight"><h5>⭐ Favourite read</h5><div class="yr-book">${coverHTML(fav)}<div><strong>${esc(fav.title)}</strong><br><span class="muted">${esc(fav.author)}</span><br>${starsHTML(fav.rating)}</div></div></div>` : ""}
      ${longest && longest !== fav ? `<div class="yr-highlight"><h5>📏 Longest book</h5><div class="yr-book">${coverHTML(longest)}<div><strong>${esc(longest.title)}</strong><br><span class="muted">${num(longest.totalPages)} pages</span></div></div></div>` : ""}
      <div class="yr-actions">
        <button class="ghost" data-yr-action="image" data-year="${year}">🖼 Save as image</button>
        <button class="ghost" data-yr-action="markdown" data-year="${year}">⬇ Export ${year} journal (.md)</button>
      </div>
      ` : `<p class="empty">No books finished in ${year} yet. Come back once you've read some!</p>`}`;
  showModal("year-modal");
}

// ---------------------------------------------------------------------------
// Keepsakes: downloads, markdown journals, shareable cards, monthly recap
// ---------------------------------------------------------------------------
function downloadFileBlob(name: string, blob: Blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = name; a.click();
  URL.revokeObjectURL(url);
}
function downloadText(name: string, text: string) { downloadFileBlob(name, new Blob([text], { type: "text/markdown;charset=utf-8" })); }
function slugify(s: unknown) { return String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60) || "book"; }
function appTitle() { return $("#app-title") ? $("#app-title").textContent : "Enkela's Bookshelf"; }

function bookMarkdown(b: Book) {
  const lines = [`# ${b.title}`, ""];
  if (b.author) lines.push(`*by ${b.author}*`, "");
  const meta = [];
  if (b.rating) meta.push(`Rating: ${fmtRating(b.rating)}★`);
  if (b.expectation) meta.push(`Expected: ${fmtRating(b.expectation)}★`);
  if (b.status === "finished" && b.finishedAt) meta.push(`Finished: ${fmtDate(b.finishedAt)}`);
  if (b.readCount > 1) meta.push(`Read ${b.readCount}×`);
  if (b.totalPages) meta.push(`${num(b.totalPages)} ${unitLabel(b)}`);
  if (b.seriesName) meta.push(`${b.seriesName}${b.seriesNumber ? " #" + b.seriesNumber : ""}`);
  if (meta.length) lines.push(meta.join(" · "), "");
  if (b.pickReason) lines.push(`## Why I picked it up`, "", b.pickReason, "");
  if (b.review) lines.push(`## My review`, "", b.review, "");
  if (b.dnfReason) lines.push(`## Why I set it aside`, "", b.dnfReason, "");
  if ((b.journal || []).length) {
    lines.push(`## Journal`, "");
    b.journal.slice().sort((x, y) => new Date(x.date).getTime() - new Date(y.date).getTime())
      .forEach((j) => lines.push(`- **${fmtDate(j.date)}**${j.page ? ` (p.${j.page})` : ""} — ${j.text}`));
    lines.push("");
  }
  if ((b.quotes || []).length) {
    lines.push(`## Quotes & highlights`, "");
    b.quotes.forEach((q) => lines.push(`> ${q.text}${q.page ? ` — p.${q.page}` : ""}`, ""));
  }
  if ((b.characters || []).length) {
    lines.push(`## Characters`, "");
    b.characters.forEach((c) => lines.push(`- **${c.name}**${c.desc ? ` — ${c.desc}` : ""}`));
    lines.push("");
  }
  if ((b.vocab || []).length) {
    lines.push(`## Vocabulary`, "");
    b.vocab.forEach((v) => lines.push(`- **${v.word}**${v.page ? ` (p.${v.page})` : ""}${v.def ? ` — ${v.def}` : ""}`));
    lines.push("");
  }
  if (b.logs.length) {
    lines.push(`## Reading sessions`, "");
    b.logs.slice().sort((x, y) => new Date(x.date).getTime() - new Date(y.date).getTime())
      .forEach((l) => lines.push(`- ${fmtDateTime(l.date)}: ${num(l.pages)} ${unitLabel(b)}${l.minutes ? `, ${l.minutes} min` : ""}${l.mood ? " " + l.mood : ""}${l.note ? ` — “${l.note}”` : ""}`));
    lines.push("");
  }
  lines.push("---", `*Exported from ${appTitle()} on ${fmtDate(new Date().toISOString())}*`);
  return lines.join("\n");
}
function yearMarkdown(year: number) {
  const finished = booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt!).getFullYear() === year)
    .sort((a, b) => new Date(a.finishedAt!).getTime() - new Date(b.finishedAt!).getTime());
  const lines = [`# My ${year} in books`, "", `${finished.length} books · ${num(pagesReadInYear(year))} pages`, ""];
  finished.forEach((b) => {
    lines.push(`## ${b.title}${b.author ? ` — ${b.author}` : ""}`, "");
    const meta = [`Finished ${fmtDate(b.finishedAt)}`];
    if (b.rating) meta.push(`${fmtRating(b.rating)}★`);
    lines.push(meta.join(" · "), "");
    if (b.review) lines.push(b.review, "");
    (b.quotes || []).slice(0, 3).forEach((q) => lines.push(`> ${q.text}${q.page ? ` — p.${q.page}` : ""}`, ""));
  });
  lines.push("---", `*Exported from ${appTitle()}*`);
  return lines.join("\n");
}

// --- Shareable card images (canvas → PNG download) ---
function loadImage(url: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = "anonymous";
    img.onload = () => resolve(img);
    img.onerror = reject;
    img.src = url;
  });
}
function wrapText(ctx: CanvasRenderingContext2D, text: string, x: number, y: number, maxW: number, lh: number, maxLines: number) {
  const words = String(text).split(/\s+/);
  let line = "", lines = 0;
  for (let i = 0; i < words.length; i++) {
    const test = line ? line + " " + words[i] : words[i];
    if (ctx.measureText(test).width > maxW && line) {
      if (lines + 1 >= maxLines) { ctx.fillText(line.replace(/.{3}$/, "") + "…", x, y); return y + lh; }
      ctx.fillText(line, x, y); y += lh; lines++; line = words[i];
    } else line = test;
  }
  if (line) { ctx.fillText(line, x, y); y += lh; }
  return y;
}
function drawStars(ctx: CanvasRenderingContext2D, rating: number, x: number, y: number, size: number) {
  ctx.font = `${size}px serif`;
  for (let i = 1; i <= 5; i++) {
    const sx = x + (i - 1) * (size + 6);
    ctx.fillStyle = rating >= i - 0.5 ? "#c98a4b" : "#e7d3bd";
    ctx.fillText("★", sx, y);
    if (rating >= i - 0.5 && rating < i) {
      // half star: repaint the right half in the soft colour
      ctx.save();
      ctx.beginPath();
      ctx.rect(sx + size / 2, y - size, size / 2 + 4, size * 1.3);
      ctx.clip();
      ctx.fillStyle = "#e7d3bd";
      ctx.fillText("★", sx, y);
      ctx.restore();
    }
  }
}
async function shareBookCard(b: Book) {
  const W = 1000, H = 1400;
  const cv = document.createElement("canvas");
  cv.width = W; cv.height = H;
  const ctx = cv.getContext("2d")!;
  const g = ctx.createLinearGradient(0, 0, 0, H);
  g.addColorStop(0, "#fbf7ef"); g.addColorStop(1, "#efe2ca");
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  ctx.strokeStyle = "#c98a4b"; ctx.lineWidth = 5; ctx.strokeRect(42, 42, W - 84, H - 84);
  ctx.strokeStyle = "rgba(201,138,75,.45)"; ctx.lineWidth = 1.5; ctx.strokeRect(56, 56, W - 112, H - 112);
  const cw = 320, ch = 470, cx = (W - cw) / 2, cy = 110;
  let drewCover = false;
  if (b.coverUrl) {
    try {
      const img = await loadImage(b.coverUrl);
      ctx.save();
      ctx.shadowColor = "rgba(60,40,20,.4)"; ctx.shadowBlur = 34; ctx.shadowOffsetY = 14;
      ctx.drawImage(img, cx, cy, cw, ch);
      ctx.restore();
      drewCover = true;
    } catch (e: any) { /* CORS or broken cover — fall back */ }
  }
  if (!drewCover) {
    const hue = hashHue(b.title + b.author);
    ctx.save();
    ctx.shadowColor = "rgba(60,40,20,.4)"; ctx.shadowBlur = 34; ctx.shadowOffsetY = 14;
    ctx.fillStyle = `hsl(${hue}, 38%, 42%)`;
    ctx.fillRect(cx, cy, cw, ch);
    ctx.restore();
    ctx.fillStyle = "rgba(255,255,255,.92)";
    ctx.font = "italic 30px Georgia, serif";
    ctx.textAlign = "center";
    wrapText(ctx, b.title, cx + cw / 2, cy + ch / 2 - 20, cw - 60, 38, 5);
    ctx.textAlign = "left";
  }
  let y = cy + ch + 90;
  ctx.textAlign = "center";
  ctx.fillStyle = "#2c2722";
  ctx.font = "600 52px Georgia, serif";
  y = wrapText(ctx, b.title, W / 2, y, W - 220, 60, 2);
  if (b.author) {
    ctx.fillStyle = "#6b6258";
    ctx.font = "italic 32px Georgia, serif";
    ctx.fillText("by " + b.author, W / 2, y + 8); y += 56;
  }
  if (b.rating) {
    ctx.textAlign = "left";
    const sw = 5 * 52 + 4 * 6;
    drawStars(ctx, b.rating, (W - sw) / 2, y + 40, 52);
    y += 80;
    ctx.textAlign = "center";
  }
  ctx.fillStyle = "#6b6258";
  ctx.font = "26px Georgia, serif";
  const bits = [];
  if (b.status === "finished" && b.finishedAt) bits.push("Finished " + fmtDate(b.finishedAt));
  if (b.totalPages) bits.push(num(b.totalPages) + " " + unitLabel(b));
  if (b.readCount > 1) bits.push("read " + b.readCount + "×");
  if (bits.length) { ctx.fillText(bits.join("  ·  "), W / 2, y + 16); y += 60; }
  const quote = (b.quotes || [])[0];
  if (quote && y < H - 300) {
    ctx.fillStyle = "#9c5b3a";
    ctx.font = "72px Georgia, serif";
    ctx.fillText("“", W / 2, y + 60);
    ctx.fillStyle = "#4a4238";
    ctx.font = "italic 30px Georgia, serif";
    y = wrapText(ctx, quote.text, W / 2, y + 100, W - 260, 42, 4) + 10;
  }
  ctx.fillStyle = "#9c5b3a";
  ctx.font = "600 26px Georgia, serif";
  ctx.fillText("📚 " + appTitle(), W / 2, H - 90);
  try {
    cv.toBlob((blob) => {
      if (!blob) { toast("⚠️", "Couldn't create the card", "The cover image blocked export — try removing it."); return; }
      downloadFileBlob(slugify(b.title) + "-card.png", blob);
      toast("🖼", "Book card saved", "A shareable image of “" + b.title + "”");
    }, "image/png");
  } catch (e: any) {
    toast("⚠️", "Couldn't create the card", "The cover image blocked export.");
  }
}
// "My reading right now" keepsake — a shareable snapshot of the whole shelf.
async function shareSnapshotCard() {
  const W = 1000, H = 1000;
  const cv = document.createElement("canvas"); cv.width = W; cv.height = H;
  const ctx = cv.getContext("2d")!;
  const g = ctx.createLinearGradient(0, 0, 0, H); g.addColorStop(0, "#fbf7ef"); g.addColorStop(1, "#efe2ca");
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  ctx.strokeStyle = "#c98a4b"; ctx.lineWidth = 5; ctx.strokeRect(42, 42, W - 84, H - 84);
  ctx.textAlign = "center";
  ctx.fillStyle = "#9c5b3a"; ctx.font = "600 46px Georgia, serif"; ctx.fillText("📚 " + appTitle(), W / 2, 135);
  ctx.fillStyle = "#6b6258"; ctx.font = "italic 30px Georgia, serif"; ctx.fillText("My reading, right now", W / 2, 185);
  const streak = readingStreak();
  const stats = [
    [num(booksFinished().length), "books read"],
    [num(totalPagesRead()), "pages"],
    [num(state.books.filter((b) => b.status === "reading").length), "reading now"],
    [num(streak.current), "day streak"],
    [num(state.books.filter((b) => b.owned).length), "owned"],
    [num(state.books.filter((b) => b.status === "want").length), "on the list"],
  ];
  const cols = 2, cellW = (W - 160) / cols, startX = 80, startY = 320, rowH = 200;
  stats.forEach((s, i) => {
    const cxp = startX + (i % cols) * cellW + cellW / 2;
    const cyp = startY + Math.floor(i / cols) * rowH;
    ctx.fillStyle = "#9c5b3a"; ctx.font = "700 76px Georgia, serif"; ctx.fillText(s[0], cxp, cyp);
    ctx.fillStyle = "#6b6258"; ctx.font = "26px Georgia, serif"; ctx.fillText(s[1], cxp, cyp + 42);
  });
  const genre: Record<string, number> = {}; booksFinished().forEach((b) => (b.tags || []).forEach((t) => { genre[t] = (genre[t] || 0) + 1; }));
  const top = Object.keys(genre).sort((a, b) => genre[b] - genre[a])[0];
  if (top) { ctx.fillStyle = "#4a4238"; ctx.font = "italic 30px Georgia, serif"; ctx.fillText("Favourite genre: " + top, W / 2, H - 135); }
  ctx.fillStyle = "#9c5b3a"; ctx.font = "600 24px Georgia, serif"; ctx.fillText(new Date().toLocaleDateString(undefined, { month: "long", day: "numeric", year: "numeric" }), W / 2, H - 85);
  ctx.textAlign = "left";
  try {
    cv.toBlob((blob) => {
      if (!blob) { toast("⚠️", "Couldn't create the card", ""); return; }
      downloadFileBlob("my-reading-snapshot.png", blob);
      toast("📸", "Snapshot saved", "A shareable picture of your reading right now");
    }, "image/png");
  } catch (e: any) { toast("⚠️", "Couldn't create the card", ""); }
}
async function shareYearCard(year: number) {
  const finished = booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt!).getFullYear() === year);
  const pages = pagesReadInYear(year);
  const rated = finished.filter((b) => b.rating);
  const avg = rated.length ? (rated.reduce((s, b) => s + b.rating!, 0) / rated.length) : 0;
  const genres: Record<string, number> = {};
  finished.forEach((b) => (b.tags || []).forEach((t) => genres[t] = (genres[t] || 0) + 1));
  const topGenre = Object.keys(genres).sort((a, b) => genres[b] - genres[a])[0];
  const daysThisYear = Array.from(readingDaySet()).filter((t) => new Date(t).getFullYear() === year).length;
  const W = 1080, H = 1080;
  const cv = document.createElement("canvas");
  cv.width = W; cv.height = H;
  const ctx = cv.getContext("2d")!;
  const g = ctx.createLinearGradient(0, 0, W, H);
  g.addColorStop(0, "#9c5b3a"); g.addColorStop(1, "#c98a4b");
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = "rgba(255,255,255,.12)";
  for (let i = 0; i < 14; i++) { const bw = 46 + (i * 37) % 40; ctx.fillRect(60 + i * 70, H - 210, bw * 0.55, 150 + (i * 53) % 50); }
  ctx.fillStyle = "#fff";
  ctx.textAlign = "center";
  ctx.font = "600 72px Georgia, serif";
  ctx.fillText(year + " in Books", W / 2, 150);
  ctx.font = "30px Georgia, serif";
  ctx.fillText(appTitle(), W / 2, 205);
  const tiles = [
    [num(finished.length), "books finished"],
    [num(pages), "pages read"],
    [num(daysThisYear), "days reading"],
    [avg ? avg.toFixed(1) + "★" : "—", "average rating"],
    [topGenre || "—", "top genre"],
    [num(readingStreak().longest), "longest streak"],
  ];
  tiles.forEach(([v, l], i) => {
    const col = i % 2, row = Math.floor(i / 2);
    const x = W / 4 + col * (W / 2), y = 330 + row * 170;
    ctx.font = "600 62px Georgia, serif";
    ctx.fillText(String(v).length > 14 ? String(v).slice(0, 13) + "…" : String(v), x, y);
    ctx.font = "24px Georgia, serif";
    ctx.globalAlpha = .85;
    ctx.fillText(l.toUpperCase(), x, y + 42);
    ctx.globalAlpha = 1;
  });
  cv.toBlob((blob) => {
    if (!blob) return;
    downloadFileBlob("year-in-books-" + year + ".png", blob);
    toast("🖼", "Year card saved", year + " recap as an image");
  }, "image/png");
}

// --- Monthly wrap-up ---
function monthLogs(y: number, m: number) {
  const logs: { d: Date; pages: number; minutes: number }[] = [];
  state.books.forEach((b) => b.logs.forEach((l) => {
    const d = new Date(l.date);
    if (!isNaN(d.getTime()) && d.getFullYear() === y && d.getMonth() === m) logs.push({ d, pages: Number(l.pages) || 0, minutes: Number(l.minutes) || 0 });
  }));
  return logs;
}
function openMonthlyRecap(y: number, m: number) {
  const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const logs = monthLogs(y, m);
  const finished = booksFinished().filter((b) => { const d = new Date(b.finishedAt!); return b.finishedAt && d.getFullYear() === y && d.getMonth() === m; });
  const pages = logs.reduce((s, l) => s + l.pages, 0);
  const minutes = logs.reduce((s, l) => s + l.minutes, 0);
  const days = new Set(logs.map((l) => startOfDay(l.d))).size;
  const perDay: Record<number, number> = {};
  logs.forEach((l) => { const k = startOfDay(l.d); perDay[k] = (perDay[k] || 0) + l.pages; });
  const best = Object.values(perDay).reduce((mx, v) => Math.max(mx, v), 0);
  const genres: Record<string, number> = {};
  finished.forEach((b) => (b.tags || []).forEach((t) => genres[t] = (genres[t] || 0) + 1));
  const topGenre = Object.keys(genres).sort((a, b) => genres[b] - genres[a])[0];
  const now = new Date();
  const isCurrent = y === now.getFullYear() && m === now.getMonth();
  const prev = new Date(y, m - 1, 1), next = new Date(y, m + 1, 1);
  const tile = (n: number | string, l: string) => `<div class="yr-tile"><div class="yr-num">${n}</div><div class="yr-lbl">${l}</div></div>`;
  $("#month-title").textContent = "📅 " + MONTHS[m] + " " + y;
  $("#month-body").innerHTML = `
      <div class="yr-nav">
        <button class="ghost" data-month-nav="${prev.getFullYear()}-${prev.getMonth()}">◀ ${MONTHS[prev.getMonth()]}</button>
        <strong>${MONTHS[m]} ${y}</strong>
        <button class="ghost" data-month-nav="${next.getFullYear()}-${next.getMonth()}"${isCurrent ? " disabled" : ""}>${MONTHS[next.getMonth()]} ▶</button>
      </div>
      ${(logs.length || finished.length) ? `
      <div class="yr-tiles">
        ${tile(num(finished.length), "books finished")}
        ${tile(num(pages), "pages read")}
        ${tile(minutes ? num(minutes) + "m" : "—", "time logged")}
        ${tile(num(days), "days reading")}
        ${tile(num(best), "best day (pages)")}
        ${tile(topGenre ? esc(topGenre) : "—", "top genre")}
      </div>
      ${finished.length ? `<div class="yr-highlight"><h5>Finished this month</h5>${finished.map((b) => `<div class="yr-book">${coverHTML(b)}<div><strong>${esc(b.title)}</strong><br><span class="muted">${esc(b.author)}</span>${b.rating ? "<br>" + starsHTML(b.rating) : ""}</div></div>`).join("")}</div>` : ""}
      ` : `<p class="empty">No reading logged in ${MONTHS[m]} ${y}.</p>`}`;
  showModal("month-modal");
}
function maybeShowMonthlyRecap() {
  const curMonth = new Date().toISOString().slice(0, 7);
  let lastSeen = null;
  try { lastSeen = localStorage.getItem("enkelas-last-recap"); } catch (e: any) { /* ignore */ }
  try { localStorage.setItem("enkelas-last-recap", curMonth); } catch (e: any) { /* ignore */ }
  if (!lastSeen || lastSeen === curMonth) return;
  const prev = new Date(); prev.setDate(1); prev.setMonth(prev.getMonth() - 1);
  if (monthLogs(prev.getFullYear(), prev.getMonth()).length) {
    setTimeout(() => { openMonthlyRecap(prev.getFullYear(), prev.getMonth()); toast("📅", "Your month in books", "Here's your " + prev.toLocaleDateString(undefined, { month: "long" }) + " recap!"); }, 900);
  }
}

// ---------------------------------------------------------------------------
// Journey timeline — your whole reading life as one scrolling story
// ---------------------------------------------------------------------------
function journeyEvents() {
  const ev: { t: string | null; icon: string; title: string; sub: string; id: string }[] = [];
  state.books.forEach((b) => {
    if (b.addedAt) ev.push({ t: b.addedAt, icon: "➕", title: `Added “${b.title}”`, sub: b.pickReason ? "💭 " + b.pickReason : "", id: b.id });
    if (b.startedAt && b.status !== "want") ev.push({ t: b.startedAt, icon: "▶️", title: `Started “${b.title}”`, sub: "", id: b.id });
    b.logs.forEach((l) => ev.push({
      t: l.date, icon: "📖",
      title: `Read ${num(l.pages)} ${unitLabel(b)} of “${b.title}”`,
      sub: [l.mood, l.minutes ? l.minutes + " min" : "", l.note ? "“" + l.note + "”" : ""].filter(Boolean).join(" · "),
      id: b.id,
    }));
    (b.journal || []).forEach((j) => ev.push({ t: j.date, icon: "📓", title: `Journal — “${b.title}”`, sub: (j.page ? "p." + j.page + " · " : "") + j.text, id: b.id }));
    (b.quotes || []).forEach((q) => { if (q.at) ev.push({ t: q.at, icon: "❝", title: `Saved a quote from “${b.title}”`, sub: "“" + q.text + "”", id: b.id }); });
    const history = (b.finishHistory || []).filter((f) => f.date);
    history.forEach((f, i) => ev.push({ t: f.date, icon: "🏁", title: (i > 0 ? "Re-read" : "Finished") + ` “${b.title}”`, sub: f.rating ? "Rated " + fmtRating(f.rating) + "★" : "", id: b.id }));
    if (b.status === "finished" && b.finishedAt && !history.length) ev.push({ t: b.finishedAt, icon: "🏁", title: `Finished “${b.title}”`, sub: b.rating ? "Rated " + fmtRating(b.rating) + "★" : "", id: b.id });
    if (b.status === "dnf" && b.finishedAt) ev.push({ t: b.finishedAt, icon: "🚧", title: `Set aside “${b.title}”`, sub: b.dnfReason ? "“" + b.dnfReason + "”" : "", id: b.id });
  });
  return ev.filter((e) => e.t && !isNaN(new Date(e.t!).getTime())).sort((a, b) => new Date(b.t!).getTime() - new Date(a.t!).getTime());
}
function ownedCardHTML(b: Book) {
  const statusLabels = { want: "📌 Want to read", reading: "📖 Reading now", finished: "✓ Read", dnf: "✕ Set aside" };
  return `<article class="book-card lib-card" data-id="${b.id}">
      ${coverHTML(b)}
      <h3 class="book-title">${fmtIcon(b)}${esc(b.title)}</h3>
      <p class="book-author">${esc(b.author) || "Unknown author"}${seriesLabel(b)}</p>
      <p class="lib-date">${statusLabels[b.status] || ""} ${lentBadgeHTML(b)}</p>
      ${b.location ? `<p class="own-loc">📍 ${esc(b.location)}</p>` : ""}
    </article>`;
}
function renderOwned() {
  const owned = state.books.filter((b) => b.owned);
  const q = ownedQuery;
  // Personal library map: filter by where the book physically lives.
  const locs = allLocations();
  const locSel = $<HTMLSelectElement>("#owned-location");
  if (locSel) {
    locSel.hidden = locs.length === 0;
    if (ownedLocation && !locs.some((l) => l.toLowerCase() === ownedLocation.toLowerCase())) ownedLocation = "";
    locSel.innerHTML = `<option value="">📍 Anywhere</option>` + locs.map((l) => `<option value="${esc(l)}">📍 ${esc(l)}</option>`).join("");
    locSel.value = ownedLocation;
  }
  // "Bought but haven't touched" — owned, not started, nothing logged.
  const isUnread = (b: Book) => b.status !== "finished" && b.status !== "dnf" && pagesRead(b) === 0;
  const unreadCount = owned.filter(isUnread).length;
  const ub = $<HTMLButtonElement>("#owned-unread-btn");
  if (ub) {
    ub.hidden = owned.length === 0;
    ub.setAttribute("aria-pressed", ownedUnreadOnly ? "true" : "false");
    ub.classList.toggle("active", ownedUnreadOnly);
    ub.textContent = ownedUnreadOnly ? "📖 Unread only ✓" : `📖 Unread (${unreadCount})`;
  }
  const list = owned
    .filter((b) => bookMatches(b, q))
    .filter((b) => !ownedLocation || (b.location || "").toLowerCase() === ownedLocation.toLowerCase())
    .filter((b) => !ownedUnreadOnly || isUnread(b))
    .sort((a, b) => a.title.localeCompare(b.title));
  // While searching, also surface books she KNOWS but doesn't own — read via
  // library, ebooks, wishlist — so "have I read this?" is answered in the shop too.
  const elsewhere = q ? state.books.filter((b) => !b.owned && bookMatches(b, q)).sort((a, b) => a.title.localeCompare(b.title)) : [];
  const fmtCounts = { physical: 0, ebook: 0, audio: 0 };
  owned.forEach((b) => { fmtCounts[b.format] = (fmtCounts[b.format] || 0) + 1; });
  const parts = [];
  if (fmtCounts.physical) parts.push(`${num(fmtCounts.physical)} physical`);
  if (fmtCounts.ebook) parts.push(`${num(fmtCounts.ebook)} e-book${fmtCounts.ebook === 1 ? "" : "s"}`);
  if (fmtCounts.audio) parts.push(`${num(fmtCounts.audio)} audiobook${fmtCounts.audio === 1 ? "" : "s"}`);
  if (unreadCount) parts.push(`${num(unreadCount)} unread`);
  $("#owned-count").textContent = owned.length
    ? `You own ${num(owned.length)} book${owned.length === 1 ? "" : "s"}${parts.length ? " · " + parts.join(" · ") : ""}`
    : "";
  const lent = state.books.filter((b) => b.lentTo).sort((a, b) => new Date(a.lentAt || 0).getTime() - new Date(b.lentAt || 0).getTime());
  $("#owned-lent-wrap").hidden = !(lent.length && !q);
  $("#owned-lent").innerHTML = lent.map(ownedCardHTML).join("");
  const filtering = q || ownedLocation || ownedUnreadOnly;
  $("#owned-results-h").hidden = !filtering;
  $("#owned-results-h").textContent = filtering ? `On your shelf (${list.length})` : "";
  $("#owned-list").innerHTML = list.map(ownedCardHTML).join("");
  $("#owned-elsewhere-wrap").hidden = elsewhere.length === 0;
  $("#owned-elsewhere").innerHTML = elsewhere.map(ownedCardHTML).join("");
  const empty = $("#owned-empty");
  if (owned.length === 0 && !q) {
    empty.hidden = false;
    empty.textContent = "Nothing marked as owned yet. Open any book and tap “🏠 I own this”, or tick the checkbox when adding a book — then this shelf travels with you to the bookshop.";
  } else if (list.length === 0 && elsewhere.length === 0) {
    empty.hidden = false;
    empty.textContent = q ? "No book like that on your shelves — looks safe to buy!" : "Nothing on your shelf matches those filters.";
  } else empty.hidden = true;
}
function renderJourney() {
  const el = $("#journey-feed");
  if (!el) return;
  const ev = journeyEvents();
  $("#journey-empty").hidden = ev.length > 0;
  const MAX = 200;
  let lastDay = "", lastMonth = "";
  el.innerHTML = ev.slice(0, MAX).map((e) => {
    const d = new Date(e.t!);
    const month = isNaN(d.getTime()) ? "" : d.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    const monthHead = month && month !== lastMonth ? `<div class="j-month">${month}</div>` : "";
    lastMonth = month;
    const day = fmtDate(e.t);
    const head = day !== lastDay ? `<div class="j-day">${day}</div>` : "";
    lastDay = day;
    return monthHead + head + `<button class="j-event" data-action="detail" data-id="${e.id}">

        <span class="j-icon">${e.icon}</span>
        <span class="j-body"><span class="j-title">${esc(e.title)}</span>${e.sub ? `<span class="j-sub">${esc(e.sub)}</span>` : ""}</span>
        <span class="j-time">${new Date(e.t!).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}</span>
      </button>`;
  }).join("") + (ev.length > MAX ? `<p class="muted j-more">Showing the latest ${MAX} of ${num(ev.length)} moments.</p>` : "");
}

function renderStorageStatus() {
  const el = $("#storage-status");
  if (!el) return;
  if (syncEnabled() && auth && auth.user) {
    const last = relTimeShort(loadLastSync());
    let txt, note;
    if (syncStatus === "syncing") { txt = "☁️ Syncing…"; note = "Saving your latest changes to your account."; }
    else if (syncStatus === "offline") { txt = "📴 Offline"; note = "You're offline — changes are saved on this device and will sync when you're back."; }
    else if (syncStatus === "error") { txt = "⚠️ Sync paused"; note = "Couldn't reach your account — changes are safe on this device and will retry."; }
    else { txt = "☁️ Synced" + (last ? " · " + last : ""); note = "Your books sync privately to your account (" + auth.user.email + ")."; }
    el.textContent = txt;
    el.title = note + " Tap for settings.";
    return;
  }
  if (syncEnabled() && syncStatus === "needslogin") {
    el.textContent = "🔑 Sign in to sync";
    el.title = "Your session expired — sign in again to resume syncing. Tap for settings.";
    return;
  }
  if (fileHandle) { el.textContent = "💾 synced to file"; el.title = "Changes are written to your connected JSON file. Tap for settings."; return; }
  const lock = storagePersisted ? " 🔒" : "";
  el.textContent = (supportsFS ? "💾 saved in this browser" : "💾 saved on this device") + lock;
  el.title = (storagePersisted ? "Your data is stored persistently and won't be auto-cleared by the browser."
    : "Saved locally in this browser. Tip: add to your home screen, and export a backup now and then.") + " Tap for settings.";
}

// ---------------------------------------------------------------------------
// Settings / Data Safety
// ---------------------------------------------------------------------------
function syncBadgeText() {
  if (!syncEnabled()) return "💾 Saved on this device";
  if (!auth || !auth.user) return "💾 Saved on this device (not signed in)";
  if (syncStatus === "syncing") return "☁️ Syncing…";
  if (syncStatus === "offline") return "📴 Offline — saved on this device";
  if (syncStatus === "error") return "⚠️ Sync paused — saved on this device";
  if (syncStatus === "needslogin") return "🔑 Session expired";
  return "☁️ Synced to your account";
}
function renderSettings() {
  const acct = $("#settings-account");
  if (!acct) return;
  const actions = $("#settings-account-actions");
  if (syncEnabled() && auth && auth.user) {
    acct.textContent = "Signed in as " + auth.user.fullName + " (" + auth.user.email + ")";
    actions.innerHTML = '<button class="ghost" data-settings-action="syncnow">🔄 Sync now</button>'
      + '<button class="ghost danger" data-settings-action="signout">Sign out</button>';
  } else if (syncEnabled()) {
    acct.textContent = "Not signed in — your books are saved only on this device.";
    actions.innerHTML = '<button class="primary" data-settings-action="signin">👤 Sign in to sync</button>';
  } else {
    acct.textContent = "Your books are saved locally on this device.";
    actions.innerHTML = "";
  }
  $("#settings-sync-badge").textContent = syncBadgeText();
  const last = loadLastSync();
  $("#settings-last-sync").textContent = (syncEnabled() && auth && auth.user)
    ? (last ? "Last synced " + relTimeLong(last) : "Not synced yet")
    : "";
  $("#settings-version").textContent = "Enkela's Bookshelf · version " + APP_VERSION;
  renderBackupHealth();
}
// A tiny at-a-glance "is my data safe?" panel: what's here, when it was last
// backed up, whether the browser promised to keep it.
function renderBackupHealth() {
  const box = $("#backup-health");
  if (!box) return;
  const logs = state.books.reduce((n, b) => n + (b.logs || []).length, 0);
  const lastX = loadLastExport();
  const days = lastX ? Math.floor((Date.now() - new Date(lastX).getTime()) / DAY) : null;
  const stale = lastX === null || days! > 30;
  const rows = [
    `<div class="bh-row"><span>📚</span><span>${state.books.length} book${state.books.length === 1 ? "" : "s"} · ${num(logs)} reading session${logs === 1 ? "" : "s"} on this device</span></div>`,
    `<div class="bh-row${stale ? " warn" : ""}"><span>🛟</span><span>Last backup export: <strong>${lastX ? relTimeLong(lastX) : "never"}</strong>${stale ? " — a fresh one wouldn't hurt" : ""}</span></div>`,
    `<div class="bh-row" id="bh-persist"><span>🔒</span><span>Checking storage protection…</span></div>`,
    `<div class="bh-row" id="bh-epubs" hidden><span>📕</span><span></span></div>`,
  ];
  box.innerHTML = rows.join("");
  if (navigator.storage && navigator.storage.persisted) {
    navigator.storage.persisted().then((p) => {
      const el = $("#bh-persist");
      if (el) el.innerHTML = `<span>${p ? "🔒" : "⚠️"}</span><span>${p ? "The browser granted persistent storage — it won't auto-clear your data." : "Storage isn't marked persistent yet — installing the app (Add to Home Screen) protects it."}</span>`;
    }).catch(() => { const el = $("#bh-persist"); if (el) el.hidden = true; });
  } else { const el = $("#bh-persist"); if (el) el.hidden = true; }
  if (EReader && EReader.exportAll) {
    EReader.exportAll().then((recs) => {
      const el = $("#bh-epubs");
      if (!el || !recs.length) return;
      const bytes = recs.reduce((n, r) => n + ((r.data && r.data.byteLength) || 0), 0);
      const size = bytes >= 1024 * 1024 ? (bytes / (1024 * 1024)).toFixed(1) + " MB" : Math.max(1, Math.round(bytes / 1024)) + " KB";
      el.hidden = false;
      el.lastElementChild!.textContent = recs.length + " ePub" + (recs.length === 1 ? "" : "s") + " in the eReader (" + size + ") — only “Export everything” includes these.";
    }).catch(() => { /* ignore */ });
  }
}
function openConflicts() {
  const body = $("#conflicts-body");
  const log = loadConflictLog();
  body.innerHTML = log.length
    ? `<p class="muted">When two devices change the bookshelf at the same time, you pick a winner. Every time that happened is listed here.</p>`
      + log.map((c: any) => `<div class="conflict-row"><strong>${esc(relTimeLong(c.at))}</strong> · during ${esc(c.where)} → ${esc(c.choice)} <span class="muted">(${c.books} books after)</span></div>`).join("")
    : `<p class="empty">No sync conflicts so far — every change has merged cleanly. 🎉</p>`;
  showModal("conflicts-modal");
}
// A gentle, throttled nudge when the library has grown but no export exists
// (or the last one is getting old). Signed-in users get more slack — the
// account itself is a live backup.
function maybeBackupReminder() {
  try {
    if (state.books.length < 5) return;
    const now = Date.now();
    if (now - Number(localStorage.getItem(BACKUPNAG_KEY) || 0) < 13 * DAY) return;
    const lastX = loadLastExport();
    const ageDays = lastX ? (now - new Date(lastX).getTime()) / DAY : Infinity;
    if (ageDays < ((syncEnabled() && auth) ? 60 : 30)) return;
    localStorage.setItem(BACKUPNAG_KEY, String(now));
    toast("🛟", "Backup reminder", lastX
      ? "It's been " + Math.round(ageDays) + " days since your last export — Settings → ⬇ Export backup."
      : "You've never exported a backup — Settings → ⬇ Export backup takes two taps.");
  } catch (e: any) { /* ignore */ }
}
function openSettings() { closeAccountMenu(); renderSettings(); showModal("settings-modal"); }
function clearLocalData() {
  const msg = (syncEnabled() && auth)
    ? "Clear this device's copy of your bookshelf?\n\nYour books stay safe in your account and download again on the next sign-in/sync. To erase everything, sign out or delete your account."
    : "Erase all bookshelf data on this device?\n\nThis cannot be undone. Export a backup first if you're not sure.";
  if (!confirm(msg)) return;
  try { localStorage.removeItem(STORAGE_KEY); } catch (e: any) { /* ignore */ }
  state = defaultState();
  knownBadges = new Set();
  currentDetailId = null;
  coverBackfillRan = false;
  if (activeView === "book") switchView("reading");
  render();
  renderSettings();
  toast("🧹", "Device data cleared", (syncEnabled() && auth) ? "Your account copy is untouched." : "Your bookshelf on this device is empty now.");
}
async function refreshAppFiles() {
  if (!confirm("Refresh the app's files?\n\nThis clears the cached app and reloads the latest version. Your books are safe.")) return;
  try {
    if (window.caches) { const keys = await caches.keys(); await Promise.all(keys.map((k) => caches.delete(k))); }
    if (navigator.serviceWorker) { const regs = await navigator.serviceWorker.getRegistrations(); await Promise.all(regs.map((r) => r.unregister())); }
  } catch (e: any) { /* ignore */ }
  location.reload();
}

// ---------------------------------------------------------------------------
// Shelf Doctor — data-quality dashboard (find & fix messy library entries)
// ---------------------------------------------------------------------------
function duplicateGroups() {
  const by: Record<string, Book[]> = {};
  state.books.forEach((b) => { const k = (b.title + "|" + (b.author || "")).toLowerCase(); (by[k] = by[k] || []).push(b); });
  return Object.keys(by).map((k) => ({ key: k, books: by[k] })).filter((g) => g.books.length > 1);
}
function shelfDoctorIssues() {
  const bs = state.books;
  return [
    { key: "cover", icon: "🖼", label: "Missing cover", fix: "cover", books: bs.filter((b) => !b.coverUrl) },
    { key: "author", icon: "✍️", label: "Missing author", fix: "edit", books: bs.filter((b) => !(b.author || "").trim()) },
    { key: "pages", icon: "📄", label: "No page / length count", fix: "edit", books: bs.filter((b) => !b.totalPages) },
    { key: "genre", icon: "🏷️", label: "No genres yet", fix: "genres", books: bs.filter((b) => !(b.tags && b.tags.length)) },
    { key: "finish", icon: "📅", label: "Finished, but no date", fix: "edit", books: bs.filter((b) => b.status === "finished" && !b.finishedAt) },
    { key: "series", icon: "#️⃣", label: "In a series, no book number", fix: "edit", books: bs.filter((b) => (b.seriesName || "").trim() && b.seriesNumber == null) },
    { key: "dup", icon: "👯", label: "Possible duplicates", fix: "dup", groups: duplicateGroups() },
  ].filter((g) => (g.books ? g.books.length : g.groups.length) > 0);
}
function shelfDoctorCount() { return shelfDoctorIssues().reduce((s, g) => s + (g.books ? g.books.length : g.groups.length), 0); }
function fixLabel(fix: string) { return fix === "cover" ? "🔍 Find cover" : fix === "genres" ? "✨ Fetch genres" : "✎ Edit"; }
async function fetchGenresForBook(book: Book) {
  let docs = await searchOpenLibrary(book.title, book.author, book.isbn);
  if (book.author && !book.isbn) { const m = docs.filter((d: OLDoc) => authorMatches(book.author, d.author_name)); if (m.length) docs = m; }
  const doc = docs.find((d: OLDoc) => Array.isArray(d.subject) && d.subject.length) || docs[0];
  let picks = cleanSubjects((doc && doc.subject) || []);
  if (picks.length < 3 && doc && doc.key) {
    try { const w = await (await fetch("https://openlibrary.org" + doc.key + ".json")).json(); picks = cleanSubjects((w.subjects || []).concat(doc.subject || [])); } catch (e: any) { /* keep what we have */ }
  }
  return picks;
}
function mergeDuplicateGroup(group: Book[]) {
  if (!group || group.length < 2) return;
  const title = group[0].title;
  if (!confirm(`Merge ${group.length} copies of “${title}” into one?\n\nReading logs, quotes, journal, tags and shelves are combined; the extra copies are removed. This can't be undone.`)) return;
  const primary = group.slice().sort((a, b) => (b.logs.length - a.logs.length) || (new Date(a.addedAt).getTime() - new Date(b.addedAt).getTime()))[0];
  const others = group.filter((b) => b !== primary);
  others.forEach((o) => {
    primary.logs = primary.logs.concat(o.logs || []);
    primary.quotes = (primary.quotes || []).concat(o.quotes || []);
    primary.journal = (primary.journal || []).concat(o.journal || []);
    primary.characters = (primary.characters || []).concat(o.characters || []);
    primary.vocab = (primary.vocab || []).concat(o.vocab || []);
    primary.finishHistory = (primary.finishHistory || []).concat(o.finishHistory || []);
    primary.tags = parseList(primary.tags.concat(o.tags || []).join(","));
    primary.collections = parseList((primary.collections || []).concat(o.collections || []).join(","));
    primary.owned = primary.owned || o.owned;
    primary.readCount = Math.max(primary.readCount || 1, o.readCount || 1);
    (["coverUrl", "author", "isbn", "description", "review", "seriesName", "dnfReason", "pickReason", "lentTo"] as const).forEach((f) => { if (!primary[f] && o[f]) (primary as any)[f] = o[f]; });
    if (!primary.totalPages && o.totalPages) primary.totalPages = o.totalPages;
    if (primary.seriesNumber == null && o.seriesNumber != null) primary.seriesNumber = o.seriesNumber;
    if (!primary.rating && o.rating) primary.rating = o.rating;
    if (!primary.finishedAt && o.finishedAt) primary.finishedAt = o.finishedAt;
    if (!primary.startedAt && o.startedAt) primary.startedAt = o.startedAt;
  });
  const removeIds = new Set(others.map((o) => o.id));
  state.books = state.books.filter((b) => !removeIds.has(b.id));
  commit();
  renderShelfDoctor();
  toast("🔗", "Merged", title);
}
function renderShelfDoctor() {
  const body = $("#doctor-body");
  if (!body) return;
  const issues = shelfDoctorIssues();
  if (!state.books.length) { body.innerHTML = `<p class="doctor-clean">Add some books first, then Shelf Doctor will help you tidy them up.</p>`; return; }
  if (!issues.length) { body.innerHTML = `<p class="doctor-clean">🎉 Your shelves look healthy — nothing needs attention.</p>`; return; }
  const total = issues.reduce((s, g) => s + (g.books ? g.books.length : g.groups.length), 0);
  body.innerHTML = `<p class="muted doctor-intro">${total} thing${total === 1 ? "" : "s"} could use attention. Fix what you like — none of it is required.</p>` +
    issues.map((g) => {
      const count = g.books ? g.books.length : g.groups.length;
      let rows;
      if (g.key === "dup") {
        rows = g.groups!.map((grp) => `<div class="doctor-row"><div class="doctor-book"><span class="doctor-title">${esc(grp.books[0].title)}</span><span class="muted"> · ${grp.books.length} copies${grp.books[0].author ? " · " + esc(grp.books[0].author) : ""}</span></div><button class="mini" data-doctor-merge="${esc(grp.key)}">🔗 Merge</button></div>`).join("");
      } else {
        rows = g.books!.map((b) => `<div class="doctor-row"><div class="doctor-book"><span class="doctor-title">${esc(b.title)}</span>${b.author ? `<span class="muted"> · ${esc(b.author)}</span>` : ""}</div><button class="mini" data-doctor-fix="${g.fix}" data-id="${esc(b.id)}">${fixLabel(g.fix)}</button></div>`).join("");
      }
      return `<details class="doctor-group"${count <= 6 ? " open" : ""}><summary>${g.icon} ${g.label} <span class="doctor-count">${count}</span></summary>${rows}</details>`;
    }).join("");
}
function openShelfDoctor() { closeAccountMenu(); renderShelfDoctor(); showModal("doctor-modal"); }

// ---------------------------------------------------------------------------
// Reading Clubs (spoiler-safe, account-backed; needs the sync worker + D1)
// ---------------------------------------------------------------------------
let currentClubId: string | null = null, clubPollTimer: ReturnType<typeof setInterval> | null = null, clubSocket: WebSocket | null = null;
function clubApi(path: string, opts?: RequestInit) { return apiFetch("/api/clubs" + path, opts || {}); }
function firstName(n: unknown) { return String(n || "?").trim().split(/\s+/)[0] || "?"; }
// Realtime: a WebSocket to the club's Durable Object. On any nudge we re-fetch
// from D1 (so the spoiler gate stays server-side). Polling remains a fallback.
function closeClubWs() { if (clubSocket) { try { clubSocket.onclose = null; clubSocket.close(); } catch (e: any) { /* already closed */ } clubSocket = null; } }
function openClubWs(clubId: string) {
  closeClubWs();
  if (!("WebSocket" in window) || !SYNC_API || !auth) return;
  try {
    const base = SYNC_API.replace(/\/$/, "").replace(/^http/, "ws");
    const ws = new WebSocket(base + "/api/clubs/" + encodeURIComponent(clubId) + "/ws?token=" + encodeURIComponent(auth.token || ""));
    clubSocket = ws;
    ws.onmessage = () => { if (currentClubId === clubId && !$("#clubs-modal").hidden) refreshClub(true); };
    ws.onclose = () => { if (clubSocket === ws) clubSocket = null; };
    ws.onerror = () => { /* fall back to polling */ };
  } catch (e: any) { /* fall back to polling */ }
}
// Per-club "last seen" (unread dots), stored locally.
function loadClubSeen() { try { return JSON.parse(localStorage.getItem("enkelas-club-seen") || "null") || {}; } catch (e: any) { return {}; } }
function markClubSeen(clubId: string) { try { const s = loadClubSeen(); s[clubId] = new Date().toISOString(); localStorage.setItem("enkelas-club-seen", JSON.stringify(s)); } catch (e: any) { /* ignore */ } }
// Shows the clubs modal (auth-gated) without loading anything into it yet.
// Returns false when the user still needs to sign in first.
function openClubsShell() {
  closeAccountMenu();
  if (!syncEnabled()) { toast("ℹ️", "Clubs need an account", "This feature syncs with friends via your account."); return false; }
  if (!auth) { closeModals(); openAuthModal("login"); toast("👤", "Sign in first", "Reading clubs sync with friends through your account."); return false; }
  currentClubId = null;
  showModal("clubs-modal");
  return true;
}
function openClubs() {
  if (!openClubsShell()) return;
  renderClubsListScreen();
}
function clubDisplayName() { return (auth && auth.user && auth.user.fullName) || "You"; }
async function joinClubByCode(code: string) {
  const body = $("#clubs-body");
  if (body) body.innerHTML = `<p class="muted">Joining club…</p>`;
  try {
    const { res, data } = await clubApi("/join", { method: "POST", body: JSON.stringify({ joinCode: code, displayName: clubDisplayName() }) });
    if (res.ok && data.clubId) { toast("👥", "Joined the club!", ""); openClub(data.clubId); return; }
    toast("⚠️", "Couldn't join", (data && data.error) || "Check the code and try again.");
  } catch (e: any) {
    toast("📴", "Couldn't reach the club server", "Check your connection and try the code again.");
  }
  renderClubsListScreen();
}
// Invite links: <app URL>#join/CODE — opening one joins (or prompts sign-in first).
const PENDING_JOIN_KEY = "enkelas-club-pendingjoin";
function clubInviteUrl(code: string) {
  if (!/^https?:/.test(location.protocol)) return ""; // file:// has no shareable origin
  return location.origin + location.pathname + "#join/" + encodeURIComponent(code);
}
async function shareClubInvite(code: string, bookTitle: string) {
  const url = clubInviteUrl(code);
  const text = `Join my reading club${bookTitle ? ` for “${bookTitle}”` : ""} — invite code ${code}`;
  if (navigator.share) {
    try { await navigator.share(url ? { title: "Reading club invite", text, url } : { title: "Reading club invite", text }); return; }
    catch (e: any) { if (e && e.name === "AbortError") return; /* fall through to clipboard */ }
  }
  try { await navigator.clipboard.writeText(url ? text + "\n" + url : text); toast("📋", "Invite copied", "Send it to a friend."); }
  catch (e: any) { toast("ℹ️", "Invite code " + code, url); }
}
function maybePendingClubJoin() {
  let code = null;
  try { code = localStorage.getItem(PENDING_JOIN_KEY); } catch (e: any) { /* ignore */ }
  if (!code || !auth || !syncEnabled()) return;
  try { localStorage.removeItem(PENDING_JOIN_KEY); } catch (e: any) { /* ignore */ }
  closeModals();
  if (openClubsShell()) joinClubByCode(code);
}
function stopClubPoll() { clearTimeout(clubPollTimer!); clubPollTimer = null; closeClubWs(); }
async function renderClubsListScreen() {
  currentClubId = null; stopClubPoll();
  const body = $("#clubs-body");
  body.innerHTML = `<p class="muted">Loading your clubs…</p>`;
  const { res, data } = await clubApi("");
  if (res.status === 503) { body.innerHTML = `<p class="empty">Reading clubs aren't switched on yet — the sync worker needs its clubs database enabled.</p>`; return; }
  if (!res.ok) { body.innerHTML = `<p class="empty">Couldn't load your clubs — check your connection.</p>`; return; }
  const clubs = (data && data.clubs) || [];
  const seen = loadClubSeen();
  body.innerHTML =
    (clubs.length ? `<div class="club-list">${clubs.map((c: Club) => clubRowHTML(c, seen)).join("")}</div>` : `<p class="empty">No clubs yet. Start one for a book you're reading, or join a friend's with their code.</p>`) +
    `<div class="club-forms">
        <form id="club-create-form" class="club-form">
          <h4>Start a club</h4>
          <input class="input" id="club-book-title" placeholder="Book title" required maxlength="140" />
          <input class="input" id="club-book-author" placeholder="Author (optional)" maxlength="140" />
          <button class="primary" type="submit">Create club</button>
        </form>
        <form id="club-join-form" class="club-form">
          <h4>Join with a code</h4>
          <input class="input" id="club-join-code" placeholder="8-letter code" maxlength="8" autocapitalize="characters" />
          <button class="ghost" type="submit">Join club</button>
        </form>
      </div>`;
}
function clubRowHTML(c: Club, seen: Record<string, string>) {
  const members = c.members || [];
  const me = c.me || {};
  const unread = c.last_activity && (!(seen || {})[c.id] || c.last_activity > seen[c.id]);
  return `<button class="club-row" data-club-open="${esc(c.id)}">
      <span class="club-row-main"><strong>${esc(c.book_title)}</strong>${unread ? `<span class="club-dot" title="New activity"></span>` : ""}${c.book_author ? `<span class="muted"> · ${esc(c.book_author)}</span>` : ""}</span>
      <span class="club-row-meta">${members.length} member${members.length === 1 ? "" : "s"} · you're ${me.progress_pct || 0}%</span>
    </button>`;
}
async function openClub(clubId: string) {
  currentClubId = clubId;
  $("#clubs-body").innerHTML = `<p class="muted">Loading…</p>`;
  await refreshClub(false);
  stopClubPoll();
  markClubSeen(clubId); // opening it clears its unread dot
  openClubWs(clubId);   // live updates
  // Polling stays as a backstop in case the socket can't connect.
  const loop = () => { clubPollTimer = setTimeout(async () => { if (currentClubId === clubId && !$("#clubs-modal").hidden) { if (!clubSocket) await refreshClub(true); loop(); } }, 20000); };
  loop();
}
async function refreshClub(quiet?: boolean) {
  const clubId = currentClubId;
  if (!clubId) return;
  const [detailR, commentsR] = await Promise.all([clubApi("/" + clubId), clubApi("/" + clubId + "/comments")]);
  if (!detailR.res.ok) { if (!quiet) $("#clubs-body").innerHTML = `<p class="empty">Couldn't open this club.</p><button class="mini" data-club-back>← All clubs</button>`; return; }
  // Don't clobber the box the user is typing in on a background poll.
  if (quiet && document.activeElement && document.activeElement.id === "club-comment-body") return;
  renderClubScreen(detailR.data, commentsR.data || {});
}
function renderClubScreen(d: any, cm: any) {
  const body = $("#clubs-body");
  if (!body || !d.club || currentClubId !== d.club.id) return;
  const me = d.me || {};
  const myPct = me.progress_pct || 0;
  const members = d.members || [];
  const comments = cm.comments || [];
  const locked = cm.lockedAhead || 0;
  body.innerHTML = `
      <button class="mini" data-club-back>← All clubs</button>
      <h3 class="club-title">${esc(d.club.book_title)}</h3>
      ${d.club.book_author ? `<p class="muted club-sub">${esc(d.club.book_author)}</p>` : ""}
      <div class="club-members">${members.map((m: ClubMember) => clubMemberHTML(m, me.uid)).join("")}</div>
      <div class="club-progress">
        <label for="club-progress-range">You're <strong id="club-my-pct">${myPct}</strong>% through</label>
        <input type="range" id="club-progress-range" min="0" max="100" value="${myPct}" />
      </div>
      <div class="club-comments">
        ${comments.length ? comments.map(clubCommentHTML).join("") : `<p class="muted">No comments you can see yet${myPct < 100 ? " — read on to unlock more" : ""}.</p>`}
        ${locked ? `<p class="club-locked">🔒 ${locked} comment${locked === 1 ? "" : "s"} ahead — keep reading to unlock ${locked === 1 ? "it" : "them"}.</p>` : ""}
      </div>
      <form id="club-comment-form" class="club-comment-form">
        <input class="input" id="club-comment-body" placeholder="Share a thought (up to where you are)…" maxlength="2000" autocomplete="off" />
        <button class="primary" type="submit">Post at ${myPct}%</button>
      </form>
      <div class="club-foot">
        <span class="muted">Invite code: <strong>${esc(d.joinCode || "—")}</strong></span>
        <button class="mini" data-club-copy="${esc(d.joinCode || "")}">Copy code</button>
        <button class="mini" data-club-share="${esc(d.joinCode || "")}" data-club-share-title="${esc(d.club.book_title || "")}">📤 Share invite</button>
        <button class="mini danger" data-club-leave="${esc(d.club.id)}">Leave</button>
      </div>`;
}
// One row per member: name (host gets a crown) + progress bar + %.
function clubMemberHTML(m: ClubMember, meUid: string) {
  const pct = Math.max(0, Math.min(100, Number(m.progress_pct) || 0));
  return `<div class="club-member${m.uid === meUid ? " me" : ""}" title="${esc(m.display_name || "")}${m.role === "host" ? " · host" : ""}">
      <span class="cm-name">${esc(firstName(m.display_name))}${m.role === "host" ? " 👑" : ""}</span>
      <span class="cm-bar"><span class="cm-fill" style="width:${pct}%"></span></span>
      <span class="cm-pct">${pct}%</span>
    </div>`;
}
const CLUB_REACTS = ["❤️", "🤯", "😂", "😢", "👀"];
function clubCommentHTML(c: ClubComment) {
  const rx = c.reactions || { counts: {}, mine: [] };
  const bar = CLUB_REACTS.map((e) => {
    const n = rx.counts[e] || 0;
    const mine = (rx.mine || []).indexOf(e) >= 0;
    return `<button type="button" class="cc-react${mine ? " on" : ""}" data-react="${e}" data-comment="${esc(c.id)}" title="React">${e}${n ? ` <span class="cc-n">${n}</span>` : ""}</button>`;
  }).join("");
  return `<div class="club-comment">
      <div class="cc-head"><strong>${esc(firstName(c.display_name))}</strong> <span class="muted">· ${c.pos_pct}%${c.label ? " · " + esc(c.label) : ""}</span></div>
      <p class="cc-body">${esc(c.body)}</p>
      <div class="cc-reacts">${bar}</div>
    </div>`;
}
async function toggleReaction(commentId: string, emoji: string) {
  if (!currentClubId || !commentId || !emoji) return;
  const { res } = await clubApi("/" + currentClubId + "/reactions", { method: "POST", body: JSON.stringify({ commentId, emoji }) });
  if (res.ok) await refreshClub(false);
}
async function setClubProgress(pct: number) {
  if (!currentClubId) return;
  await clubApi("/" + currentClubId + "/progress", { method: "PUT", body: JSON.stringify({ progressPct: pct }) });
  await refreshClub(false); // server is forward-only; re-read reveals newly-unlocked comments
}
async function postClubComment() {
  const el = $<HTMLTextAreaElement>("#club-comment-body");
  const bodyText = el ? el.value.trim() : "";
  if (!bodyText || !currentClubId) return;
  const pct = Number($("#club-progress-range") ? $<HTMLInputElement>("#club-progress-range").value : 0) || 0;
  if (el) el.value = "";
  const { res } = await clubApi("/" + currentClubId + "/comments", { method: "POST", body: JSON.stringify({ body: bodyText, posPct: pct }) });
  if (!res.ok) { toast("⚠️", "Couldn't post", "Try again in a moment."); if (el) el.value = bodyText; return; }
  await refreshClub(false);
}

// ---------------------------------------------------------------------------
// Community recommendations — a shared, per-category board everyone votes on.
// Backed by the sync worker's D1 (public to read; sign-in required to vote or
// recommend). Books the current reader has already finished are hidden by
// default, filtered client-side against their own synced library.
// ---------------------------------------------------------------------------
let communityCategory = "", communitySort = "top", communityHideRead = true, lastRecs: RecRow[] | null = null, recsSignedIn = false;
function recsApi(path: string, opts?: RequestInit) { return apiFetch("/api/recs" + path, opts || {}); }
function normStr(s: unknown) { return String(s || "").toLowerCase().replace(/\s+/g, " ").trim(); }
function isbnDigits(s: unknown) { return String(s || "").replace(/\D/g, ""); }
// Normalized keys of everything the reader has finished, for the "hide read" filter.
function readMatchers(): { titles: Set<string>; pairs: Set<string>; isbns: Set<string> } {
  const titles = new Set<string>(), pairs = new Set<string>(), isbns = new Set<string>();
  booksFinished().forEach((b) => {
    const t = normStr(b.title); if (t) { titles.add(t); pairs.add(t + "|" + normStr(b.author)); }
    const i = isbnDigits(b.isbn); if (i.length >= 10) isbns.add(i);
  });
  return { titles, pairs, isbns };
}
function recIsRead(r: Pick<RecRow, "book_title" | "book_author" | "book_isbn">, m: { isbns: Set<string>; pairs: Set<string>; titles: Set<string> }) {
  const i = isbnDigits(r.book_isbn); if (i.length >= 10 && m.isbns.has(i)) return true;
  const t = normStr(r.book_title); if (!t) return false;
  const a = normStr(r.book_author);
  return a ? m.pairs.has(t + "|" + a) : m.titles.has(t);
}
function openCommunity() { renderCommunity(); }
async function renderCommunity() {
  const body = $("#community-body");
  if (!body) return;
  if (!syncEnabled()) { body.innerHTML = `<p class="empty">Community recommendations sync through the app's account server, which isn't configured here.</p>`; return; }
  if (lastRecs === null) body.innerHTML = `<p class="muted">Loading recommendations…</p>`;
  const { res, data } = await recsApi("");
  if (res.status === 503) { body.innerHTML = `<p class="empty">Recommendations aren't switched on yet — the sync worker needs its database enabled.</p>`; return; }
  if (!res.ok || !data) { body.innerHTML = `<p class="empty">Couldn't load recommendations — check your connection.</p>`; return; }
  lastRecs = data.recs || [];
  recsSignedIn = !!data.signedIn;
  drawCommunity();
}
function drawCommunity() {
  const body = $("#community-body");
  if (!body) return;
  const all = lastRecs || [];
  populateCommunityCategoryFilter(all);
  const matchers = communityHideRead ? readMatchers() : null;
  let hiddenRead = 0;
  let recs = all.filter((r) => {
    if (matchers && recIsRead(r, matchers)) { hiddenRead++; return false; }
    if (communityCategory && normStr(r.category) !== normStr(communityCategory)) return false;
    return true;
  });
  const sortFn = communitySort === "new"
    ? (a: RecRow, b: RecRow) => (b.created_at || "").localeCompare(a.created_at || "")
    : (a: RecRow, b: RecRow) => (b.score! - a.score!) || (b.up - a.up) || (b.created_at || "").localeCompare(a.created_at || "");
  recs.sort(sortFn);

  const signInBanner = !recsSignedIn
    ? `<div class="community-signin">👋 <button class="linklike" data-community-signin>Sign in</button> to vote and add your own recommendations.</div>`
    : "";
  const readNote = (communityHideRead && hiddenRead)
    ? `<p class="community-readnote muted">${hiddenRead} book${hiddenRead === 1 ? "" : "s"} you've read ${hiddenRead === 1 ? "is" : "are"} hidden. <button class="linklike" data-community-showread>Show ${hiddenRead === 1 ? "it" : "them"}</button></p>`
    : "";

  if (!recs.length) {
    body.innerHTML = signInBanner + `<p class="empty">${all.length ? "Nothing here yet in this view." : "No recommendations yet — be the first to share a book you loved."}</p>` + readNote;
    return;
  }

  let html = signInBanner;
  if (communityCategory) {
    html += `<div class="rec-group">${recs.map(recCardHTML).join("")}</div>`;
  } else {
    // Group by category, categories ordered by how many picks they hold.
    const groups: Record<string, RecRow[]> = {};
    recs.forEach((r) => { const k = r.category || "General"; (groups[k] = groups[k] || []).push(r); });
    const cats = Object.keys(groups).sort((a, b) => (groups[b].length - groups[a].length) || a.toLowerCase().localeCompare(b.toLowerCase()));
    html += cats.map((c) => `<div class="rec-cat"><h3 class="rec-cat-title">${esc(c)} <span class="muted">· ${groups[c].length}</span></h3><div class="rec-group">${groups[c].map(recCardHTML).join("")}</div></div>`).join("");
  }
  body.innerHTML = html + readNote;
}
function recCardHTML(r: RecRow) {
  const up = r.up || 0, down = r.down || 0, mine = r.myVote || 0;
  const cover = r.cover_url
    ? `<img class="rec-cover" src="${esc(r.cover_url)}" alt="" loading="lazy" />`
    : `<div class="rec-cover rec-cover-ph">📖</div>`;
  const worth = (up + down) ? Math.round((up / (up + down)) * 100) : 0;
  const verdict = (up + down) >= 2 ? `<span class="rec-verdict ${worth >= 60 ? "good" : worth <= 40 ? "meh" : ""}">${worth}% say worth reading</span>` : "";
  return `<article class="rec-card" data-rec="${esc(r.id)}">
      ${cover}
      <div class="rec-main">
        <div class="rec-head">
          <strong class="rec-title">${esc(r.book_title)}</strong>
          ${r.book_author ? `<span class="muted rec-author"> · ${esc(r.book_author)}</span>` : ""}
        </div>
        ${r.note ? `<p class="rec-note">${esc(r.note)}</p>` : ""}
        <div class="rec-meta muted">Recommended by ${esc(firstName(r.created_name) || "a reader")}${r.mine ? " (you)" : ""} ${verdict}</div>
        <div class="rec-vote">
          <button type="button" class="rec-btn up${mine === 1 ? " on" : ""}" data-vote="1" title="Worth reading">👍 <span>${up}</span></button>
          <button type="button" class="rec-btn down${mine === -1 ? " on" : ""}" data-vote="-1" title="Not worth it">👎 <span>${down}</span></button>
          ${r.mine ? `<button type="button" class="rec-btn rec-del" data-rec-del title="Remove your recommendation">🗑</button>` : ""}
        </div>
      </div>
    </article>`;
}
function populateCommunityCategoryFilter(recs: RecRow[]) {
  const sel = $<HTMLSelectElement>("#community-category");
  if (!sel) return;
  const cur = communityCategory;
  const cats = Array.from(new Set((recs || []).map((r) => r.category || "General"))).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
  sel.innerHTML = `<option value="">All categories</option>` + cats.map((c) => `<option value="${esc(c)}"${normStr(c) === normStr(cur) ? " selected" : ""}>${esc(c)}</option>`).join("");
  if (cur && !cats.some((c) => normStr(c) === normStr(cur))) { communityCategory = ""; sel.value = ""; }
}
async function voteRec(id: string, vote: number) {
  if (!id) return;
  if (!auth) { closeModals(); openAuthModal("login"); toast("👤", "Sign in to vote", "Voting is tied to your account so everyone votes once."); return; }
  // Optimistic: flip the local vote + tallies, redraw, then reconcile with the server.
  const r = (lastRecs || []).find((x) => x.id === id);
  if (r) {
    const prev = r.myVote || 0;
    if (prev === 1) r.up--; else if (prev === -1) r.down--;
    const next = prev === vote ? 0 : vote;
    if (next === 1) r.up++; else if (next === -1) r.down++;
    r.myVote = next; r.score = r.up - r.down;
    drawCommunity();
  }
  const { res, data } = await recsApi("/" + id + "/vote", { method: "POST", body: JSON.stringify({ vote }) });
  if (!res.ok) { toast("⚠️", "Couldn't record your vote", "Try again in a moment."); await renderCommunity(); return; }
  if (r && data && typeof data.myVote === "number") { r.myVote = data.myVote; r.score = r.up - r.down; }
}
async function deleteRec(id: string) {
  if (!id || !confirm("Remove your recommendation from the community board?")) return;
  const { res } = await recsApi("/" + id + "/delete", { method: "POST", body: "{}" });
  if (!res.ok) { toast("⚠️", "Couldn't remove it", "Try again in a moment."); return; }
  lastRecs = (lastRecs || []).filter((r) => r.id !== id);
  drawCommunity();
  toast("🗑", "Recommendation removed", "");
}
function populateRecCategoryDatalist() {
  const dl = $<HTMLDataListElement>("#rec-category-list");
  if (!dl) return;
  const fromLib = allTags();
  const fromBoard = (lastRecs || []).map((r) => r.category).filter(Boolean);
  const cats = Array.from(new Set([...fromLib, ...fromBoard])).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
  dl.innerHTML = cats.map((c) => `<option value="${esc(c)}"></option>`).join("");
}
function openRecommendModal(prefill?: { title?: string; author?: string; category?: string; isbn?: string; cover?: string }) {
  if (!syncEnabled()) { toast("ℹ️", "Needs an account", "Recommendations sync through your account."); return; }
  if (!auth) { closeModals(); openAuthModal("login"); toast("👤", "Sign in first", "Recommending a book is tied to your account."); return; }
  populateRecCategoryDatalist();
  $<HTMLInputElement>("#rec-title").value = (prefill && prefill.title) || "";
  $<HTMLInputElement>("#rec-author").value = (prefill && prefill.author) || "";
  $<HTMLInputElement>("#rec-category").value = (prefill && prefill.category) || "";
  $<HTMLTextAreaElement>("#rec-note").value = "";
  $("#recommend-modal").dataset.isbn = (prefill && prefill.isbn) || "";
  $("#recommend-modal").dataset.cover = (prefill && prefill.cover) || "";
  showModal("recommend-modal");
  setTimeout(() => { const t = $<HTMLInputElement>("#rec-title"); if (t) t.focus(); }, 60);
}
async function submitRecommend() {
  const title = $<HTMLInputElement>("#rec-title").value.trim();
  const category = $<HTMLInputElement>("#rec-category").value.trim();
  if (!title) { toast("✍️", "Add a title", "Which book are you recommending?"); return; }
  if (!category) { toast("🏷️", "Pick a category", "Which shelf does it belong on?"); return; }
  let author = $<HTMLInputElement>("#rec-author").value.trim();
  let isbn = $("#recommend-modal").dataset.isbn || "";
  let cover = $("#recommend-modal").dataset.cover || "";
  // Borrow author/cover/ISBN from the reader's own copy if they have one.
  if (!cover || !author) {
    const match = state.books.find((b) => normStr(b.title) === normStr(title));
    if (match) { author = author || match.author || ""; cover = cover || match.coverUrl || ""; isbn = isbn || match.isbn || ""; }
  }
  const body = { bookTitle: title, bookAuthor: author, category, note: $<HTMLTextAreaElement>("#rec-note").value.trim(), bookIsbn: isbn, coverUrl: cover, displayName: (auth && auth.user && auth.user.fullName) || "" };
  const { res } = await recsApi("", { method: "POST", body: JSON.stringify(body) });
  if (!res.ok) { toast("⚠️", "Couldn't share it", "Try again in a moment."); return; }
  closeModals();
  // If the book is one the reader has finished, it's hidden from their own
  // board by default — say so, so a "successful but invisible" post isn't confusing.
  const hiddenFromMe = communityHideRead && recIsRead({ book_title: title, book_author: author, book_isbn: isbn }, readMatchers());
  toast("🌟", "Recommendation shared", hiddenFromMe ? title + " — hidden on your board since you've read it, but everyone else sees it" : title);
  // Stay put when recommending from a book page; refresh in place when on the board.
  if (activeView === "community") await renderCommunity();
}

// ---------------------------------------------------------------------------
// PWA install prompt + first-run onboarding
// ---------------------------------------------------------------------------
let deferredInstallPrompt: BeforeInstallPromptEvent | null = null;
function updateInstallUI() {
  const has = !!deferredInstallPrompt;
  const b1 = $<HTMLButtonElement>("#btn-install-app"); if (b1) b1.hidden = !has;
  const b2 = $<HTMLButtonElement>("#onboard-install"); if (b2) b2.hidden = !has;
}
async function promptInstall() {
  if (!deferredInstallPrompt) { toast("ℹ️", "Add to Home Screen", "Use your browser's Share menu → “Add to Home Screen.”"); return; }
  deferredInstallPrompt.prompt();
  try { await deferredInstallPrompt.userChoice; } catch (e: any) { /* dismissed */ }
  deferredInstallPrompt = null;
  updateInstallUI();
}
const ONBOARD_KEY = "enkelas-onboarded";
function finishOnboarding() { try { localStorage.setItem(ONBOARD_KEY, "1"); } catch (e: any) { /* ignore */ } }
function maybeShowOnboarding() {
  let done = false; try { done = localStorage.getItem(ONBOARD_KEY) === "1"; } catch (e: any) { /* ignore */ }
  if (done) return;
  // Existing/returning users skip it: they already have books, or they're
  // signed in and their library may still be syncing down.
  if (state.books.length > 0 || (syncEnabled() && auth)) { finishOnboarding(); return; }
  updateInstallUI();
  showModal("onboard-modal");
}

// ---------------------------------------------------------------------------
// Toasts
// ---------------------------------------------------------------------------
function toast(emoji: string, title: string, sub?: string, isBadge?: boolean) {
  const el = document.createElement("div");
  el.className = "toast" + (isBadge ? " badge-toast" : "");
  el.innerHTML = `<span class="t-emoji">${emoji}</span><div><div class="t-title">${esc(title)}</div>${sub ? `<div class="t-sub">${esc(sub)}</div>` : ""}</div>`;
  $("#toast-stack").appendChild(el);
  setTimeout(() => { el.style.opacity = "0"; el.style.transform = "translateX(20px)"; el.style.transition = "all .3s"; }, isBadge ? 4200 : 2600);
  setTimeout(() => el.remove(), isBadge ? 4600 : 3000);
}

// ---------------------------------------------------------------------------
// Book modal (add / edit)
// ---------------------------------------------------------------------------
let modalRating = 0;
function openBookModal(opts: { book?: Book | null; status?: BookStatus }) {
  const book = opts.book || null;
  const status = book ? book.status : (opts.status || "reading");
  $("#book-modal-title").textContent = book ? "Edit book" : (status === "finished" ? "Add a read book" : status === "want" ? "Add to your list" : "Add a book");
  $<HTMLInputElement>("#f-id").value = book ? book.id : "";
  $<HTMLInputElement>("#f-title").value = book ? book.title : "";
  $<HTMLInputElement>("#f-author").value = book ? book.author : "";
  $<HTMLInputElement>("#f-pages").value = book && book.totalPages ? String(book.totalPages) : "";
  $<HTMLInputElement>("#f-isbn").value = book ? book.isbn : "";
  $<HTMLSelectElement>("#f-format").value = book ? book.format : "physical";
  $<HTMLInputElement>("#f-year").value = book && book.publishedYear ? String(book.publishedYear) : "";
  $<HTMLInputElement>("#f-series").value = book ? book.seriesName : "";
  $<HTMLInputElement>("#f-series-num").value = book && book.seriesNumber != null ? String(book.seriesNumber) : "";
  $<HTMLInputElement>("#f-cover").value = book ? book.coverUrl : "";
  $<HTMLInputElement>("#f-owned").checked = book ? !!book.owned : false;
  $<HTMLInputElement>("#f-location").value = book ? (book.location || "") : "";
  const locs = allLocations();
  $<HTMLDataListElement>("#locations-datalist").innerHTML = locs.map((l) => `<option value="${esc(l)}"></option>`).join("");
  $<HTMLTextAreaElement>("#f-desc").value = book ? (book.description || "") : "";
  $<HTMLTextAreaElement>("#f-review").value = book ? (book.review || "") : "";
  $<HTMLInputElement>("#f-tags").value = book && book.tags ? book.tags.join(", ") : "";
  $<HTMLInputElement>("#f-collections").value = book && book.collections ? book.collections.join(", ") : "";
  $<HTMLTextAreaElement>("#f-pick-reason").value = book ? (book.pickReason || "") : "";
  $<HTMLSelectElement>("#f-expectation").value = book && book.expectation ? String(book.expectation) : "";
  $<HTMLInputElement>("#f-loan-due").value = book && book.loanDue ? book.loanDue : "";
  renderTagHelpers();
  $("#cover-candidates").innerHTML = "";
  setCoverPreview(book ? book.coverUrl : "");

  $$<HTMLInputElement>("input[name='f-status']").forEach((r) => (r.checked = r.value === status));
  toggleStatusFields(status);
  $<HTMLInputElement>("#f-started").value = (book && book.startedAt) ? book.startedAt.slice(0, 10) : todayISODate();
  $<HTMLInputElement>("#f-finished").value = (book && book.finishedAt) ? book.finishedAt.slice(0, 10) : todayISODate();
  modalRating = book && book.rating ? book.rating : 0;
  paintStars($("#f-stars"), modalRating);
  updatePagesLabel();

  showModal("book-modal");
  setTimeout(() => $<HTMLInputElement>("#f-title").focus(), 50);
  // Editing a book with no genres yet → quietly look them up and fill in.
  if (book && (!book.tags || !book.tags.length)) fetchGenresForForm({ quiet: true, onlyIfEmpty: true, forId: book.id });
}
function toggleStatusFields(status: string) {
  $("#reading-fields").hidden = status !== "reading";
  $("#finished-fields").hidden = status !== "finished";
}
function updatePagesLabel() {
  const fmt = $<HTMLSelectElement>("#f-format").value;
  $<HTMLInputElement>("#f-pages").previousElementSibling!.childNodes[0]!.nodeValue = fmt === "audio" ? "Total minutes" : "Total pages";
}
function setCoverPreview(url: string) {
  const box = $("#f-cover-preview");
  box.innerHTML = url ? `<img src="${esc(url)}" alt="cover" onerror="this.parentNode.innerHTML='<span class=\\'cover-ph\\'>No cover</span>'" />` : `<span class="cover-ph">No cover</span>`;
}
function renderTagHelpers() {
  const tags = allTags();
  $<HTMLDataListElement>("#tags-datalist").innerHTML = tags.map((t) => `<option value="${esc(t)}"></option>`).join("");
  const curT = parseList($<HTMLInputElement>("#f-tags").value).map((t) => t.toLowerCase());
  $("#tag-suggest").innerHTML = tags.filter((t) => curT.indexOf(t.toLowerCase()) < 0).slice(0, 12).map((t) => `<span class="tag" data-add-tag="${esc(t)}">+ ${esc(t)}</span>`).join("");
  const cols = allCollections();
  $<HTMLDataListElement>("#collections-datalist").innerHTML = cols.map((t) => `<option value="${esc(t)}"></option>`).join("");
  const curC = parseList($<HTMLInputElement>("#f-collections").value).map((t) => t.toLowerCase());
  $("#collection-suggest").innerHTML = cols.filter((t) => curC.indexOf(t.toLowerCase()) < 0).slice(0, 12).map((t) => `<span class="tag" data-add-collection="${esc(t)}">+ 📁 ${esc(t)}</span>`).join("");
}

// Open Library "subjects" are noisy (bestseller lists, "large type", library
// housekeeping). Keep the ones that read like genres, title-cased and deduped.
function cleanSubjects(subjects: string[]) {
  if (!Array.isArray(subjects)) return [];
  const BAD = /\d|fiction in|accessible|reading level|nyt|new york times|bestsell|large type|protected daisy|in library|overdrive|lending|open library|internet archive|braille|audiobook|ebook|collection|general/i;
  // Words that signal a genre rather than a plot element (OL mixes both, and
  // doesn't rank them, so "Arkenstone" and "Fantasy" sit side by side).
  const GENRE = /fiction|fantasy|romance|myster|thriller|horror|histor|biograph|memoir|science|sci-?fi|young adult|nonfiction|non-fiction|poetry|classic|adventure|literary|literature|contemporary|dystopia|paranormal|crime|detective|self-help|philosoph|humou?r|comic|graphic novel|children|juvenile|coming of age|mytholog|retelling|saga|epic|western|suspense|drama|essays|short stories|feminis|queer|lgbt|thriller|horror|western|magical realism/i;
  const seen = new Set<string>(), hits: string[] = [], rest: string[] = [];
  for (let s of subjects) {
    s = String(s || "").trim();
    if (s.length < 3 || s.length > 26 || BAD.test(s)) continue;
    const key = s.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    const titled = s.toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());
    (GENRE.test(s) ? hits : rest).push(titled);
  }
  // Genre-looking terms first; only fall back to other subjects if we found
  // barely any real genres, so obscure books still get something.
  return (hits.length >= 3 ? hits : hits.concat(rest)).slice(0, 5);
}
// Look up genres for whatever's in the add/edit form and merge them into the
// tags field. Used by the "✨ Fetch genres" button and auto-run when editing a
// book that has none yet.
async function fetchGenresForForm(opts?: { silent?: boolean; quiet?: boolean; onlyIfEmpty?: boolean; forId?: string }) {
  opts = opts || {};
  const title = $<HTMLInputElement>("#f-title").value.trim(), author = $<HTMLInputElement>("#f-author").value.trim(), isbn = $<HTMLInputElement>("#f-isbn").value.trim();
  if (!title && !isbn) { if (!opts.quiet) toast("ℹ️", "Add a title first", "Then I can look up its genres."); return; }
  const btn = $<HTMLButtonElement>("#btn-fetch-genres");
  if (btn && !opts.quiet) { btn.disabled = true; btn.textContent = "Fetching…"; }
  try {
    let docs = await searchOpenLibrary(title, author, isbn);
    if (author && !isbn) { const m = docs.filter((d: OLDoc) => authorMatches(author, d.author_name)); if (m.length) docs = m; }
    const doc = docs.find((d: OLDoc) => Array.isArray(d.subject) && d.subject.length) || docs[0];
    let picks = cleanSubjects((doc && doc.subject) || []);
    // The work record usually carries a richer subject list than search docs.
    if (picks.length < 3 && doc && doc.key) {
      try { const w = await (await fetch("https://openlibrary.org" + doc.key + ".json")).json(); picks = cleanSubjects((w.subjects || []).concat(doc.subject || [])); } catch (e: any) { /* keep what we have */ }
    }
    if (opts.forId && $<HTMLInputElement>("#f-id").value !== opts.forId) return; // modal moved on to another book
    if (!picks.length) { if (!opts.quiet) toast("🔍", "No genres found", "Add a couple by hand below."); return; }
    const existing = parseList($<HTMLInputElement>("#f-tags").value);
    if (opts.onlyIfEmpty && existing.length) return;
    const have = new Set(existing.map((x) => x.toLowerCase()));
    const merged = existing.slice();
    picks.forEach((pk) => { if (!have.has(pk.toLowerCase())) { have.add(pk.toLowerCase()); merged.push(pk); } });
    $<HTMLInputElement>("#f-tags").value = merged.join(", ");
    renderTagHelpers();
    if (!opts.quiet) toast("🏷️", "Genres added", picks.join(", "));
  } catch (e: any) {
    if (!opts.quiet) toast("⚠️", "Couldn't fetch genres", "Check your connection, or add them by hand.");
  } finally {
    if (btn && !opts.quiet) { btn.disabled = false; btn.textContent = "✨ Fetch genres"; }
  }
}

async function handleFetch() {
  const title = $<HTMLInputElement>("#f-title").value.trim(), author = $<HTMLInputElement>("#f-author").value.trim(), isbn = $<HTMLInputElement>("#f-isbn").value.trim();
  if (!title && !isbn) { toast("ℹ️", "Type a title first", "Then I can look up the cover."); return; }
  const btn = $<HTMLButtonElement>("#btn-fetch");
  btn.disabled = true; btn.textContent = "Searching…";
  try {
    let docs = await searchOpenLibrary(title, author, isbn);
    if (!docs.length && author && !isbn) {
      // Strict title+author search can miss a real book; retry on title alone.
      docs = await searchOpenLibrary(title, "", "");
    }
    if (!docs.length) { toast("🔍", "No matches found", author ? "Double-check the author's spelling, or paste a cover URL." : "Try adding the author, or paste a cover URL."); return; }
    // With an author given, only trust same-author results — a book with the
    // same title by someone else must not fill in the cover/pages/ISBN.
    if (author && !isbn) {
      const matched = docs.filter((d: OLDoc) => authorMatches(author, d.author_name));
      if (matched.length) {
        docs = matched;
      } else {
        renderCandidates(docs);
        toast("🔍", "Couldn't confirm that author", `No “${title}” by ${author} in the catalogue — pick the right book below to fill its details, or leave what you typed.`);
        return; // leave the user's fields untouched rather than fill wrong data
      }
    }
    // Show the matches as a pickable list and pre-fill from the best one,
    // leaving anything the user already typed untouched.
    renderCandidates(docs);
    applyDoc(docs[0], { overwrite: false });
    toast("✨", "Found it!", docs.length > 1 ? "Not the one? Pick another below." : "Wrong cover or genres? Tweak them below.");
  } catch (e: any) {
    console.warn(e);
    toast("⚠️", "Lookup failed", "Check your connection, or paste a cover URL.");
  } finally {
    btn.disabled = false; btn.textContent = "🔍 Auto-fetch details & cover";
  }
}

// The most recent search results, kept so the candidate click handler can look
// a pick up by index. A token guards the async description/genre fetch so a
// slow response from an earlier pick can't overwrite a newer one.
let lastSearchDocs: OLDoc[] = [];
let applyDocToken = 0;
// Fill the add/edit form from one Open Library result. overwrite=true means the
// user explicitly picked this book, so replace the catalogue fields;
// overwrite=false auto-fills from the top match but keeps whatever was typed.
async function applyDoc(doc: OLDoc, opts?: { overwrite?: boolean }) {
  if (!doc) return;
  opts = opts || {};
  const overwrite = !!opts.overwrite;
  const myToken = ++applyDocToken;
  const put = (sel: string, val: unknown) => { if (val == null || val === "") return; if (overwrite || !$<HTMLInputElement>(sel).value) $<HTMLInputElement>(sel).value = String(val); };
  put("#f-title", doc.title);
  put("#f-author", doc.author_name && doc.author_name[0]);
  put("#f-pages", doc.number_of_pages_median);
  put("#f-isbn", doc.isbn && doc.isbn[0]);
  put("#f-year", doc.first_publish_year);
  const cover = doc.cover_i ? coverFromId(doc.cover_i) : (doc.isbn && doc.isbn[0] ? coverFromIsbn(doc.isbn[0]) : "");
  if (cover && (overwrite || !$<HTMLInputElement>("#f-cover").value)) { $<HTMLInputElement>("#f-cover").value = cover; setCoverPreview(cover); }
  const picks = cleanSubjects(doc.subject || []);
  if (picks.length && (overwrite || !$<HTMLInputElement>("#f-tags").value.trim())) { $<HTMLInputElement>("#f-tags").value = picks.join(", "); renderTagHelpers(); }
  // The work record carries the description + a fuller subject list. Fetch it,
  // but drop the result if a newer pick has since superseded this one.
  if (doc.key && (overwrite || picks.length < 3 || !$<HTMLTextAreaElement>("#f-desc").value.trim())) {
    try {
      const w = await (await fetch("https://openlibrary.org" + doc.key + ".json")).json();
      if (myToken !== applyDocToken || !w) return;
      let d = w.description;
      if (d && typeof d === "object") d = d.value;
      d = d ? String(d).split("\n")[0].slice(0, 600) : "";
      if (overwrite) $<HTMLTextAreaElement>("#f-desc").value = d;                 // reflect the chosen book, even if blank
      else if (d && !$<HTMLTextAreaElement>("#f-desc").value.trim()) $<HTMLTextAreaElement>("#f-desc").value = d;
      const richer = cleanSubjects((w.subjects || []).concat(doc.subject || []));
      if (richer.length > picks.length && (overwrite || !$<HTMLInputElement>("#f-tags").value.trim())) { $<HTMLInputElement>("#f-tags").value = richer.join(", "); renderTagHelpers(); }
    } catch (e: any) { /* offline or no work record — keep what we have */ }
  }
}
// Render the search results as a list of pickable books (cover + title +
// author + year), so the user chooses the right edition instead of us guessing.
function renderCandidates(docs: OLDoc[], selIdx?: number) {
  lastSearchDocs = Array.isArray(docs) ? docs : [];
  const box = $("#cover-candidates");
  if (!lastSearchDocs.length) { box.innerHTML = ""; return; }
  const cards = lastSearchDocs.slice(0, 8).map((d, i) => {
    const thumb = d.cover_i ? coverFromId(d.cover_i, "M") : (d.isbn && d.isbn[0] ? coverFromIsbn(d.isbn[0], "M") : "");
    const cov = thumb
      ? `<img src="${esc(thumb)}" alt="" loading="lazy" onerror="this.outerHTML='<span class=\\'cand-noimg\\'>📕</span>'" />`
      : `<span class="cand-noimg">📕</span>`;
    const bits = [d.author_name && d.author_name[0] ? esc(d.author_name[0]) : "Unknown author"];
    if (d.first_publish_year) bits.push(String(d.first_publish_year));
    if (d.number_of_pages_median) bits.push(d.number_of_pages_median + "p");
    return `<button type="button" class="cand${i === selIdx ? " sel" : ""}" data-doc-idx="${i}" title="Use this book's details">
        <span class="cand-cover">${cov}</span>
        <span class="cand-meta"><span class="cand-title">${esc(d.title || "Untitled")}</span><span class="cand-sub">${bits.join(" · ")}</span></span>
      </button>`;
  }).join("");
  const hint = lastSearchDocs.length > 1 ? "Pick the right book to autofill its details:" : "Found this — pick it to fill the rest:";
  box.innerHTML = `<p class="cand-hint muted">${hint}</p><div class="cand-list">${cards}</div>`;
}

function saveBookFromForm(e: SubmitEvent) {
  e.preventDefault();
  const id = $<HTMLInputElement>("#f-id").value;
  const status = $$<HTMLInputElement>("input[name='f-status']").find((r) => r.checked)!.value as BookStatus;
  const existing = id ? state.books.find((b) => b.id === id) : null;
  const title = $<HTMLInputElement>("#f-title").value.trim();
  if (!title) return;
  const wasFinished = existing && existing.status === "finished";

  const book: Book = existing || ({ id: uid(), addedAt: new Date().toISOString(), logs: [], quotes: [], readCount: 1, finishHistory: [] } as unknown as Book);
  book.title = title;
  book.author = $<HTMLInputElement>("#f-author").value.trim();
  book.totalPages = Number($<HTMLInputElement>("#f-pages").value) || 0;
  book.isbn = $<HTMLInputElement>("#f-isbn").value.trim();
  book.format = $<HTMLSelectElement>("#f-format").value as Book["format"];
  book.publishedYear = Number($<HTMLInputElement>("#f-year").value) || null;
  book.seriesName = $<HTMLInputElement>("#f-series").value.trim();
  book.seriesNumber = $<HTMLInputElement>("#f-series-num").value !== "" ? Number($<HTMLInputElement>("#f-series-num").value) : null;
  book.coverUrl = $<HTMLInputElement>("#f-cover").value.trim();
  book.owned = $<HTMLInputElement>("#f-owned").checked;
  book.location = $<HTMLInputElement>("#f-location").value.trim();
  book.description = $<HTMLTextAreaElement>("#f-desc").value.trim();
  book.review = $<HTMLTextAreaElement>("#f-review").value.trim();
  book.tags = parseList($<HTMLInputElement>("#f-tags").value);
  book.collections = parseList($<HTMLInputElement>("#f-collections").value);
  book.pickReason = $<HTMLTextAreaElement>("#f-pick-reason").value.trim();
  book.expectation = Number($<HTMLSelectElement>("#f-expectation").value) || null;
  book.loanDue = $<HTMLInputElement>("#f-loan-due").value || "";
  book.quotes = book.quotes || [];
  book.status = status;

  if (status === "reading") {
    book.startedAt = $<HTMLInputElement>("#f-started").value ? new Date($<HTMLInputElement>("#f-started").value).toISOString() : new Date().toISOString();
  } else if (status === "want") {
    /* no dates */
  } else if (status === "finished") {
    book.finishedAt = $<HTMLInputElement>("#f-finished").value ? new Date($<HTMLInputElement>("#f-finished").value).toISOString() : new Date().toISOString();
    book.startedAt = book.startedAt || book.finishedAt;
    book.rating = modalRating || book.rating || null;
    if (book.logs.length === 0 && book.totalPages > 0) {
      book.logs.push({ id: uid(), date: book.finishedAt!, pages: book.totalPages, minutes: 0, mood: "", note: "Added as already read" });
    }
    if (!wasFinished) {
      book.finishHistory = book.finishHistory || [];
      book.finishHistory.push({ date: book.finishedAt, rating: book.rating || null });
      book.bookmark = null;
    }
  }

  if (!existing) {
    const key = (title + "|" + book.author).toLowerCase();
    if (state.books.some((b) => (b.title + "|" + (b.author || "")).toLowerCase() === key)
        && !confirm(`You already have “${title}”${book.author ? " by " + book.author : ""} on your shelves.\n\nAdd it again anyway?`)) return;
    state.books.push(book);
  }
  closeModals();
  commit();
  checkNewBadges();
  if (status === "finished" && !wasFinished) confetti();
  toast("✅", existing ? "Book updated" : "Book added", title);
}

// ---------------------------------------------------------------------------
// Log / finish / rate dialogs
// ---------------------------------------------------------------------------
function openLogModal(book: Book, log?: ReadingLog | null) {
  resetTimer();
  const isAudio = book.format === "audio";
  const baseline = pagesBefore(book, log);
  $<HTMLInputElement>("#log-book-id").value = book.id;
  $<HTMLInputElement>("#log-id").value = log ? log.id : "";
  $<HTMLInputElement>("#log-baseline").value = String(baseline);
  $("#log-book-name").textContent = book.title;
  $("#log-modal-title").textContent = log ? "Edit reading session" : "Log a reading session";
  // Audio books track minutes as a running total per session; page-based books
  // ask for the page you've reached and we work out the delta ourselves.
  $("#log-pages-label").textContent = isAudio ? "Minutes read this session *" : "Current page *";
  $<HTMLInputElement>("#log-pages").min = String(isAudio ? 1 : baseline + 1);
  $<HTMLInputElement>("#log-pages").value = log ? String(isAudio ? log.pages : baseline + log.pages) : "";
  $<HTMLInputElement>("#log-minutes").value = log && log.minutes ? String(log.minutes) : "";
  $<HTMLInputElement>("#log-note").value = log ? log.note : "";
  $<HTMLInputElement>("#log-when").value = log ? toLocalInput(log.date) : nowLocalInput();
  paintMood(log ? log.mood : "");
  updateLogPageHint();
  showModal("log-modal");
  setTimeout(() => $<HTMLInputElement>("#log-pages").focus(), 50);
}
// Live helper under the page field: shows where you left off and the pages
// this session works out to. Hidden entirely for audio books.
function updateLogPageHint() {
  const hint = $("#log-page-hint");
  if (!hint) return;
  const book = state.books.find((b) => b.id === $<HTMLInputElement>("#log-book-id").value);
  if (!book || book.format === "audio") { hint.hidden = true; return; }
  hint.hidden = false;
  const baseline = Number($<HTMLInputElement>("#log-baseline").value) || 0;
  const total = book.totalPages || 0;
  const cur = Number($<HTMLInputElement>("#log-pages").value);
  let msg = (baseline > 0 ? `You were on page ${num(baseline)}` : "Starting from the beginning");
  if (total) msg += ` of ${num(total)}`;
  msg += ".";
  let warn = false;
  if ($<HTMLInputElement>("#log-pages").value !== "") {
    const delta = cur - baseline;
    if (delta > 0) msg += ` That's +${num(delta)} ${unitLabel(book)} this session.`;
    else { msg += " ⚠️ Enter a page beyond where you left off."; warn = true; }
  }
  hint.textContent = msg;
  hint.classList.toggle("warn", warn);
}
function paintMood(mood: string) {
  $<HTMLInputElement>("#log-mood").value = mood || "";
  $$("#mood-row button").forEach((b) => b.classList.toggle("sel", b.dataset.mood === mood));
}
function saveLog(e: SubmitEvent) {
  e.preventDefault();
  const book = state.books.find((b) => b.id === $<HTMLInputElement>("#log-book-id").value);
  if (!book) return;
  const isAudio = book.format === "audio";
  const entered = Number($<HTMLInputElement>("#log-pages").value);
  if (!entered || entered < 1) return;
  // For page-based books the field holds the page reached; the session's page
  // count is that minus where we left off. Audio still logs raw minutes.
  const baseline = Number($<HTMLInputElement>("#log-baseline").value) || 0;
  const pages = isAudio ? entered : entered - baseline;
  if (!isAudio && pages < 1) {
    toast("⚠️", "Check the page number", `You were already on page ${num(baseline)} — enter a higher page.`);
    return;
  }
  const when = $<HTMLInputElement>("#log-when").value ? new Date($<HTMLInputElement>("#log-when").value).toISOString() : new Date().toISOString();
  const note = $<HTMLInputElement>("#log-note").value.trim();
  const minutes = Number($<HTMLInputElement>("#log-minutes").value) || 0;
  const mood = $<HTMLInputElement>("#log-mood").value || "";
  const editId = $<HTMLInputElement>("#log-id").value;
  if (editId) {
    const lg = book.logs.find((x) => x.id === editId);
    if (lg) { lg.pages = pages; lg.date = when; lg.note = note; lg.minutes = minutes; lg.mood = mood; }
  } else {
    book.logs.push({ id: uid(), date: when, pages, minutes, mood, note });
  }
  resetTimer();
  closeModals();
  commit();
  checkNewBadges();
  refreshDetail();
  toast(editId ? "✎" : "📖", editId ? "Log updated" : "Logged " + pages + " " + unitLabel(book), book.title);
}

let finishRating = 0;
function openFinishModal(book: Book) {
  $<HTMLInputElement>("#finish-mode").value = "finish";
  $<HTMLInputElement>("#finish-book-id").value = book.id;
  $("#finish-book-name").textContent = book.title;
  $<HTMLInputElement>("#finish-date").value = todayISODate();
  finishRating = book.rating || 0;
  paintStars($("#finish-stars"), finishRating);
  showModal("finish-modal");
}
function openRereadModal(book: Book) {
  openFinishModal(book);
  $<HTMLInputElement>("#finish-mode").value = "reread";
  $("#finish-modal-title").textContent = "Finished a re-read";
  finishRating = 0; // rate THIS read on its own
  paintStars($("#finish-stars"), 0);
}
function saveFinish(e: SubmitEvent) {
  e.preventDefault();
  const book = state.books.find((b) => b.id === $<HTMLInputElement>("#finish-book-id").value);
  if (!book) return;
  const mode = $<HTMLInputElement>("#finish-mode").value || "finish";
  const when = $<HTMLInputElement>("#finish-date").value ? new Date($<HTMLInputElement>("#finish-date").value).toISOString() : new Date().toISOString();
  if (mode === "reread") {
    book.readCount = (book.readCount || 1) + 1;
    book.finishedAt = when;
    book.finishHistory = book.finishHistory || [];
    book.finishHistory.push({ date: when, rating: finishRating || null });
    if (finishRating) book.rating = finishRating;
    closeModals();
    commit();
    checkNewBadges();
    refreshDetail();
    confetti();
    toast("🔁", "Re-read finished!", book.title + " · " + book.readCount + "× read");
    return;
  }
  const wasFinished = book.status === "finished";
  book.status = "finished";
  book.finishedAt = when;
  book.rating = finishRating || book.rating || null;
  const read = pagesRead(book);
  if (book.totalPages && read < book.totalPages) {
    book.logs.push({ id: uid(), date: book.finishedAt, pages: book.totalPages - read, minutes: 0, mood: "", note: "Finished the book" });
  }
  if (!wasFinished) {
    book.finishHistory = book.finishHistory || [];
    book.finishHistory.push({ date: book.finishedAt, rating: book.rating || null });
    book.bookmark = null; // journey's over — no need to keep your place
  }
  closeModals();
  commit();
  checkNewBadges();
  if (!wasFinished) confetti();
  toast("🏁", "Finished!", book.title);
}
function rateBook(book: Book) {
  $<HTMLInputElement>("#finish-mode").value = "finish";
  $("#finish-modal-title").textContent = "Rate this book";
  $<HTMLInputElement>("#finish-book-id").value = book.id;
  $("#finish-book-name").textContent = book.title;
  $<HTMLInputElement>("#finish-date").value = (book.finishedAt || new Date().toISOString()).slice(0, 10);
  finishRating = book.rating || 0;
  paintStars($("#finish-stars"), finishRating);
  showModal("finish-modal");
}

// ---------------------------------------------------------------------------
// Bookmark ("where I left off") + DNF-reason dialogs
// ---------------------------------------------------------------------------
function openBookmarkModal(book: Book) {
  $<HTMLInputElement>("#bm-book-id").value = book.id;
  $("#bm-book-name").textContent = book.title;
  $<HTMLInputElement>("#bm-page").value = book.bookmark && book.bookmark.page ? String(book.bookmark.page) : "";
  $<HTMLInputElement>("#bm-note").value = book.bookmark ? book.bookmark.note : "";
  $<HTMLButtonElement>("#bm-clear").hidden = !book.bookmark;
  showModal("bookmark-modal");
  setTimeout(() => $<HTMLInputElement>("#bm-note").focus(), 50);
}
function openLendModal(book: Book) {
  $<HTMLInputElement>("#lend-book-id").value = book.id;
  $("#lend-book-name").textContent = book.title;
  $<HTMLInputElement>("#lend-name").value = book.lentTo || "";
  $<HTMLInputElement>("#lend-date").value = new Date().toISOString().slice(0, 10);
  showModal("lend-modal");
  setTimeout(() => $<HTMLInputElement>("#lend-name").focus(), 50);
}
function saveLend(e: SubmitEvent) {
  e.preventDefault();
  const book = state.books.find((b) => b.id === $<HTMLInputElement>("#lend-book-id").value);
  if (!book) return;
  const name = $<HTMLInputElement>("#lend-name").value.trim();
  if (!name) return;
  book.lentTo = name;
  book.lentAt = $<HTMLInputElement>("#lend-date").value ? new Date($<HTMLInputElement>("#lend-date").value + "T12:00:00").toISOString() : new Date().toISOString();
  closeModals();
  commit();
  toast("📤", "Lent out", `“${book.title}” is with ${name} now`);
}
function saveBookmark(e: SubmitEvent) {
  e.preventDefault();
  const book = state.books.find((b) => b.id === $<HTMLInputElement>("#bm-book-id").value);
  if (!book) return;
  const page = $<HTMLInputElement>("#bm-page").value ? Number($<HTMLInputElement>("#bm-page").value) : null;
  const note = $<HTMLInputElement>("#bm-note").value.trim();
  if (!page && !note) { closeModals(); return; }
  book.bookmark = { page, note, date: new Date().toISOString() };
  closeModals();
  commit();
  toast("🔖", "Bookmark saved", (page ? "p." + page + " · " : "") + book.title);
}
function clearBookmark() {
  const book = state.books.find((b) => b.id === $<HTMLInputElement>("#bm-book-id").value);
  if (!book) return;
  book.bookmark = null;
  closeModals();
  commit();
  toast("🔖", "Bookmark cleared", book.title);
}
function openDnfModal(book: Book) {
  $<HTMLInputElement>("#dnf-book-id").value = book.id;
  $("#dnf-book-name").textContent = book.title;
  $<HTMLTextAreaElement>("#dnf-reason").value = book.dnfReason || "";
  showModal("dnf-modal");
  setTimeout(() => $<HTMLTextAreaElement>("#dnf-reason").focus(), 50);
}
function saveDnf(e: SubmitEvent) {
  e.preventDefault();
  const book = state.books.find((b) => b.id === $<HTMLInputElement>("#dnf-book-id").value);
  if (!book) return;
  book.status = "dnf";
  book.finishedAt = book.finishedAt || new Date().toISOString();
  book.dnfReason = $<HTMLTextAreaElement>("#dnf-reason").value.trim();
  book.bookmark = null;
  closeModals();
  commit();
  toast("🚧", "Did not finish", book.title);
}

// ---------------------------------------------------------------------------
// Reading-session timer
// ---------------------------------------------------------------------------
let timerStart: number | null = null, timerInterval: ReturnType<typeof setInterval> | null = null;
function resetTimer() {
  if (timerInterval) clearInterval(timerInterval!);
  timerInterval = null; timerStart = null;
  const btn = $<HTMLButtonElement>("#timer-btn"), read = $("#timer-read");
  if (btn) btn.textContent = "⏱ Start timer";
  if (read) { read.hidden = true; read.textContent = "00:00"; }
}
function toggleTimer() {
  if (timerStart) {
    const mins = Math.max(0, Math.round((Date.now() - timerStart) / 60000));
    $<HTMLInputElement>("#log-minutes").value = String((Number($<HTMLInputElement>("#log-minutes").value) || 0) + mins);
    resetTimer();
  } else {
    timerStart = Date.now();
    $<HTMLButtonElement>("#timer-btn").textContent = "⏹ Stop timer";
    $("#timer-read").hidden = false;
    timerInterval = setInterval(() => {
      const s = Math.floor((Date.now() - timerStart!) / 1000);
      $("#timer-read").textContent = String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0");
    }, 1000);
  }
}

// ---------------------------------------------------------------------------
// Barcode scanner
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// EAN-13 fallback decoder — iOS Safari has no BarcodeDetector, so on Apple
// devices we decode ISBN barcodes ourselves from camera frames. EAN-13 is a
// 1D code: 95 modules = guard(3) + 6 digits(7 each, L/G parity encodes the
// 13th digit) + guard(5) + 6 digits(7 each) + guard(3). We scan several
// horizontal lines, run-length encode them, and pattern-match run widths.
// Checksum + 978/979 prefix keep false positives out.
// ---------------------------------------------------------------------------
const EAN_SIG = [ // run-width signature (4 runs, 7 modules) per digit, L-encoding
  [3, 2, 1, 1], [2, 2, 2, 1], [2, 1, 2, 2], [1, 4, 1, 1], [1, 1, 3, 2],
  [1, 2, 3, 1], [1, 1, 1, 4], [1, 3, 1, 2], [1, 2, 1, 3], [3, 1, 1, 2],
]; // G-encoding signature = the same reversed; R-encoding = same as L
const EAN_PARITY = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"];
function eanMatchDigit(runs: number[], i: number, rightSide: boolean) {
  const total = runs[i] + runs[i + 1] + runs[i + 2] + runs[i + 3];
  if (!total) return null;
  let best = null, bestD = Infinity, secondD = Infinity;
  for (let d = 0; d < 10; d++) {
    const sig = EAN_SIG[d];
    let dl = 0, dg = 0;
    for (let k = 0; k < 4; k++) {
      const w = (runs[i + k] * 7) / total;
      dl += Math.abs(w - sig[k]);
      dg += Math.abs(w - sig[3 - k]);
    }
    const cand: [number, string][] = rightSide ? [[dl, "L"]] : [[dl, "L"], [dg, "G"]];
    for (const [dist, par] of cand) {
      if (dist < bestD) { secondD = bestD; bestD = dist; best = { d, par }; }
      else if (dist < secondD) secondD = dist;
    }
  }
  if (!best || bestD > 1.5 || secondD - bestD < 0.25) return null; // too blurry/ambiguous
  return best;
}
function eanGuardOk(runs: number[], i: number, count: number, m: number) {
  let total = 0;
  for (let k = 0; k < count; k++) { if (runs[i + k] == null) return false; total += runs[i + k]; }
  if (Math.abs(total / count - m) > m * 0.55) return false;
  for (let k = 0; k < count; k++) if (Math.abs(runs[i + k] - m) > m * 0.7) return false;
  return true;
}
function eanDecodeRuns(runs: number[], startsDark: boolean) {
  // runs = widths of alternating dark/light stretches; runs[0] darkness = startsDark
  for (let i = startsDark ? 0 : 1; i + 58 < runs.length; i += 2) {
    const m = (runs[i] + runs[i + 1] + runs[i + 2]) / 3; // start guard 1-1-1
    if (m < 1 || !eanGuardOk(runs, i, 3, m)) continue;
    let ok = true, parity = "", digits = "";
    for (let d = 0; d < 6 && ok; d++) {
      const g = i + 3 + d * 4;
      const tot = runs[g] + runs[g + 1] + runs[g + 2] + runs[g + 3];
      if (Math.abs(tot - 7 * m) > 3 * m) { ok = false; break; }
      const hit = eanMatchDigit(runs, g, false);
      if (!hit) { ok = false; break; }
      digits += hit.d; parity += hit.par;
    }
    if (!ok || !eanGuardOk(runs, i + 27, 5, m)) continue;
    for (let d = 0; d < 6 && ok; d++) {
      const g = i + 32 + d * 4;
      const tot = runs[g] + runs[g + 1] + runs[g + 2] + runs[g + 3];
      if (Math.abs(tot - 7 * m) > 3 * m) { ok = false; break; }
      const hit = eanMatchDigit(runs, g, true);
      if (!hit) { ok = false; break; }
      digits += hit.d;
    }
    if (!ok || !eanGuardOk(runs, i + 56, 3, m)) continue;
    const first = EAN_PARITY.indexOf(parity);
    if (first < 0) continue;
    const code = first + digits;
    let sum = 0;
    for (let k = 0; k < 12; k++) sum += Number(code[k]) * (k % 2 ? 3 : 1);
    if ((10 - (sum % 10)) % 10 !== Number(code[12])) continue;
    if (!/^97[89]/.test(code)) continue; // books only — ignores price add-on codes
    return code;
  }
  return null;
}
function eanRowRuns(data: Uint8ClampedArray, w: number, y: number) {
  const off = y * w * 4;
  let min = 255, max = 0;
  const lum = new Array(w);
  for (let x = 0; x < w; x++) {
    const j = off + x * 4;
    const v = 0.299 * data[j] + 0.587 * data[j + 1] + 0.114 * data[j + 2];
    lum[x] = v;
    if (v < min) min = v; else if (v > max) max = v;
  }
  if (max - min < 48) return null; // no barcode contrast on this line
  const thr = (min + max) / 2;
  const runs = []; let dark = lum[0] < thr, len = 1;
  for (let x = 1; x < w; x++) {
    const d = lum[x] < thr;
    if (d === dark) len++;
    else { runs.push(len); dark = d; len = 1; }
  }
  runs.push(len);
  return { runs, startsDark: lum[0] < thr };
}
function decodeEAN13FromCanvas(canvas: HTMLCanvasElement) {
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  const w = canvas.width, h = canvas.height;
  const data = ctx.getImageData(0, 0, w, h).data;
  for (let f = 0.30; f <= 0.70; f += 0.05) {
    const row = eanRowRuns(data, w, Math.round(h * f));
    if (!row) continue;
    const fwd = eanDecodeRuns(row.runs, row.startsDark);
    if (fwd) return fwd;
    const rev = row.runs.slice().reverse();
    const revStartsDark = row.startsDark === (row.runs.length % 2 === 1);
    const back = eanDecodeRuns(rev, revStartsDark);
    if (back) return back;
  }
  return null;
}
window.__decodeEAN13Canvas = decodeEAN13FromCanvas; // debug/test hook (no camera needed)
function decodeEAN13FromVideo(video: HTMLVideoElement, canvas: HTMLCanvasElement) {
  if (!video.videoWidth) return null;
  const w = Math.min(900, video.videoWidth);
  const h = Math.round(video.videoHeight * (w / video.videoWidth));
  canvas.width = w; canvas.height = h;
  canvas.getContext("2d", { willReadFrequently: true })!.drawImage(video, 0, 0, w, h);
  return decodeEAN13FromCanvas(canvas);
}

let scanStream: MediaStream | null = null, scanLoop: ReturnType<typeof setTimeout> | null = null, scanDetector: BarcodeDetector | null = null;
async function openScan(onDetect?: unknown) {
  const onCode = typeof onDetect === "function" ? (onDetect as (isbn: string) => unknown) : null; // called via addEventListener too
  // Native BarcodeDetector where available (Android/Chrome); otherwise the
  // built-in EAN-13 decoder above (iOS Safari has no BarcodeDetector).
  scanDetector = null;
  if ("BarcodeDetector" in window) {
    try { scanDetector = new window.BarcodeDetector!({ formats: ["ean_13", "ean_8", "upc_a"] }); }
    catch (e: any) { try { scanDetector = new window.BarcodeDetector!(); } catch (e2) { scanDetector = null; } }
  }
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { toast("⚠️", "No camera access", "Type the ISBN instead."); return; }
  try { scanStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment", width: { ideal: 1280 } } }); }
  catch (e: any) { toast("⚠️", "Camera blocked", "Allow camera access, or type the ISBN."); return; }
  const v = $<HTMLVideoElement>("#scan-video");
  v.srcObject = scanStream;
  try { await v.play(); } catch (e: any) { /* ignore */ }
  showModal("scan-modal");
  const grabCanvas = document.createElement("canvas");
  scanLoop = setInterval(async () => {
    if (!scanStream) return;
    try {
      let raw = "";
      if (scanDetector) {
        const codes = await scanDetector.detect(v);
        if (codes && codes.length) raw = String(codes[0].rawValue || "").replace(/[^0-9Xx]/g, "");
      } else {
        raw = decodeEAN13FromVideo(v, grabCanvas) || "";
      }
      if (raw.length >= 10) {
        stopScan();
        $("#scan-modal").hidden = true;
        if (onCode) onCode(raw);
        else { $<HTMLInputElement>("#f-isbn").value = raw; handleFetch(); }
      }
    } catch (e: any) { /* keep scanning */ }
  }, scanDetector ? 500 : 350);
}
function stopScan() {
  if (scanLoop) clearInterval(scanLoop!);
  scanLoop = null;
  if (scanStream) { scanStream.getTracks().forEach((t) => t.stop()); scanStream = null; }
  const v = $<HTMLVideoElement>("#scan-video"); if (v) v.srcObject = null;
}

// "Scan to check" (Owned tab): am I holding a book I already have?
// (exposed as window.__checkScannedBook so it can be tested without a camera)
// Matches by ISBN first, then by the title Open Library reports for it.
// Pull "(Series Name, #3)" out of a Goodreads/OL-style title.
function parseSeriesFromTitle(title: string) {
  const m = String(title || "").match(/\(([^,(#]+?)[,]?\s*#\s*(\d+(?:\.\d+)?)\)\s*$/);
  return m ? { name: m[1].trim(), number: Number(m[2]) } : null;
}
// A one-line "how this book sits in a series you're collecting" note for the
// Should-I-Buy verdict — the thing Goodreads/Fable don't do in-hand.
function seriesInsight(seriesName: string, thisNumber: number | null) {
  if (!seriesName) return "";
  const inSeries = state.books.filter((b) => (b.seriesName || "").toLowerCase() === seriesName.toLowerCase());
  if (!inSeries.length) return "";
  const owned = inSeries.filter((b) => b.owned && b.seriesNumber != null).map((b) => b.seriesNumber!).sort((a, b) => a - b);
  const parts = [];
  parts.push(`You have ${inSeries.length} from <strong>${esc(seriesName)}</strong>` + (owned.length ? ` (own #${owned.join(", #")})` : "") + ".");
  if (thisNumber != null) {
    if (inSeries.some((b) => b.seriesNumber === thisNumber && b.owned)) parts.push(`You already own #${thisNumber}.`);
    else parts.push(`This is #${thisNumber}.`);
    if (inSeries.some((b) => b.seriesNumber === thisNumber - 1 && b.status !== "finished")) parts.push(`Heads up — you haven't read #${thisNumber - 1} yet.`);
  }
  return parts.join(" ");
}
async function checkScannedBook(isbn: string) {
  const digits = String(isbn || "").replace(/[^0-9Xx]/g, "");
  switchView("owned");
  const box = $("#owned-check-result");
  box.hidden = false;
  box.innerHTML = `<div class="own-verdict"><p class="muted">Looking up ${esc(digits)}…</p></div>`;
  const normT = (s: unknown) => String(s || "").toLowerCase().replace(/\s*\(.*?\)\s*$/, "").replace(/\s*:.*$/, "").trim();
  let hit = state.books.find((b) => (b.isbn || "").replace(/[^0-9Xx]/g, "") === digits);
  let scanTitle = "", scanAuthor = "";
  if (!hit) {
    try {
      const docs = await searchOpenLibrary("", "", digits);
      if (docs[0]) { scanTitle = docs[0].title || ""; scanAuthor = (docs[0].author_name || [])[0] || ""; }
    } catch (e: any) { /* offline — fall through to ISBN-only verdict */ }
    if (scanTitle) {
      const c = normT(scanTitle);
      hit = state.books.find((b) => { const a = normT(b.title); return a && c && (a === c || a.includes(c) || c.includes(a)); });
    }
  }
  const fmtName = { physical: "a physical copy", ebook: "an e-book", audio: "an audiobook" };
  const parsed = parseSeriesFromTitle(scanTitle) || ({} as { name?: string; number?: number | null });
  const seriesName = (hit && hit.seriesName) || parsed.name || "";
  const seriesNum = hit && hit.seriesNumber != null ? hit.seriesNumber : (parsed.number != null ? parsed.number : null);
  const insight = seriesInsight(seriesName, seriesNum);
  const insightHTML = insight ? `<p class="own-verdict-series">📚 ${insight}</p>` : "";
  if (hit && hit.owned) {
    const extra = [];
    if (hit.format && hit.format !== "physical") extra.push(`You have this as ${fmtName[hit.format]}.`);
    if (hit.lentTo) extra.push(`📤 But it's lent to ${esc(hit.lentTo)} right now.`);
    box.innerHTML = `<div class="own-verdict have">
        <strong>✓ You own this — no need to buy</strong>
        <p>${fmtIcon(hit)}“${esc(hit.title)}” is on your home shelf${hit.location ? ` · 📍 ${esc(hit.location)}` : ""}.${extra.length ? " " + extra.join(" ") : ""}</p>
        ${insightHTML}
        <div class="own-verdict-actions">
          <button class="mini" data-action="detail" data-id="${hit.id}">Open book</button>
          <button class="mini" data-action="dismiss-check">Done</button>
        </div></div>`;
  } else if (hit) {
    const verb = { want: "📌 It's on your Want-to-Read list", reading: "📖 You're reading it right now", finished: "✅ You've already read it", dnf: "🚫 You set this one aside" }[hit.status] || "It's on your shelves";
    box.innerHTML = `<div class="own-verdict partial">
        <strong>${verb} — but you don't own a copy</strong>
        <p>“${esc(hit.title)}”${hit.status === "dnf" && hit.dnfReason ? ` — you noted: “${esc(hit.dnfReason)}”` : ""}.${hit.lentTo ? ` 📤 (Lent to ${esc(hit.lentTo)}.)` : ""}</p>
        ${insightHTML}
        <div class="own-verdict-actions">
          <button class="mini" data-action="detail" data-id="${hit.id}">Open book</button>
          <button class="mini" data-action="toggle-owned" data-id="${hit.id}">🏠 I own it now</button>
          <button class="mini" data-action="dismiss-check">Done</button>
        </div></div>`;
  } else {
    box.innerHTML = `<div class="own-verdict new">
        <strong>🆕 Not on your shelves — safe to buy</strong>
        <p>${scanTitle ? "“" + esc(scanTitle) + "”" + (scanAuthor ? " by " + esc(scanAuthor) : "") : "ISBN " + esc(digits)} isn't in your library.</p>
        ${insightHTML}
        <div class="own-verdict-actions">
          <button class="mini" data-action="scan-add" data-isbn="${esc(digits)}">＋ Add to Want to Read</button>
          <button class="mini" data-action="dismiss-check">Done</button>
        </div></div>`;
  }
}

// ---------------------------------------------------------------------------
// Star inputs
// ---------------------------------------------------------------------------
function paintStarSpans(container: HTMLElement, v: number) {
  $$("span", container).forEach((x) => {
    const n = Number(x.dataset.star);
    x.classList.toggle("on", n <= v);
    x.classList.toggle("half-on", n - 0.5 === v);
  });
}
function paintStars(container: HTMLElement, rating: number | null | undefined) {
  container.dataset.rating = String(rating);
  paintStarSpans(container, Number(rating));
}
// Click the left half of a star for a half-star rating (e.g. 3.5★).
function starValueFromEvent(e: MouseEvent, s: HTMLElement) {
  const rect = s.getBoundingClientRect();
  const half = (e.clientX - rect.left) < rect.width / 2;
  return Number(s.dataset.star) - (half ? 0.5 : 0);
}
function wireStars(container: HTMLElement, onSet: (v: number) => void) {
  container.addEventListener("click", (e) => { const s = (e.target as HTMLElement).closest<HTMLElement>("[data-star]"); if (!s) return; const v = starValueFromEvent(e, s); onSet(v); paintStars(container, v); });
  container.addEventListener("mousemove", (e) => { const s = (e.target as HTMLElement).closest<HTMLElement>("[data-star]"); if (!s) return; paintStarSpans(container, starValueFromEvent(e, s)); });
  container.addEventListener("mouseleave", () => paintStars(container, Number(container.dataset.rating)));
}

// ---------------------------------------------------------------------------
// Modal plumbing
// ---------------------------------------------------------------------------
function showModal(id: string) { $("#" + id).hidden = false; }
function closeModals() {
  stopScan();
  resetTimer();
  stopClubPoll(); // also closes any open club WebSocket
  $$(".modal-backdrop").forEach((m) => (m.hidden = true));
  $("#finish-modal-title").textContent = "Finish this book";
}

// ---------------------------------------------------------------------------
// Data import / export / file connect / Goodreads
// ---------------------------------------------------------------------------
function downloadBlob(text: string, filename: string) {
  const blob = new Blob([text], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = filename; a.click();
  URL.revokeObjectURL(url);
}
function exportJSON() {
  downloadBlob(JSON.stringify(state, null, 2), "enkelas-bookshelf.json");
  markExported();
  toast("⬇️", "Exported", "enkelas-bookshelf.json downloaded");
}
// Base64 helpers for bundling ePub bytes into the "export everything" file.
function bufToB64(buf: ArrayBuffer): string {
  const u8 = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000) as unknown as number[]);
  return btoa(s);
}
function b64ToBuf(s: string): ArrayBuffer {
  const bin = atob(s);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8.buffer;
}
// One file with EVERYTHING: books, preferences, and the eReader's ePubs
// (bookmarks, highlights and reading stats included) — a whole-life backup.
async function exportEverything() {
  const btn = $<HTMLButtonElement>("#btn-export-full");
  if (btn) { btn.disabled = true; btn.textContent = "Packing…"; }
  try {
    const bundle = {
      kind: "enkelas-full-backup", version: 1,
      exportedAt: new Date().toISOString(),
      appVersion: APP_VERSION,
      state,
      prefs: { theme: loadTheme() },
      epubs: [] as any[],
    };
    if (EReader && EReader.exportAll) {
      const recs = await EReader.exportAll();
      bundle.epubs = recs.map((r) => Object.assign({}, r, { data: bufToB64(r.data) }));
    }
    downloadBlob(JSON.stringify(bundle), "enkelas-bookshelf-full.json");
    markExported();
    toast("📦", "Everything exported", state.books.length + " books" + (bundle.epubs.length ? " + " + bundle.epubs.length + " ePub" + (bundle.epubs.length === 1 ? "" : "s") : ""));
  } catch (e: any) {
    console.warn(e);
    toast("⚠️", "Export failed", "Try the plain backup instead.");
  }
  if (btn) { btn.disabled = false; btn.textContent = "📦 Export everything"; }
}
function importJSON(file: File) {
  const reader = new FileReader();
  reader.onload = async () => {
    try {
      const data = JSON.parse(reader.result as string);
      const isFull = data && data.kind === "enkelas-full-backup";
      state = normalize(isFull ? data.state : data);
      knownBadges = new Set();
      commit();
      knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
      let epubNote = "";
      if (isFull && Array.isArray(data.epubs) && data.epubs.length && EReader && EReader.importAll) {
        try {
          await EReader.importAll(data.epubs.map((r: any) => Object.assign({}, r, { data: b64ToBuf(r.data) })));
          epubNote = " · " + data.epubs.length + " ePub" + (data.epubs.length === 1 ? "" : "s") + " restored";
        } catch (e2) { epubNote = " · ePubs couldn't be restored"; }
      }
      if (isFull && data.prefs && data.prefs.theme) {
        const th = data.prefs.theme === "dark" ? "dark" : "light";
        try { localStorage.setItem(THEME_KEY, th); } catch (e2) { /* ignore */ }
        applyTheme(th);
      }
      toast("⬆️", "Imported", state.books.length + " books loaded" + epubNote);
    } catch (e: any) { toast("⚠️", "Import failed", "That file isn't valid bookshelf JSON."); }
  };
  reader.readAsText(file);
}
async function connectFile() {
  if (!supportsFS) { toast("ℹ️", "Use Export / Import", "This browser can't link a file directly. Your data is saved in-browser."); return; }
  try {
    const [handle] = await window.showOpenFilePicker!({ types: [{ description: "JSON", accept: { "application/json": [".json"] } }], multiple: false })
      .catch(async () => { const h = await window.showSaveFilePicker!({ suggestedName: "bookshelf.json", types: [{ description: "JSON", accept: { "application/json": [".json"] } }] }); return [h]; });
    fileHandle = handle;
    const text = await (await handle.getFile()).text();
    if (text.trim()) { try { state = normalize(JSON.parse(text)); knownBadges = new Set(); } catch (e: any) { /* keep */ } }
    await persist();
    render();
    knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
    toast("🔗", "File connected", "Changes now save to your JSON file.");
  } catch (e: any) { if (e && e.name !== "AbortError") { console.warn(e); toast("⚠️", "Couldn't connect file", ""); } }
}

// Minimal RFC-4180-ish CSV parser (handles quotes and embedded commas/newlines).
function parseCSV(text: string) {
  const rows = []; let row = [], field = "", inQ = false, i = 0;
  text = text.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  while (i < text.length) {
    const c = text[i];
    if (inQ) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i += 2; continue; } inQ = false; i++; continue; }
      field += c; i++; continue;
    }
    if (c === '"') { inQ = true; i++; continue; }
    if (c === ",") { row.push(field); field = ""; i++; continue; }
    if (c === "\n") { row.push(field); rows.push(row); row = []; field = ""; i++; continue; }
    field += c; i++;
  }
  if (field.length || row.length) { row.push(field); rows.push(row); }
  return rows;
}
function importGoodreads(file: File) {
  const reader = new FileReader();
  reader.onload = () => {
    try {
      const text = String(reader.result || "");
      if (text.slice(0, 2) === "PK" && text.indexOf("\u0000") >= 0) {
        toast("⚠️", "That's not a CSV", "Looks like a Numbers/Excel file. In Numbers: File → Export To → CSV, then import that.");
        return;
      }
      const rows = parseCSV(text);
      if (rows.length < 2) throw 0;
      const header = rows[0].map((h) => h.trim());
      const idx = (name: string) => header.indexOf(name);
      const cTitle = idx("Title"), cAuthor = idx("Author"), cRating = idx("My Rating"),
        cPages = idx("Number of Pages"), cShelf = idx("Exclusive Shelf"), cShelves = idx("Bookshelves"),
        cReview = idx("My Review"), cDateRead = idx("Date Read"), cISBN = idx("ISBN"),
        cISBN13 = idx("ISBN13"), cYear = idx("Original Publication Year"), cOwned = idx("Owned Copies");
      if (cTitle < 0) throw 0;
      const clean = (s: string) => {
        let v = String(s == null ? "" : s).trim().replace(/^=/, "");
        if (v.length >= 2 && ((v[0] === '"' && v[v.length - 1] === '"') || (v[0] === "'" && v[v.length - 1] === "'"))) v = v.slice(1, -1);
        return v.trim();
      };
      const existing = new Set(state.books.map((b) => (b.title + "|" + b.author).toLowerCase()));
      let added = 0;
      for (let r = 1; r < rows.length; r++) {
        const row = rows[r];
        if (!row || row[cTitle] == null) continue;
        const title = clean(row[cTitle]); if (!title) continue;
        const author = cAuthor >= 0 ? clean(row[cAuthor]) : "";
        const key = (title + "|" + author).toLowerCase();
        if (existing.has(key)) continue;
        existing.add(key);
        const shelf = cShelf >= 0 ? clean(row[cShelf]) : "read";
        const status = shelf === "currently-reading" ? "reading"
          : shelf === "to-read" ? "want"
          : (shelf === "did-not-finish" || shelf === "dnf" || shelf === "abandoned") ? "dnf"
          : "finished";
        const rating = cRating >= 0 ? Number(clean(row[cRating])) || 0 : 0;
        const pages = cPages >= 0 ? Number(clean(row[cPages])) || 0 : 0;
        const isbn = (cISBN13 >= 0 && clean(row[cISBN13])) || (cISBN >= 0 && clean(row[cISBN])) || "";
        const dateRead = cDateRead >= 0 ? clean(row[cDateRead]) : "";
        const review = cReview >= 0 ? clean(row[cReview]).replace(/<br\s*\/?>/gi, "\n") : "";
        const year = cYear >= 0 ? Number(clean(row[cYear])) || null : null;
        const rawShelves = cShelves >= 0 ? parseList(clean(row[cShelves])) : [];
        const tags = rawShelves.filter((s) => !isJunkTag(s));
        const seriesShelf = rawShelves.map((s) => (s.match(SERIES_TAG) || [])[1]).find(Boolean);
        const seriesName = seriesShelf ? seriesShelf.replace(/[-_]+/g, " ").trim().replace(/\b\w/g, (c) => c.toUpperCase()) : "";
        // No "Date Read" in Goodreads means we genuinely don't know WHEN it
        // was read: leave finishedAt empty rather than stamping today, which
        // would count an old book toward this year's goals.
        const finishedAt = status === "finished" && dateRead ? new Date(dateRead).toISOString() : null;
        const book = {
          id: uid(), title, author, totalPages: pages, coverUrl: isbn ? coverFromIsbn(isbn) : "", isbn,
          review, description: "", tags, collections: [], format: "physical",
          seriesName, seriesNumber: null, publishedYear: year, quotes: [], readCount: 1, finishHistory: [],
          status, rating: rating || null, startedAt: null, finishedAt, addedAt: new Date().toISOString(), logs: [],
          owned: cOwned >= 0 ? (parseFloat(clean(row[cOwned]) || "0") || 0) > 0 : false,
        } as unknown as Book;
        if (status === "finished" && pages > 0 && finishedAt) book.logs.push({ id: uid(), date: finishedAt, pages, minutes: 0, mood: "", note: "Imported from Goodreads" });
        state.books.push(book);
        added++;
      }
      knownBadges = new Set();
      commit();
      knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
      toast("📥", "Goodreads import", added + " book" + (added === 1 ? "" : "s") + " added");
      if (added) backfillCovers(true);
    } catch (e: any) { console.warn(e); toast("⚠️", "Import failed", "That doesn't look like a Goodreads CSV export."); }
  };
  reader.readAsText(file);
}

// ---------------------------------------------------------------------------
// Event wiring
// ---------------------------------------------------------------------------
function switchView(view: string) {
  activeView = view;
  $$(".tab").forEach((t) => t.classList.toggle("active", t.dataset.view === view));
  $$(".view").forEach((v) => (v.hidden = v.id !== "view-" + view));
  // The book page is a real page: hide the app chrome (header/stats/tabs)
  // so it starts at the top with just the Back bar.
  document.body.classList.toggle("book-open", view === "book");
  if (view === "community") openCommunity();
}

function onMainClick(e: MouseEvent) {
  const actBtn = (e.target as HTMLElement).closest<HTMLElement>("[data-action]");
  if (actBtn) {
    const action = actBtn.dataset.action;
    if (action === "dismiss-check") { $("#owned-check-result").hidden = true; return; }
    if (action === "scan-add") { openBookModal({ status: "want" }); $<HTMLInputElement>("#f-isbn").value = actBtn.dataset.isbn || ""; if ($<HTMLInputElement>("#f-isbn").value) handleFetch(); return; }
    const book = state.books.find((b) => b.id === actBtn.dataset.id);
    if (!book) return;
    if (action === "log") openLogModal(book);
    else if (action === "detail") openBookPage(book);
    else if (action === "finish") openFinishModal(book);
    else if (action === "edit") openBookModal({ book });
    else if (action === "cover") { openBookModal({ book }); setTimeout(() => $<HTMLButtonElement>("#btn-fetch").focus(), 80); }
    else if (action === "rate") rateBook(book);
    else if (action === "start") { book.status = "reading"; book.startedAt = new Date().toISOString(); commit(); toast("📖", "Started reading", book.title); }
    else if (action === "bookmark") openBookmarkModal(book);
    else if (action === "toggle-owned") { book.owned = !book.owned; commit(); toast("🏠", book.owned ? "Added to your home shelf" : "Removed from your home shelf", book.title); }
    else if (action === "dnf") openDnfModal(book);
    else if (action === "edit-log") { const lg = book.logs.find((x) => x.id === actBtn.dataset.log); if (lg) openLogModal(book, lg); }
    else if (action === "del-log") { const lg = book.logs.find((x) => x.id === actBtn.dataset.log); if (lg && confirm(`Delete this log of ${num(lg.pages)} pages?`)) { book.logs = book.logs.filter((x) => x.id !== lg.id); commit(); toast("🗑", "Log removed", book.title); } }
    else if (action === "delete") { if (confirm(`Remove “${book.title}” from your bookshelf? This can't be undone.`)) { state.books = state.books.filter((b) => b.id !== book.id); commit(); toast("🗑", "Removed", book.title); } }
    return;
  }
  const tagChip = (e.target as HTMLElement).closest<HTMLElement>("[data-tag]");
  if (tagChip) {
    const tag = tagChip.dataset.tag!;
    leaveBookPage();
    if (activeView === "library") { libraryTag = tag; $<HTMLSelectElement>("#library-tag").value = tag; renderLibrary(); }
    else if (activeView === "want") { wantQuery = tag; $<HTMLInputElement>("#want-search").value = tag; renderWant(); }
    else { readingQuery = tag; $<HTMLInputElement>("#reading-search").value = tag; renderReading(); }
    return;
  }
  const colChip = (e.target as HTMLElement).closest<HTMLElement>("[data-collection]");
  if (colChip) {
    const col = colChip.dataset.collection!;
    leaveBookPage();
    if (activeView === "library") { libraryCollection = col; $<HTMLSelectElement>("#library-collection").value = col; renderLibrary(); }
    else { switchView("library"); libraryCollection = col; $<HTMLSelectElement>("#library-collection").value = col; renderLibrary(); }
    return;
  }
  const addBtn = (e.target as HTMLElement).closest<HTMLElement>("[data-add]");
  if (addBtn) { openBookModal({ status: addBtn.dataset.add as BookStatus }); return; }
  // Tapping anywhere else on a book card (or a Read-next pick) opens its detail page.
  const card = (e.target as HTMLElement).closest<HTMLElement>(".book-card[data-id], .rn-card[data-id]");
  if (card && !(e.target as HTMLElement).closest<HTMLElement>("button, a, input, select, textarea, details, summary, label")) {
    const book = state.books.find((b) => b.id === card.dataset.id);
    if (book) openBookPage(book);
  }
}

function init() {
  // Loaded by tests.html (which has no app shell) — expose helpers, skip UI wiring.
  if (!document.getElementById("main")) return;
  $("#tabs").addEventListener("click", (e) => {
    const tab = (e.target as HTMLElement).closest<HTMLElement>(".tab");
    if (!tab) return;
    if (activeView === "book") histCleanHash();
    switchView(tab.dataset.view!);
  });
  $("#main").addEventListener("click", onMainClick);

  // Search + filters
  $<HTMLInputElement>("#reading-search").addEventListener("input", (e) => { readingQuery = (e.target as HTMLInputElement).value.trim(); renderReading(); });
  $<HTMLInputElement>("#want-search").addEventListener("input", (e) => { wantQuery = (e.target as HTMLInputElement).value.trim(); renderWant(); });
  $<HTMLInputElement>("#library-search").addEventListener("input", (e) => { libraryQuery = (e.target as HTMLInputElement).value.trim(); renderLibrary(); });
  $<HTMLInputElement>("#owned-search").addEventListener("input", (e) => { ownedQuery = (e.target as HTMLInputElement).value.trim(); renderOwned(); });
  $<HTMLSelectElement>("#owned-location").addEventListener("change", (e) => { ownedLocation = (e.target as HTMLInputElement).value; renderOwned(); });
  $<HTMLButtonElement>("#owned-unread-btn").addEventListener("click", () => { ownedUnreadOnly = !ownedUnreadOnly; renderOwned(); });
  $<HTMLButtonElement>("#btn-scan-check").addEventListener("click", () => openScan(checkScannedBook));
  window.__checkScannedBook = checkScannedBook;
  $<HTMLSelectElement>("#library-tag").addEventListener("change", (e) => { libraryTag = (e.target as HTMLInputElement).value; renderLibrary(); });
  $<HTMLSelectElement>("#library-collection").addEventListener("change", (e) => { libraryCollection = (e.target as HTMLInputElement).value; renderLibrary(); });
  $<HTMLSelectElement>("#library-sort").addEventListener("change", renderLibrary);
  $<HTMLSelectElement>("#library-format").addEventListener("change", (e) => { libraryFormat = (e.target as HTMLInputElement).value; renderLibrary(); });
  $<HTMLSelectElement>("#library-rating").addEventListener("change", (e) => { libraryRating = Number((e.target as HTMLInputElement).value) || 0; renderLibrary(); });
  $("#library-view-toggle").addEventListener("click", (e) => { const b = (e.target as HTMLElement).closest<HTMLElement>("[data-libview]"); if (b) { libraryView = b.dataset.libview!; renderLibrary(); } });

  // Genre + collection quick-add chips
  $("#tag-suggest").addEventListener("click", (e) => { const chip = (e.target as HTMLElement).closest<HTMLElement>("[data-add-tag]"); if (!chip) return; const t = parseList($<HTMLInputElement>("#f-tags").value); t.push(chip.dataset.addTag!); $<HTMLInputElement>("#f-tags").value = parseList(t.join(",")).join(", "); renderTagHelpers(); });
  $("#collection-suggest").addEventListener("click", (e) => { const chip = (e.target as HTMLElement).closest<HTMLElement>("[data-add-collection]"); if (!chip) return; const t = parseList($<HTMLInputElement>("#f-collections").value); t.push(chip.dataset.addCollection!); $<HTMLInputElement>("#f-collections").value = parseList(t.join(",")).join(", "); renderTagHelpers(); });
  $<HTMLInputElement>("#f-tags").addEventListener("input", renderTagHelpers);
  $<HTMLButtonElement>("#btn-fetch-genres").addEventListener("click", () => fetchGenresForForm());
  $<HTMLInputElement>("#f-collections").addEventListener("input", renderTagHelpers);
  $<HTMLSelectElement>("#f-format").addEventListener("change", updatePagesLabel);

  // Detail modal actions
  $("#detail-body").addEventListener("click", (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>("[data-detail-action]");
    if (!btn) return;
    const book = state.books.find((x) => x.id === currentDetailId);
    if (!book) return;
    const act = btn.dataset.detailAction;
    if (act === "log") openLogModal(book);
    else if (act === "edit") openBookModal({ book });
    else if (act === "bookmark") openBookmarkModal(book);
    else if (act === "reread") openRereadModal(book);
    else if (act === "finish") openFinishModal(book);
    else if (act === "dnf") openDnfModal(book);
    else if (act === "rate") rateBook(book);
    else if (act === "recommend") openRecommendModal({ title: book.title, author: book.author, category: (book.tags || [])[0] || "", isbn: book.isbn, cover: book.coverUrl });
    else if (act === "toggle-owned") { book.owned = !book.owned; commit(); toast("🏠", book.owned ? "Added to your home shelf" : "Removed from your home shelf", book.title); }
    else if (act === "lend") openLendModal(book);
    else if (act === "lend-return") { const who = book.lentTo; book.lentTo = ""; book.lentAt = null; commit(); toast("↩", "Welcome back!", `“${book.title}” returned from ${who}`); }
    else if (act === "start") { book.status = "reading"; book.startedAt = new Date().toISOString(); commit(); toast("📖", "Started reading", book.title); }
    else if (act === "delete") { if (confirm(`Remove “${book.title}” from your bookshelf? This can't be undone.`)) { state.books = state.books.filter((x) => x.id !== book.id); currentDetailId = null; goBackFromBook(); commit(); toast("🗑", "Removed", book.title); } }
    else if (act === "share-card") { shareBookCard(book); }
    else if (act === "export-md") { downloadText(slugify(book.title) + "-journal.md", bookMarkdown(book)); toast("⬇️", "Journal exported", book.title + " as Markdown"); }
    else if (act === "edit-log") { const lg = book.logs.find((x) => x.id === btn.dataset.log); if (lg) openLogModal(book, lg); }
    else if (act === "del-log") { const lg = book.logs.find((x) => x.id === btn.dataset.log); if (lg && confirm(`Delete this log of ${num(lg.pages)} pages?`)) { book.logs = book.logs.filter((x) => x.id !== lg.id); commit(); refreshDetail(); toast("🗑", "Log removed", book.title); } }
    else if (act === "del-quote") { book.quotes = (book.quotes || []).filter((q) => q.id !== btn.dataset.quote); commit(); refreshDetail(); }
    else if (act === "del-journal") { book.journal = (book.journal || []).filter((j) => j.id !== btn.dataset.journal); commit(); refreshDetail(); }
    else if (act === "del-char") { book.characters = (book.characters || []).filter((c) => c.id !== btn.dataset.char); commit(); refreshDetail(); }
    else if (act === "del-vocab") { book.vocab = (book.vocab || []).filter((v) => v.id !== btn.dataset.vocab); commit(); refreshDetail(); }
  });
  $("#detail-body").addEventListener("submit", (e) => {
    const book = state.books.find((x) => x.id === currentDetailId);
    if (!book) return;
    if ((e.target as HTMLElement).id === "quote-form") {
      e.preventDefault();
      const text = $<HTMLInputElement>("#q-text").value.trim();
      if (!text) return;
      book.quotes = book.quotes || [];
      book.quotes.push({ id: uid(), text, page: $<HTMLInputElement>("#q-page").value ? Number($<HTMLInputElement>("#q-page").value) : null, at: new Date().toISOString() });
      commit(); refreshDetail();
      toast("❝", "Quote saved", book.title);
    } else if ((e.target as HTMLElement).id === "journal-form") {
      e.preventDefault();
      const text = $<HTMLInputElement>("#j-text").value.trim();
      if (!text) return;
      book.journal = book.journal || [];
      book.journal.push({ id: uid(), date: new Date().toISOString(), page: $<HTMLInputElement>("#j-page").value ? Number($<HTMLInputElement>("#j-page").value) : null, text });
      commit(); refreshDetail();
      toast("📓", "Journal entry added", book.title);
    } else if ((e.target as HTMLElement).id === "char-form") {
      e.preventDefault();
      const name = $<HTMLInputElement>("#char-name").value.trim();
      if (!name) return;
      book.characters = book.characters || [];
      book.characters.push({ id: uid(), name, desc: $<HTMLInputElement>("#char-desc").value.trim() });
      commit(); refreshDetail();
    } else if ((e.target as HTMLElement).id === "vocab-form") {
      e.preventDefault();
      const word = $<HTMLInputElement>("#vocab-word").value.trim();
      if (!word) return;
      book.vocab = book.vocab || [];
      book.vocab.push({ id: uid(), word, def: $<HTMLInputElement>("#vocab-def").value.trim(), page: $<HTMLInputElement>("#vocab-page").value ? Number($<HTMLInputElement>("#vocab-page").value) : null });
      commit(); refreshDetail();
    }
  });

  // Book modal
  $<HTMLFormElement>("#book-form").addEventListener("submit", saveBookFromForm);
  $<HTMLButtonElement>("#btn-fetch").addEventListener("click", handleFetch);
  $<HTMLButtonElement>("#btn-scan").addEventListener("click", openScan);
  $<HTMLInputElement>("#f-cover").addEventListener("input", (e) => setCoverPreview((e.target as HTMLInputElement).value.trim()));
  $("#cover-candidates").addEventListener("click", (e) => {
    const card = (e.target as HTMLElement).closest<HTMLElement>("[data-doc-idx]");
    if (!card) return;
    const doc = lastSearchDocs[Number(card.dataset.docIdx)];
    if (!doc) return;
    $$("#cover-candidates .cand").forEach((c) => c.classList.remove("sel"));
    card.classList.add("sel");
    applyDoc(doc, { overwrite: true });
    toast("✨", "Details filled in", doc.title || "Book selected");
  });
  $$<HTMLInputElement>("input[name='f-status']").forEach((r) => r.addEventListener("change", () => toggleStatusFields(r.value)));
  wireStars($("#f-stars"), (v) => (modalRating = v));

  // Log + finish
  $<HTMLFormElement>("#log-form").addEventListener("submit", saveLog);
  $<HTMLInputElement>("#log-pages").addEventListener("input", updateLogPageHint);
  $<HTMLFormElement>("#finish-form").addEventListener("submit", saveFinish);
  $<HTMLButtonElement>("#timer-btn").addEventListener("click", toggleTimer);
  wireStars($("#finish-stars"), (v) => (finishRating = v));

  // Goals
  $<HTMLButtonElement>("#goal-save").addEventListener("click", () => {
    state.settings.goal = {
      year: Number($<HTMLInputElement>("#goal-year").value) || new Date().getFullYear(),
      target: Number($<HTMLInputElement>("#goal-target").value) || 0,
      pagesTarget: Number($<HTMLInputElement>("#goal-pages").value) || 0,
      dailyPages: Number($<HTMLInputElement>("#goal-daily").value) || 0,
    };
    commit();
    checkNewBadges();
    toast("🎯", "Goals saved", state.settings.goal.target + " books in " + state.settings.goal.year);
  });

  // Year in Review + monthly recap
  $<HTMLButtonElement>("#btn-year-review").addEventListener("click", () => openYearReview(new Date().getFullYear()));
  $("#year-body").addEventListener("click", (e) => {
    const act = (e.target as HTMLElement).closest<HTMLElement>("[data-yr-action]");
    if (act) {
      const y = Number(act.dataset.year);
      if (act.dataset.yrAction === "image") shareYearCard(y);
      else { downloadText("my-" + y + "-in-books.md", yearMarkdown(y)); toast("⬇️", "Year journal exported", y + " as Markdown"); }
      return;
    }
    const b = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-year-nav]");
    if (b && !b.disabled) openYearReview(Number(b.dataset.yearNav));
  });
  $<HTMLButtonElement>("#btn-month-recap").addEventListener("click", () => { const n = new Date(); openMonthlyRecap(n.getFullYear(), n.getMonth()); });
  $<HTMLButtonElement>("#btn-snapshot").addEventListener("click", shareSnapshotCard);
  $("#month-body").addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-month-nav]");
    if (b && !b.disabled) { const [y, m] = b.dataset.monthNav!.split("-").map(Number); openMonthlyRecap(y, m); }
  });

  // Mood picker in the log dialog
  $("#mood-row").addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest<HTMLElement>("[data-mood]");
    if (!b) return;
    paintMood($<HTMLInputElement>("#log-mood").value === b.dataset.mood ? "" : b.dataset.mood!);
  });

  // Bookmark + DNF dialogs
  $<HTMLFormElement>("#bookmark-form").addEventListener("submit", saveBookmark);
  $<HTMLFormElement>("#lend-form").addEventListener("submit", saveLend);
  $<HTMLButtonElement>("#bm-clear").addEventListener("click", clearBookmark);
  $<HTMLFormElement>("#dnf-form").addEventListener("submit", saveDnf);

  // Bookshelf drag & drop
  setupShelfDnD($("#library-list"));

  // Built-in eReader
  $<HTMLButtonElement>("#btn-ereader").addEventListener("click", () => {
    if (EReader) EReader.openLibrary();
    else toast("⚠️", "eReader unavailable", "The reader script didn't load.");
  });

  // Data menu
  $<HTMLButtonElement>("#btn-export").addEventListener("click", exportJSON);
  $<HTMLButtonElement>("#btn-import").addEventListener("click", () => $<HTMLInputElement>("#import-input").click());
  $<HTMLInputElement>("#import-input").addEventListener("change", (e) => { if ((e.target as HTMLInputElement).files![0]) importJSON((e.target as HTMLInputElement).files![0]); (e.target as HTMLInputElement).value = ""; });
  $<HTMLButtonElement>("#btn-goodreads").addEventListener("click", () => $<HTMLInputElement>("#goodreads-input").click());
  $<HTMLInputElement>("#goodreads-input").addEventListener("change", (e) => { if ((e.target as HTMLInputElement).files![0]) importGoodreads((e.target as HTMLInputElement).files![0]); (e.target as HTMLInputElement).value = ""; });
  $<HTMLButtonElement>("#btn-connect-file").addEventListener("click", connectFile);
  $<HTMLButtonElement>("#btn-theme").addEventListener("click", toggleTheme);

  // Settings / data safety
  $<HTMLButtonElement>("#btn-settings").addEventListener("click", openSettings);
  $("#storage-status").addEventListener("click", openSettings);
  $("#storage-status").addEventListener("keydown", (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openSettings(); } });
  $<HTMLButtonElement>("#btn-clear-data").addEventListener("click", clearLocalData);
  $<HTMLButtonElement>("#btn-refresh-app").addEventListener("click", refreshAppFiles);
  $<HTMLButtonElement>("#btn-export-full").addEventListener("click", exportEverything);
  $<HTMLButtonElement>("#btn-conflicts").addEventListener("click", () => { closeModals(); openConflicts(); });
  $<HTMLButtonElement>("#btn-shelf-doctor").addEventListener("click", () => { closeModals(); openShelfDoctor(); });
  // Reading clubs
  $<HTMLButtonElement>("#btn-clubs").addEventListener("click", () => { closeModals(); openClubs(); });
  $("#clubs-body").addEventListener("click", (e) => {
    const react = (e.target as HTMLElement).closest<HTMLElement>("[data-react]"); if (react) { toggleReaction(react.dataset.comment!, react.dataset.react!); return; }
    const open = (e.target as HTMLElement).closest<HTMLElement>("[data-club-open]"); if (open) { openClub(open.dataset.clubOpen!); return; }
    if ((e.target as HTMLElement).closest<HTMLElement>("[data-club-back]")) { renderClubsListScreen(); return; }
    const leave = (e.target as HTMLElement).closest<HTMLElement>("[data-club-leave]");
    if (leave) { if (confirm("Leave this club? You can rejoin later with the code.")) clubApi("/" + leave.dataset.clubLeave + "/leave", { method: "POST" }).then(() => { toast("👋", "Left the club", ""); renderClubsListScreen(); }); return; }
    const share = (e.target as HTMLElement).closest<HTMLElement>("[data-club-share]");
    if (share && share.dataset.clubShare) { shareClubInvite(share.dataset.clubShare, share.dataset.clubShareTitle || ""); return; }
    const copy = (e.target as HTMLElement).closest<HTMLElement>("[data-club-copy]");
    if (copy && copy.dataset.clubCopy) { try { navigator.clipboard.writeText(copy.dataset.clubCopy); } catch (e2) { /* ignore */ } toast("📋", "Invite code copied", copy.dataset.clubCopy); return; }
  });
  $("#clubs-body").addEventListener("submit", (e) => {
    e.preventDefault();
    if ((e.target as HTMLElement).id === "club-create-form") {
      const title = $<HTMLInputElement>("#club-book-title").value.trim(); if (!title) return;
      clubApi("", { method: "POST", body: JSON.stringify({ bookTitle: title, bookAuthor: $<HTMLInputElement>("#club-book-author").value.trim(), displayName: clubDisplayName() }) })
        .then(({ res, data }) => { if (res.ok && data.clubId) { toast("👥", "Club created", "Invite code " + data.joinCode); openClub(data.clubId); } else toast("⚠️", "Couldn't create the club", (data && data.error) || ""); });
    } else if ((e.target as HTMLElement).id === "club-join-form") {
      const code = $<HTMLInputElement>("#club-join-code").value.trim().toUpperCase(); if (!code) return;
      joinClubByCode(code);
    } else if ((e.target as HTMLElement).id === "club-comment-form") {
      postClubComment();
    }
  });
  $("#clubs-body").addEventListener("input", (e) => { if ((e.target as HTMLElement).id === "club-progress-range") { const v = $("#club-my-pct"); if (v) v.textContent = (e.target as HTMLInputElement).value; } });
  $("#clubs-body").addEventListener("change", (e) => { if ((e.target as HTMLElement).id === "club-progress-range") setClubProgress(Number((e.target as HTMLInputElement).value) || 0); });

  // Community recommendations
  $<HTMLButtonElement>("#btn-recommend").addEventListener("click", () => openRecommendModal());
  $<HTMLFormElement>("#recommend-form").addEventListener("submit", (e) => { e.preventDefault(); submitRecommend(); });
  $<HTMLSelectElement>("#community-category").addEventListener("change", (e) => { communityCategory = (e.target as HTMLInputElement).value; drawCommunity(); });
  $<HTMLSelectElement>("#community-sort").addEventListener("change", (e) => { communitySort = (e.target as HTMLInputElement).value; drawCommunity(); });
  $<HTMLInputElement>("#community-hide-read").addEventListener("change", (e) => { communityHideRead = (e.target as HTMLInputElement).checked; drawCommunity(); });
  $("#community-body").addEventListener("click", (e) => {
    if ((e.target as HTMLElement).closest<HTMLElement>("[data-community-signin]")) { closeModals(); openAuthModal("login"); return; }
    if ((e.target as HTMLElement).closest<HTMLElement>("[data-community-showread]")) { communityHideRead = false; const cb = $<HTMLInputElement>("#community-hide-read"); if (cb) cb.checked = false; drawCommunity(); return; }
    const card = (e.target as HTMLElement).closest<HTMLElement>("[data-rec]");
    if (!card) return;
    const id = card.dataset.rec;
    if ((e.target as HTMLElement).closest<HTMLElement>("[data-rec-del]")) { deleteRec(id!); return; }
    const vote = (e.target as HTMLElement).closest<HTMLElement>("[data-vote]");
    if (vote) voteRec(id!, Number(vote.dataset.vote));
  });
  $<HTMLButtonElement>("#btn-doctor-covers").addEventListener("click", async (e) => {
    const btn = e.currentTarget as HTMLButtonElement; btn.disabled = true; btn.textContent = "Searching…";
    await backfillCovers(true);
    btn.disabled = false; btn.textContent = "🔍 Find all missing covers";
    renderShelfDoctor();
  });
  $("#doctor-body").addEventListener("click", async (e) => {
    const mg = (e.target as HTMLElement).closest<HTMLElement>("[data-doctor-merge]");
    if (mg) { const g = duplicateGroups().find((x) => x.key === mg.dataset.doctorMerge); if (g) mergeDuplicateGroup(g.books); return; }
    const fx = (e.target as HTMLElement).closest<HTMLButtonElement>("[data-doctor-fix]");
    if (!fx) return;
    const book = state.books.find((b) => b.id === fx.dataset.id);
    if (!book) return;
    const fix = fx.dataset.doctorFix;
    if (fix === "edit") { closeModals(); openBookModal({ book }); return; }
    if (fix === "cover") {
      fx.disabled = true; fx.textContent = "Finding…";
      try {
        const url = await findCoverFor(book);
        if (url) { book.coverUrl = url; commit(); toast("🖼", "Cover found", book.title); renderShelfDoctor(); }
        else { toast("🔍", "No cover found", "Try editing and pasting one."); fx.disabled = false; fx.textContent = "🔍 Find cover"; }
      } catch (err: any) { toast("⚠️", "Lookup failed", "Check your connection."); fx.disabled = false; fx.textContent = "🔍 Find cover"; }
      return;
    }
    if (fix === "genres") {
      fx.disabled = true; fx.textContent = "Fetching…";
      try {
        const picks = await fetchGenresForBook(book);
        if (picks.length) {
          const have = new Set((book.tags || []).map((x) => x.toLowerCase()));
          picks.forEach((p) => { if (!have.has(p.toLowerCase())) { have.add(p.toLowerCase()); book.tags.push(p); } });
          commit(); toast("🏷️", "Genres added", picks.join(", ")); renderShelfDoctor();
        } else { toast("🔍", "No genres found", "Add a couple by hand."); fx.disabled = false; fx.textContent = "✨ Fetch genres"; }
      } catch (err: any) { toast("⚠️", "Couldn't fetch genres", "Check your connection."); fx.disabled = false; fx.textContent = "✨ Fetch genres"; }
      return;
    }
  });
  $("#settings-modal").addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest<HTMLElement>("[data-settings-action]");
    if (!b) return;
    const act = b.dataset.settingsAction;
    if (act === "signin") { closeModals(); openAuthModal("login"); }
    else if (act === "signout") logout();
    else if (act === "syncnow") { toast("🔄", "Syncing…", ""); pullData(); }
  });

  // PWA install + first-run onboarding
  window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); deferredInstallPrompt = e; updateInstallUI(); });
  window.addEventListener("appinstalled", () => { deferredInstallPrompt = null; updateInstallUI(); toast("📲", "Installed!", "Enkela's Bookshelf is on your home screen now."); });
  $<HTMLButtonElement>("#btn-install-app").addEventListener("click", promptInstall);
  $("#onboard-modal").addEventListener("click", (e) => {
    const b = (e.target as HTMLElement).closest<HTMLElement>("[data-onboard]");
    if (!b) return;
    const act = b.dataset.onboard;
    finishOnboarding();
    closeModals();
    if (act === "goodreads") $<HTMLInputElement>("#goodreads-input").click();
    else if (act === "add") openBookModal({ status: "reading" });
    else if (act === "goal") switchView("goals");
    else if (act === "install") promptInstall();
  });

  // Accounts + sync
  if (syncEnabled()) {
    $<HTMLButtonElement>("#btn-account").addEventListener("click", () => {
      if (auth) { const m = $("#account-menu"); m.hidden = !m.hidden; }
      else openAuthModal("login");
    });
    $<HTMLButtonElement>("#am-sync").addEventListener("click", () => { closeAccountMenu(); toast("🔄", "Syncing…", ""); pullData(); });
    $<HTMLButtonElement>("#am-settings").addEventListener("click", openSettings);
    $<HTMLButtonElement>("#am-signout").addEventListener("click", logout);
    $<HTMLButtonElement>("#tab-login").addEventListener("click", () => setAuthMode("login"));
    $<HTMLButtonElement>("#tab-register").addEventListener("click", () => setAuthMode("register"));
    $<HTMLFormElement>("#auth-form").addEventListener("submit", onAuthSubmit);
    document.addEventListener("click", (e) => { if (!(e.target as HTMLElement).closest<HTMLElement>("#account-wrap")) closeAccountMenu(); });
  }

  // Modal close
  $$(".modal-backdrop").forEach((m) => m.addEventListener("click", (e) => { if (e.target === m) closeModals(); }));
  document.addEventListener("click", (e) => { if ((e.target as HTMLElement).closest<HTMLElement>("[data-close-modal]")) closeModals(); });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    const hadOpenModal = $$(".modal-backdrop").some((m) => !m.hidden);
    closeModals();
    if (!hadOpenModal && activeView === "book") goBackFromBook();
  });

  // Book page navigation
  $<HTMLButtonElement>("#btn-book-back").addEventListener("click", goBackFromBook);
  window.addEventListener("popstate", () => {
    const m = (location.hash || "").match(/^#book\/(.+)$/);
    const b = m && state.books.find((x) => x.id === decodeURIComponent(m[1]));
    if (b) openBookPage(b, { push: false });
    else closeBookPage();
  });

  if (!supportsFS) $<HTMLButtonElement>("#btn-connect-file").style.display = "none";

  // We restore list scroll positions ourselves when leaving a book page —
  // stop the browser fighting us on popstate.
  try { history.scrollRestoration = "manual"; } catch (e: any) { /* ignore */ }
  applyTheme(loadTheme());
  render();
  knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
  switchView("reading");
  // Deep link: reopening the app on a #book/<id> URL lands on that book's page.
  const deepLink = (location.hash || "").match(/^#book\/(.+)$/);
  const deepBook = deepLink && state.books.find((x) => x.id === decodeURIComponent(deepLink[1]));
  if (deepBook) openBookPage(deepBook, { push: false });
  else if (deepLink) histCleanHash();
  // Deep link: a #join/CODE invite URL joins that club (after sign-in if needed).
  const joinLink = (location.hash || "").match(/^#join\/([A-Za-z0-9]{4,12})$/i);
  if (joinLink) {
    histCleanHash();
    const code = joinLink[1].toUpperCase();
    if (syncEnabled() && auth) { if (openClubsShell()) joinClubByCode(code); }
    else if (syncEnabled()) {
      try { localStorage.setItem(PENDING_JOIN_KEY, code); } catch (e: any) { /* ignore */ }
      openAuthModal("login");
      toast("👥", "You've been invited to a club", "Sign in and you'll join automatically.");
    }
  }
  renderAccount();
  if (syncEnabled() && auth) pullData();
  setupAutoSync();
  setupOfflineAndPersistence();
  maybeShowMonthlyRecap();
  maybeShowOnboarding();
  // After the app settles (and any sync pull has a head start), quietly
  // fill in covers that the Goodreads import / ISBN lookup couldn't find.
  setTimeout(() => backfillCovers(), 3000);
  setTimeout(() => maybeBackupReminder(), 8000);
}

// Small bridge so the eReader (reader.js) can list books and save sessions.
export const BookshelfAPI = {
  getBooks() {
    return state.books
      .filter((b) => b.status === "reading" || b.status === "want")
      .concat(state.books.filter((b) => b.status === "finished" || b.status === "dnf"))
      .map((b) => ({ id: b.id, title: b.title, author: b.author, totalPages: b.totalPages, status: b.status }));
  },
  addReadingLog(bookId: string, entry: { pages?: number; minutes?: number; note?: string }) {
    const b = state.books.find((x) => x.id === bookId);
    if (!b) return false;
    if (b.status === "want") { b.status = "reading"; b.startedAt = b.startedAt || new Date().toISOString(); }
    b.logs.push({
      id: uid(), date: new Date().toISOString(),
      pages: Math.max(0, Math.round(entry.pages || 0)),
      minutes: Math.max(0, Math.round(entry.minutes || 0)),
      mood: "", note: entry.note || "📖 eReader session",
    });
    commit();
    checkNewBadges();
    toast("📖", "Session saved", Math.round(entry.minutes || 0) + " min added to “" + b.title + "”");
    return true;
  },
  // Live session logging: the reader calls this every minute while reading,
  // updating ONE log in place (no toast — the reader announces the session
  // itself when it ends). Returns the log id to pass back on the next call.
  upsertReadingLog(bookId: string, logId: string | null | undefined, entry: { pages?: number; minutes?: number; note?: string }) {
    const b = state.books.find((x) => x.id === bookId);
    if (!b) return null;
    if (b.status === "want") { b.status = "reading"; b.startedAt = b.startedAt || new Date().toISOString(); }
    let lg = logId ? b.logs.find((x) => x.id === logId) : null;
    if (!lg) { lg = { id: uid(), date: new Date().toISOString(), pages: 0, minutes: 0, mood: "", note: "" }; b.logs.push(lg); }
    lg.date = new Date().toISOString();
    lg.pages = Math.max(0, Math.round(entry.pages || 0));
    lg.minutes = Math.max(0, Math.round(entry.minutes || 0));
    lg.note = entry.note || lg.note || "📖 eReader session";
    commit();
    checkNewBadges();
    return lg.id;
  },
  // The reader's "save quote" lands the selection straight on the linked book.
  addQuote(bookId: string, text: string) {
    const b = state.books.find((x) => x.id === bookId);
    const t = String(text || "").trim();
    if (!b || !t) return false;
    b.quotes = b.quotes || [];
    b.quotes.push({ id: uid(), text: t.slice(0, 2000), page: null, at: null });
    commit();
    return true;
  },
  // Reading streak for the reader's session summary.
  streak() { return readingStreak(); },
};
window.BookshelfAPI = BookshelfAPI; // kept on window for console + backwards-compat

// Pure(ish) helpers exposed for the no-build test harness (tests.html).
window.__test = { normalize, parseCSV, bookMatches, isJunkTag, authorMatches, cleanSubjects, parseList, readingStreak, readNextPicks, bufToB64, b64ToBuf };

document.addEventListener("DOMContentLoaded", init);
document.addEventListener("DOMContentLoaded", initReader); // reader wires up second, matching the old script order
