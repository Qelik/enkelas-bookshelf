/* Enkela's Bookshelf — a no-backend reading tracker.
 * Data lives in a single JSON object, auto-saved to localStorage, and
 * optionally synced to a real bookshelf.json file via the File System Access API.
 */
(function () {
  "use strict";

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------
  const STORAGE_KEY = "enkelas-bookshelf-v1";
  const THEME_KEY = "enkelas-bookshelf-theme";
  const SCHEMA_VERSION = 1;
  const DAY = 86400000;
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

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  let state = loadState();
  let fileHandle = null;
  let knownBadges = new Set();
  let activeView = "reading";
  let storagePersisted = false;
  let readingQuery = "", wantQuery = "", libraryQuery = "";
  let libraryTag = "", libraryCollection = "", libraryView = "grid";
  let currentDetailId = null;
  let yearReviewYear = new Date().getFullYear();

  const supportsFS = "showSaveFilePicker" in window && "showOpenFilePicker" in window;

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

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
  function toLocalInput(iso) {
    const d = new Date(iso);
    if (isNaN(d)) return nowLocalInput();
    d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
    return d.toISOString().slice(0, 16);
  }
  function startOfDay(date) { const d = new Date(date); d.setHours(0, 0, 0, 0); return d.getTime(); }
  function fmtDate(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
  }
  function fmtDateTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    return d.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
  }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
  function num(n) { return Number(n || 0).toLocaleString(); }
  function unitLabel(book) { return book && book.format === "audio" ? "min" : "pages"; }
  function unitShort(book) { return book && book.format === "audio" ? "m" : "p"; }
  function hashHue(str) { let h = 0; for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) >>> 0; return h % 360; }

  function parseList(str) {
    const seen = new Set(), out = [];
    String(str || "").split(",").forEach((t) => {
      const v = t.trim(), key = v.toLowerCase();
      if (v && !seen.has(key)) { seen.add(key); out.push(v); }
    });
    return out;
  }
  const parseTags = parseList;
  function uniqueValues(getter) {
    const seen = new Map();
    state.books.forEach((b) => (getter(b) || []).forEach((t) => {
      const key = String(t).toLowerCase();
      if (!seen.has(key)) seen.set(key, t);
    }));
    return Array.from(seen.values()).sort((a, b) => a.localeCompare(b));
  }
  function allTags() { return uniqueValues((b) => b.tags); }
  function allCollections() { return uniqueValues((b) => b.collections); }

  function bookMatches(book, q) {
    if (!q) return true;
    q = q.toLowerCase();
    return book.title.toLowerCase().includes(q)
      || (book.author || "").toLowerCase().includes(q)
      || (book.seriesName || "").toLowerCase().includes(q)
      || (book.tags || []).some((t) => t.toLowerCase().includes(q))
      || (book.collections || []).some((t) => t.toLowerCase().includes(q));
  }
  function fmtIcon(b) { return `<span class="fmt" title="${b.format || "physical"}">${FORMAT_ICON[b.format] || FORMAT_ICON.physical}</span> `; }
  function seriesLabel(b) { return b.seriesName ? ` · <span class="series">${esc(b.seriesName)}${b.seriesNumber ? " #" + b.seriesNumber : ""}</span>` : ""; }
  function chipsHTML(book, clickable) {
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
  function defaultState() {
    return {
      version: SCHEMA_VERSION,
      settings: { goal: { year: new Date().getFullYear(), target: 12, pagesTarget: 0, dailyPages: 0 } },
      books: [],
    };
  }
  function loadState() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return defaultState();
      return normalize(JSON.parse(raw));
    } catch (e) {
      console.warn("Could not load saved data, starting fresh.", e);
      return defaultState();
    }
  }
  function normalize(data) {
    const base = defaultState();
    if (!data || typeof data !== "object") return base;
    base.settings.goal = Object.assign(base.settings.goal, (data.settings && data.settings.goal) || {});
    const STATUSES = ["want", "reading", "finished", "dnf"];
    base.books = Array.isArray(data.books) ? data.books.map((b) => ({
      id: b.id || uid(),
      title: b.title || "Untitled",
      author: b.author || "",
      totalPages: Number(b.totalPages) || 0,
      coverUrl: b.coverUrl || "",
      isbn: b.isbn || "",
      review: b.review || "",
      description: b.description || "",
      tags: Array.isArray(b.tags) ? b.tags.map((t) => String(t).trim()).filter(Boolean) : [],
      collections: Array.isArray(b.collections) ? b.collections.map((t) => String(t).trim()).filter(Boolean) : [],
      format: ["physical", "ebook", "audio"].indexOf(b.format) >= 0 ? b.format : "physical",
      seriesName: b.seriesName || "",
      seriesNumber: b.seriesNumber != null && b.seriesNumber !== "" ? Number(b.seriesNumber) : null,
      publishedYear: b.publishedYear ? Number(b.publishedYear) : null,
      quotes: Array.isArray(b.quotes) ? b.quotes.map((q) => ({ id: q.id || uid(), text: q.text || "", page: q.page != null ? Number(q.page) : null })) : [],
      readCount: Number(b.readCount) || 1,
      finishHistory: Array.isArray(b.finishHistory) ? b.finishHistory : [],
      status: STATUSES.indexOf(b.status) >= 0 ? b.status : "reading",
      rating: b.rating ? Number(b.rating) : null,
      startedAt: b.startedAt || null,
      finishedAt: b.finishedAt || null,
      addedAt: b.addedAt || new Date().toISOString(),
      logs: Array.isArray(b.logs) ? b.logs.map((l) => ({
        id: l.id || uid(),
        date: l.date || new Date().toISOString(),
        pages: Number(l.pages) || 0,
        minutes: Number(l.minutes) || 0,
        note: l.note || "",
      })) : [],
    })) : [];
    return base;
  }

  async function persist() {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch (e) { console.warn(e); }
    if (fileHandle) {
      try {
        const writable = await fileHandle.createWritable();
        await writable.write(JSON.stringify(state, null, 2));
        await writable.close();
      } catch (e) {
        console.warn("File write failed:", e);
        toast("⚠️", "Couldn't write file", "Falling back to in-browser storage.");
        fileHandle = null;
        renderStorageStatus();
      }
    }
  }
  function commit() { render(); persist(); }

  // ---------------------------------------------------------------------------
  // Theme
  // ---------------------------------------------------------------------------
  function loadTheme() { try { return localStorage.getItem(THEME_KEY) === "dark" ? "dark" : "light"; } catch (e) { return "light"; } }
  function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    const btn = $("#btn-theme");
    if (btn) { btn.textContent = theme === "dark" ? "☀️" : "🌙"; btn.title = theme === "dark" ? "Switch to light mode" : "Switch to dark mode"; }
  }
  function toggleTheme() {
    const next = loadTheme() === "dark" ? "light" : "dark";
    try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* ignore */ }
    applyTheme(next);
  }

  // ---------------------------------------------------------------------------
  // Offline + persistent storage
  // ---------------------------------------------------------------------------
  async function setupOfflineAndPersistence() {
    if ("serviceWorker" in navigator && location.protocol.indexOf("http") === 0) {
      try { await navigator.serviceWorker.register("sw.js"); } catch (e) { /* ignore */ }
    }
    if (navigator.storage && navigator.storage.persist) {
      try {
        storagePersisted = await navigator.storage.persisted();
        if (!storagePersisted) storagePersisted = await navigator.storage.persist();
      } catch (e) { /* ignore */ }
    }
    renderStorageStatus();
  }

  // ---------------------------------------------------------------------------
  // Derived values
  // ---------------------------------------------------------------------------
  function pagesRead(book) { return book.logs.reduce((s, l) => s + (Number(l.pages) || 0), 0); }
  function totalPagesRead() { return state.books.reduce((s, b) => s + pagesRead(b), 0); }
  function booksFinished() { return state.books.filter((b) => b.status === "finished"); }
  function libraryBooks() { return state.books.filter((b) => b.status === "finished" || b.status === "dnf"); }
  function booksFinishedInYear(year) {
    return booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt).getFullYear() === year).length;
  }
  function pagesReadInYear(year) {
    let s = 0;
    state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d) && d.getFullYear() === year) s += Number(l.pages) || 0; }));
    return s;
  }
  function pagesOnDay(t) {
    let s = 0;
    state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d) && startOfDay(d) === t) s += Number(l.pages) || 0; }));
    return s;
  }
  function perDayMap() {
    const m = {};
    state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d)) { const k = startOfDay(d); m[k] = (m[k] || 0) + (Number(l.pages) || 0); } }));
    return m;
  }
  function readingDaySet() {
    const days = new Set();
    state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d)) days.add(startOfDay(d)); }));
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
  function estimateFinish(book) {
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
    const finishedYr = booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt).getFullYear() === year);
    const genresYr = new Set(); finishedYr.forEach((b) => (b.tags || []).forEach((t) => genresYr.add(t.toLowerCase())));
    const chunky = state.books.some((b) => b.status === "finished" && b.totalPages >= 500);
    const decades = new Set(); state.books.filter((b) => b.status === "finished" && b.publishedYear).forEach((b) => decades.add(Math.floor(b.publishedYear / 10)));
    const reviews = state.books.filter((b) => b.review && b.review.trim()).length;
    const monthsRead = new Set(); finishedYr.forEach((b) => monthsRead.add(new Date(b.finishedAt).getMonth()));
    const fiveStar = state.books.some((b) => b.rating === 5);
    const speed = state.books.some((b) => b.status === "finished" && b.startedAt && b.finishedAt && (() => { const d = (new Date(b.finishedAt) - new Date(b.startedAt)) / DAY; return d >= 0 && d <= 7; })());
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
    if (window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches) return;
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
  function coverFromId(id, size) { return `https://covers.openlibrary.org/b/id/${id}-${size || "L"}.jpg`; }
  function coverFromIsbn(isbn, size) { return `https://covers.openlibrary.org/b/isbn/${encodeURIComponent(isbn)}-${size || "L"}.jpg`; }
  async function searchOpenLibrary(title, author, isbn) {
    const params = new URLSearchParams();
    if (isbn) params.set("isbn", isbn.replace(/[^0-9Xx]/g, ""));
    if (title) params.set("title", title);
    if (author) params.set("author", author);
    params.set("limit", "6");
    params.set("fields", "key,title,author_name,cover_i,number_of_pages_median,first_publish_year,isbn,subject");
    const res = await fetch("https://openlibrary.org/search.json?" + params.toString());
    if (!res.ok) throw new Error("Search failed");
    const data = await res.json();
    return (data.docs || []).filter((d) => d.cover_i || (d.isbn && d.isbn.length));
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------
  function render() {
    renderStats();
    renderReading();
    renderWant();
    renderLibrary();
    renderAchievements();
    renderGoal();
    renderStatsView();
    renderStorageStatus();
  }

  function renderStats() {
    const streak = readingStreak();
    $("#stats-strip").innerHTML = `
      <div class="stat"><div class="num">${num(booksFinished().length)}</div><div class="lbl">Books read</div></div>
      <div class="stat"><div class="num">${num(totalPagesRead())}</div><div class="lbl">Pages read</div></div>
      <div class="stat"><div class="num">${num(state.books.filter((b) => b.status === "reading").length)}</div><div class="lbl">Reading now</div></div>
      <div class="stat"><div class="num">${num(streak.current)}</div><div class="lbl">Day streak 🔥</div></div>
      <div class="stat"><div class="num">${num(computeBadges().filter((b) => b.unlocked).length)}</div><div class="lbl">Badges earned</div></div>`;
  }

  function coverHTML(book, cls) {
    if (book.coverUrl) {
      return `<img class="cover ${cls || ""}" src="${esc(book.coverUrl)}" alt="Cover of ${esc(book.title)}"
              onerror="this.outerHTML='<div class=\\'cover ${cls || ""}\\'>${esc(book.title)}</div>'" />`;
    }
    return `<div class="cover ${cls || ""}">${esc(book.title)}</div>`;
  }
  function starsHTML(rating) {
    let out = "";
    for (let i = 1; i <= 5; i++) out += `<span class="${i <= (rating || 0) ? "" : "off"}">★</span>`;
    return `<span class="stars">${out}</span>`;
  }

  function renderReading() {
    const all = state.books.filter((b) => b.status === "reading");
    const list = all.filter((b) => bookMatches(b, readingQuery)).sort((a, b) => new Date(b.addedAt) - new Date(a.addedAt));
    const empty = $("#reading-empty");
    empty.hidden = list.length > 0;
    empty.textContent = all.length === 0 ? "You're not reading anything yet. Add a book to start logging your pages." : "No books match your search.";
    $("#reading-list").innerHTML = list.map((b) => {
      const read = pagesRead(b);
      const pct = b.totalPages ? Math.min(100, Math.round((read / b.totalPages) * 100)) : 0;
      const recent = b.logs.slice().sort((x, y) => new Date(y.date) - new Date(x.date)).slice(0, 5);
      const est = estimateFinish(b);
      return `<article class="book-card" data-id="${b.id}">
        ${coverHTML(b)}
        <div class="book-meta">
          <h3 class="book-title">${fmtIcon(b)}${esc(b.title)}</h3>
          <p class="book-author">${esc(b.author) || "Unknown author"}${seriesLabel(b)}</p>
          <div class="progress"><span style="width:${pct}%"></span></div>
          <p class="progress-label">${num(read)}${b.totalPages ? " / " + num(b.totalPages) : ""} ${unitLabel(b)}${b.totalPages ? " · " + pct + "%" : ""}${est ? ` · <span class="eta">≈ done ${fmtDate(est.date.toISOString())}</span>` : ""}</p>
          ${chipsHTML(b, true)}
          <div class="card-actions">
            <button class="mini" data-action="log" data-id="${b.id}">＋ Log</button>
            <button class="mini" data-action="detail" data-id="${b.id}">📈 Progress</button>
            <button class="mini" data-action="finish" data-id="${b.id}">✓ Finish</button>
            <button class="mini" data-action="dnf" data-id="${b.id}">✕ DNF</button>
            <button class="mini" data-action="edit" data-id="${b.id}">✎ Edit</button>
            <button class="mini danger" data-action="delete" data-id="${b.id}">🗑</button>
          </div>
          ${recent.length ? `<details class="logs"><summary>${b.logs.length} session${b.logs.length === 1 ? "" : "s"}</summary>
            ${recent.map((l) => `<div class="log-row">
              <span class="l-pages">+${num(l.pages)}${unitShort(b)}</span>
              <span class="l-when">${fmtDateTime(l.date)}${l.minutes ? " · " + l.minutes + "m" : ""}</span>
              <span class="l-note">${l.note ? "“" + esc(l.note) + "”" : ""}</span>
              <span class="log-actions">
                <button data-action="edit-log" data-id="${b.id}" data-log="${l.id}" title="Edit log">✎</button>
                <button data-action="del-log" data-id="${b.id}" data-log="${l.id}" title="Delete log">🗑</button>
              </span>
            </div>`).join("")}
          </details>` : ""}
          ${b.review ? `<details class="review"><summary>My notes</summary><p class="review-text">${esc(b.review)}</p></details>` : ""}
        </div>
      </article>`;
    }).join("");
  }

  function renderWant() {
    const all = state.books.filter((b) => b.status === "want");
    const list = all.filter((b) => bookMatches(b, wantQuery)).sort((a, b) => new Date(b.addedAt) - new Date(a.addedAt));
    const empty = $("#want-empty");
    empty.hidden = list.length > 0;
    empty.textContent = all.length === 0 ? "Nothing on your list yet. Add books you'd like to read next." : "No books match your search.";
    $("#want-list").innerHTML = list.map((b) => `
      <article class="book-card" data-id="${b.id}">
        ${coverHTML(b)}
        <div class="book-meta">
          <h3 class="book-title">${fmtIcon(b)}${esc(b.title)}</h3>
          <p class="book-author">${esc(b.author) || "Unknown author"}${seriesLabel(b)}</p>
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

  function libDate(b) {
    if (b.status === "dnf") return `<span class="dnf-badge">Did not finish</span>`;
    return `Finished ${fmtDate(b.finishedAt)}${b.readCount > 1 ? " · " + b.readCount + "× read" : ""} · ${num(pagesRead(b) || b.totalPages)}${unitShort(b)}`;
  }

  function renderLibrary() {
    const tagSel = $("#library-tag"), tags = allTags();
    if (libraryTag && !tags.some((t) => t.toLowerCase() === libraryTag.toLowerCase())) libraryTag = "";
    tagSel.innerHTML = `<option value="">All genres</option>` + tags.map((t) => `<option value="${esc(t)}">${esc(t)}</option>`).join("");
    tagSel.value = libraryTag;

    const colSel = $("#library-collection"), cols = allCollections();
    if (libraryCollection && !cols.some((t) => t.toLowerCase() === libraryCollection.toLowerCase())) libraryCollection = "";
    colSel.innerHTML = `<option value="">All shelves</option>` + cols.map((t) => `<option value="${esc(t)}">📁 ${esc(t)}</option>`).join("");
    colSel.value = libraryCollection;

    $$("#library-view-toggle button").forEach((btn) => btn.classList.toggle("active", btn.dataset.libview === libraryView));

    const done = libraryBooks();
    let list = done
      .filter((b) => bookMatches(b, libraryQuery))
      .filter((b) => !libraryTag || (b.tags || []).some((t) => t.toLowerCase() === libraryTag.toLowerCase()))
      .filter((b) => !libraryCollection || (b.collections || []).some((t) => t.toLowerCase() === libraryCollection.toLowerCase()));
    const sort = $("#library-sort").value;
    list.sort((a, b) => {
      if (sort === "finished-asc") return new Date(a.finishedAt || 0) - new Date(b.finishedAt || 0);
      if (sort === "rating-desc") return (b.rating || 0) - (a.rating || 0);
      if (sort === "pages-desc") return (b.totalPages || 0) - (a.totalPages || 0);
      if (sort === "title-asc") return a.title.localeCompare(b.title);
      return new Date(b.finishedAt || 0) - new Date(a.finishedAt || 0);
    });

    const empty = $("#library-empty");
    empty.hidden = list.length > 0;
    empty.textContent = done.length === 0 ? "No finished books yet. Add books you've already read, or finish one you're reading." : "No books match your search or filter.";

    const wrap = $("#library-list");
    if (libraryView === "shelf") wrap.innerHTML = shelfHTML(list);
    else if (libraryView === "author") wrap.innerHTML = `<div class="author-view">${authorHTML(list)}</div>`;
    else wrap.innerHTML = `<div class="card-grid library">${list.map(libraryCardHTML).join("")}</div>`;
  }

  function libraryCardHTML(b) {
    return `<article class="book-card lib-card ${b.status === "dnf" ? "is-dnf" : ""}" data-id="${b.id}">
      ${coverHTML(b)}
      <h3 class="book-title">${fmtIcon(b)}${esc(b.title)}</h3>
      <p class="book-author">${esc(b.author) || "Unknown author"}${seriesLabel(b)}</p>
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
  function shelfHTML(list) {
    if (!list.length) return "";
    const spines = list.map((b) => {
      const hue = hashHue(b.title + b.author);
      const h = Math.max(120, Math.min(230, 120 + (b.totalPages || 200) / 6));
      return `<button class="spine" data-action="detail" data-id="${b.id}" style="--hue:${hue}; height:${h}px" title="${esc(b.title)} — ${esc(b.author)}"><span class="spine-title">${esc(b.title)}</span></button>`;
    }).join("");
    return `<div class="bookshelf">${spines}</div>`;
  }
  function authorHTML(list) {
    const groups = {};
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
    const groups = { pages: $("#badges-pages"), books: $("#badges-books"), special: $("#badges-special") };
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
    $("#goal-count").textContent = done;
    $("#goal-of").textContent = "of " + target;
    if (document.activeElement !== $("#goal-year")) $("#goal-year").value = goal.year;
    if (document.activeElement !== $("#goal-target")) $("#goal-target").value = target;
    if (document.activeElement !== $("#goal-pages")) $("#goal-pages").value = goal.pagesTarget || "";
    if (document.activeElement !== $("#goal-daily")) $("#goal-daily").value = goal.dailyPages || "";
    const hint = $("#goal-hint");
    if (target && done >= target) hint.textContent = `🎉 Goal smashed! ${done} books in ${goal.year}.`;
    else if (target) hint.textContent = `${target - done} to go in ${goal.year}.`;
    else hint.textContent = "";
    renderGoalExtra();
    renderChallenges();
  }
  function metricHTML(label, valTxt, pct, extra) {
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
      const dayOfYear = Math.floor((now - new Date(now.getFullYear(), 0, 0)) / DAY);
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
    const logs = [];
    state.books.forEach((b) => b.logs.forEach((l) => { const d = new Date(l.date); if (!isNaN(d)) logs.push({ d, pages: Number(l.pages) || 0 }); }));
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
  function dailyItems(perDay) {
    const today = startOfDay(new Date()), items = [];
    for (let i = 29; i >= 0; i--) {
      const t = today - i * DAY, d = new Date(t);
      items.push({ full: d.toLocaleDateString(undefined, { month: "short", day: "numeric" }), value: perDay[t] || 0, tick: i % 5 === 0 ? (d.getMonth() + 1) + "/" + d.getDate() : "" });
    }
    return items;
  }
  function monthlyItems(logs) {
    const NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const now = new Date(), buckets = [];
    for (let i = 11; i >= 0; i--) { const d = new Date(now.getFullYear(), now.getMonth() - i, 1); buckets.push({ y: d.getFullYear(), m: d.getMonth(), value: 0 }); }
    logs.forEach((x) => { const b = buckets.find((bk) => bk.y === x.d.getFullYear() && bk.m === x.d.getMonth()); if (b) b.value += x.pages; });
    return buckets.map((b) => ({ full: NAMES[b.m] + " " + b.y, value: b.value, tick: NAMES[b.m] }));
  }
  function genreItems() {
    const counts = {};
    state.books.forEach((b) => (b.tags || []).forEach((t) => { counts[t] = (counts[t] || 0) + 1; }));
    return Object.keys(counts).map((k) => ({ full: k, value: counts[k], tick: k.length > 8 ? k.slice(0, 7) + "…" : k }))
      .sort((a, b) => b.value - a.value).slice(0, 8);
  }
  function ratingItems() {
    const counts = [0, 0, 0, 0, 0];
    state.books.forEach((b) => { if (b.rating >= 1 && b.rating <= 5) counts[b.rating - 1]++; });
    return counts.map((v, i) => ({ full: (i + 1) + " star", value: v, tick: (i + 1) + "★" }));
  }
  function svgBars(items, unit) {
    const slot = 26, H = 170, padT = 16, padB = 26, padX = 8;
    const W = Math.max(items.length * slot + padX * 2, 320);
    const areaH = H - padT - padB, maxV = Math.max(1, ...items.map((i) => i.value)), baseY = padT + areaH;
    let out = `<line class="grid-line" x1="${padX}" y1="${padT}" x2="${W - padX}" y2="${padT}"/>`;
    out += `<text class="val-label" x="${padX}" y="${padT - 5}" font-size="9">${num(maxV)} ${unit}</text>`;
    out += `<line class="grid-line" x1="${padX}" y1="${baseY}" x2="${W - padX}" y2="${baseY}"/>`;
    items.forEach((it, i) => {
      const bh = it.value > 0 ? Math.max(2, (it.value / maxV) * areaH) : 0;
      const x = padX + i * slot + slot * 0.18, bw = slot * 0.64, y = baseY - bh;
      out += `<rect class="bar" x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${bh.toFixed(1)}" rx="2"><title>${esc(it.full)}: ${num(it.value)} ${unit}</title></rect>`;
      if (it.tick) out += `<text class="axis-label" x="${(padX + i * slot + slot / 2).toFixed(1)}" y="${H - 9}" text-anchor="middle" font-size="9">${esc(it.tick)}</text>`;
    });
    return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMinYMid meet" role="img" aria-label="bar chart">${out}</svg>`;
  }
  function svgCalendar(perDay) {
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
  function openDetailModal(book) {
    currentDetailId = book.id;
    $("#detail-title").textContent = book.title;
    const read = pagesRead(book);
    const pct = book.totalPages ? Math.min(100, Math.round((read / book.totalPages) * 100)) : 0;
    const logs = book.logs.slice().sort((a, b) => new Date(b.date) - new Date(a.date));
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

    const quotes = book.quotes || [];
    $("#detail-body").innerHTML = `
      <div class="detail-top">
        ${coverHTML(book)}
        <div class="detail-info">
          <h4>${esc(book.title)}</h4>
          <p class="by">${esc(book.author) || "Unknown author"}</p>
          <div class="detail-meta">${meta.map((m) => `<span>${m}</span>`).join("")}</div>
          ${chipsHTML(book, false)}
          <div class="detail-actions">
            ${book.status === "reading" ? `<button class="mini" data-detail-action="log" data-id="${book.id}">＋ Log pages</button>` : ""}
            ${book.status === "finished" ? `<button class="mini" data-detail-action="reread" data-id="${book.id}">🔁 Read again</button>` : ""}
            <button class="mini" data-detail-action="edit" data-id="${book.id}">✎ Edit</button>
          </div>
        </div>
      </div>
      ${book.description ? `<div class="detail-section"><h5>About</h5><p class="detail-desc">${esc(book.description)}</p></div>` : ""}
      <div class="detail-section">
        <h5>📈 Reading progress</h5>
        <div class="progress-chart">${svgProgress(book)}</div>
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
        <h5>Sessions (${book.logs.length})</h5>
        <div class="logs detail-logs">
          ${logs.length ? logs.map((l) => `<div class="log-row">
            <span class="l-pages">+${num(l.pages)}${unitShort(book)}</span>
            <span class="l-when">${fmtDateTime(l.date)}${l.minutes ? " · " + l.minutes + "m" : ""}</span>
            <span class="l-note">${l.note ? "“" + esc(l.note) + "”" : ""}</span>
          </div>`).join("") : `<p class="muted">No sessions logged yet.</p>`}
        </div>
      </div>
      ${book.review ? `<div class="detail-section"><h5>My notes</h5><p class="detail-review">${esc(book.review)}</p></div>` : ""}`;
    showModal("detail-modal");
  }
  function refreshDetail() {
    if (!currentDetailId || $("#detail-modal").hidden) return;
    const b = state.books.find((x) => x.id === currentDetailId);
    if (b) openDetailModal(b);
  }
  function svgProgress(book) {
    const logs = book.logs.slice().filter((l) => !isNaN(new Date(l.date))).sort((a, b) => new Date(a.date) - new Date(b.date));
    if (!logs.length) return `<p class="muted">No reading sessions yet — log some pages to see your progress.</p>`;
    const W = 520, H = 200, padL = 44, padR = 16, padT = 14, padB = 30;
    const aw = W - padL - padR, ah = H - padT - padB;
    let cum = 0;
    const pts = logs.map((l) => { cum += Number(l.pages) || 0; return { t: new Date(l.date).getTime(), y: cum, date: l.date }; });
    const total = book.totalPages || cum, maxY = Math.max(total, cum, 1);
    const t0 = pts[0].t, t1 = pts[pts.length - 1].t, span = t1 - t0;
    const xOf = (t, i) => span > 0 ? padL + ((t - t0) / span) * aw : padL + (pts.length === 1 ? aw : (i / (pts.length - 1)) * aw);
    const yOf = (v) => padT + ah - (v / maxY) * ah, baseY = padT + ah;
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
  function openYearReview(year) {
    yearReviewYear = year;
    const finished = booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt).getFullYear() === year);
    const pages = pagesReadInYear(year);
    const rated = finished.filter((b) => b.rating);
    const avg = rated.length ? (rated.reduce((s, b) => s + b.rating, 0) / rated.length) : 0;
    const fav = rated.slice().sort((a, b) => (b.rating - a.rating) || (new Date(b.finishedAt) - new Date(a.finishedAt)))[0];
    const longest = finished.slice().sort((a, b) => (b.totalPages || 0) - (a.totalPages || 0))[0];
    const genres = {}; finished.forEach((b) => (b.tags || []).forEach((t) => genres[t] = (genres[t] || 0) + 1));
    const topGenre = Object.keys(genres).sort((a, b) => genres[b] - genres[a])[0];
    const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    const monthCounts = new Array(12).fill(0); finished.forEach((b) => monthCounts[new Date(b.finishedAt).getMonth()]++);
    const bestMonthIdx = monthCounts.indexOf(Math.max(...monthCounts));
    const daysThisYear = Array.from(readingDaySet()).filter((t) => new Date(t).getFullYear() === year).length;

    const tile = (n, l) => `<div class="yr-tile"><div class="yr-num">${n}</div><div class="yr-lbl">${l}</div></div>`;
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
      ` : `<p class="empty">No books finished in ${year} yet. Come back once you've read some!</p>`}`;
    showModal("year-modal");
  }

  function renderStorageStatus() {
    const el = $("#storage-status");
    if (fileHandle) { el.textContent = "💾 synced to file"; el.title = "Changes are written to your connected JSON file."; return; }
    const lock = storagePersisted ? " 🔒" : "";
    el.textContent = (supportsFS ? "💾 saved in this browser" : "💾 saved on this device") + lock;
    el.title = storagePersisted ? "Your data is stored persistently and won't be auto-cleared by the browser."
      : "Saved locally in this browser. Tip: add to your home screen, and Export now and then as a backup.";
  }

  // ---------------------------------------------------------------------------
  // Toasts
  // ---------------------------------------------------------------------------
  function toast(emoji, title, sub, isBadge) {
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
  function openBookModal(opts) {
    const book = opts.book || null;
    const status = book ? book.status : (opts.status || "reading");
    $("#book-modal-title").textContent = book ? "Edit book" : (status === "finished" ? "Add a read book" : status === "want" ? "Add to your list" : "Add a book");
    $("#f-id").value = book ? book.id : "";
    $("#f-title").value = book ? book.title : "";
    $("#f-author").value = book ? book.author : "";
    $("#f-pages").value = book && book.totalPages ? book.totalPages : "";
    $("#f-isbn").value = book ? book.isbn : "";
    $("#f-format").value = book ? book.format : "physical";
    $("#f-year").value = book && book.publishedYear ? book.publishedYear : "";
    $("#f-series").value = book ? book.seriesName : "";
    $("#f-series-num").value = book && book.seriesNumber != null ? book.seriesNumber : "";
    $("#f-cover").value = book ? book.coverUrl : "";
    $("#f-desc").value = book ? (book.description || "") : "";
    $("#f-review").value = book ? (book.review || "") : "";
    $("#f-tags").value = book && book.tags ? book.tags.join(", ") : "";
    $("#f-collections").value = book && book.collections ? book.collections.join(", ") : "";
    renderTagHelpers();
    $("#cover-candidates").innerHTML = "";
    setCoverPreview(book ? book.coverUrl : "");

    $$("input[name='f-status']").forEach((r) => (r.checked = r.value === status));
    toggleStatusFields(status);
    $("#f-started").value = (book && book.startedAt) ? book.startedAt.slice(0, 10) : todayISODate();
    $("#f-finished").value = (book && book.finishedAt) ? book.finishedAt.slice(0, 10) : todayISODate();
    modalRating = book && book.rating ? book.rating : 0;
    paintStars($("#f-stars"), modalRating);
    updatePagesLabel();

    showModal("book-modal");
    setTimeout(() => $("#f-title").focus(), 50);
  }
  function toggleStatusFields(status) {
    $("#reading-fields").hidden = status !== "reading";
    $("#finished-fields").hidden = status !== "finished";
  }
  function updatePagesLabel() {
    const fmt = $("#f-format").value;
    $("#f-pages").previousElementSibling.childNodes[0].nodeValue = fmt === "audio" ? "Total minutes" : "Total pages";
  }
  function setCoverPreview(url) {
    const box = $("#f-cover-preview");
    box.innerHTML = url ? `<img src="${esc(url)}" alt="cover" onerror="this.parentNode.innerHTML='<span class=\\'cover-ph\\'>No cover</span>'" />` : `<span class="cover-ph">No cover</span>`;
  }
  function renderTagHelpers() {
    const tags = allTags();
    $("#tags-datalist").innerHTML = tags.map((t) => `<option value="${esc(t)}"></option>`).join("");
    const curT = parseList($("#f-tags").value).map((t) => t.toLowerCase());
    $("#tag-suggest").innerHTML = tags.filter((t) => curT.indexOf(t.toLowerCase()) < 0).slice(0, 12).map((t) => `<span class="tag" data-add-tag="${esc(t)}">+ ${esc(t)}</span>`).join("");
    const cols = allCollections();
    $("#collections-datalist").innerHTML = cols.map((t) => `<option value="${esc(t)}"></option>`).join("");
    const curC = parseList($("#f-collections").value).map((t) => t.toLowerCase());
    $("#collection-suggest").innerHTML = cols.filter((t) => curC.indexOf(t.toLowerCase()) < 0).slice(0, 12).map((t) => `<span class="tag" data-add-collection="${esc(t)}">+ 📁 ${esc(t)}</span>`).join("");
  }

  async function handleFetch() {
    const title = $("#f-title").value.trim(), author = $("#f-author").value.trim(), isbn = $("#f-isbn").value.trim();
    if (!title && !isbn) { toast("ℹ️", "Type a title first", "Then I can look up the cover."); return; }
    const btn = $("#btn-fetch");
    btn.disabled = true; btn.textContent = "Searching…";
    try {
      const docs = await searchOpenLibrary(title, author, isbn);
      if (!docs.length) { toast("🔍", "No matches found", "Try adding the author, or paste a cover URL."); return; }
      const top = docs[0];
      if (!$("#f-author").value && top.author_name) $("#f-author").value = top.author_name[0];
      if (!$("#f-pages").value && top.number_of_pages_median) $("#f-pages").value = top.number_of_pages_median;
      if (!$("#f-isbn").value && top.isbn && top.isbn[0]) $("#f-isbn").value = top.isbn[0];
      if (!$("#f-year").value && top.first_publish_year) $("#f-year").value = top.first_publish_year;
      if (!$("#f-title").value) $("#f-title").value = top.title || "";
      const firstCover = top.cover_i ? coverFromId(top.cover_i) : (top.isbn ? coverFromIsbn(top.isbn[0]) : "");
      if (firstCover) { $("#f-cover").value = firstCover; setCoverPreview(firstCover); }
      if (!$("#f-tags").value.trim() && Array.isArray(top.subject)) {
        const picks = top.subject.filter((s) => s.length < 24 && !/\d|fiction in|accessible|reading level|nyt:/i.test(s)).slice(0, 3);
        if (picks.length) { $("#f-tags").value = picks.join(", "); renderTagHelpers(); }
      }
      renderCandidates(docs);
      // Second call: fetch a short description from the work record.
      if (!$("#f-desc").value.trim() && top.key) {
        fetch("https://openlibrary.org" + top.key + ".json").then((r) => r.ok ? r.json() : null).then((w) => {
          if (!w) return;
          let d = w.description;
          if (d && typeof d === "object") d = d.value;
          if (d && !$("#f-desc").value.trim()) $("#f-desc").value = String(d).split("\n")[0].slice(0, 600);
        }).catch(() => {});
      }
      toast("✨", "Found it!", "Wrong cover or genres? Tweak them below.");
    } catch (e) {
      console.warn(e);
      toast("⚠️", "Lookup failed", "Check your connection, or paste a cover URL.");
    } finally {
      btn.disabled = false; btn.textContent = "🔍 Auto-fetch details & cover";
    }
  }
  function renderCandidates(docs) {
    const urls = docs.map((d) => d.cover_i ? coverFromId(d.cover_i, "M") : (d.isbn && d.isbn[0] ? coverFromIsbn(d.isbn[0], "M") : null)).filter(Boolean);
    $("#cover-candidates").innerHTML = urls.map((u) => `<img src="${esc(u)}" data-cover="${esc(u.replace("-M.jpg", "-L.jpg"))}" alt="cover option" />`).join("");
  }

  function saveBookFromForm(e) {
    e.preventDefault();
    const id = $("#f-id").value;
    const status = $$("input[name='f-status']").find((r) => r.checked).value;
    const existing = id ? state.books.find((b) => b.id === id) : null;
    const title = $("#f-title").value.trim();
    if (!title) return;
    const wasFinished = existing && existing.status === "finished";

    const book = existing || { id: uid(), addedAt: new Date().toISOString(), logs: [], quotes: [], readCount: 1, finishHistory: [] };
    book.title = title;
    book.author = $("#f-author").value.trim();
    book.totalPages = Number($("#f-pages").value) || 0;
    book.isbn = $("#f-isbn").value.trim();
    book.format = $("#f-format").value;
    book.publishedYear = Number($("#f-year").value) || null;
    book.seriesName = $("#f-series").value.trim();
    book.seriesNumber = $("#f-series-num").value !== "" ? Number($("#f-series-num").value) : null;
    book.coverUrl = $("#f-cover").value.trim();
    book.description = $("#f-desc").value.trim();
    book.review = $("#f-review").value.trim();
    book.tags = parseList($("#f-tags").value);
    book.collections = parseList($("#f-collections").value);
    book.quotes = book.quotes || [];
    book.status = status;

    if (status === "reading") {
      book.startedAt = $("#f-started").value ? new Date($("#f-started").value).toISOString() : new Date().toISOString();
    } else if (status === "want") {
      /* no dates */
    } else if (status === "finished") {
      book.finishedAt = $("#f-finished").value ? new Date($("#f-finished").value).toISOString() : new Date().toISOString();
      book.startedAt = book.startedAt || book.finishedAt;
      book.rating = modalRating || book.rating || null;
      if (book.logs.length === 0 && book.totalPages > 0) {
        book.logs.push({ id: uid(), date: book.finishedAt, pages: book.totalPages, minutes: 0, note: "Added as already read" });
      }
    }

    if (!existing) state.books.push(book);
    closeModals();
    commit();
    checkNewBadges();
    if (status === "finished" && !wasFinished) confetti();
    toast("✅", existing ? "Book updated" : "Book added", title);
  }

  // ---------------------------------------------------------------------------
  // Log / finish / rate dialogs
  // ---------------------------------------------------------------------------
  function openLogModal(book, log) {
    resetTimer();
    $("#log-book-id").value = book.id;
    $("#log-id").value = log ? log.id : "";
    $("#log-book-name").textContent = book.title;
    $("#log-modal-title").textContent = log ? "Edit reading session" : "Log a reading session";
    $("#log-pages-label").textContent = (book.format === "audio" ? "Minutes read this session *" : "Pages read this session *");
    $("#log-pages").value = log ? log.pages : "";
    $("#log-minutes").value = log && log.minutes ? log.minutes : "";
    $("#log-note").value = log ? log.note : "";
    $("#log-when").value = log ? toLocalInput(log.date) : nowLocalInput();
    showModal("log-modal");
    setTimeout(() => $("#log-pages").focus(), 50);
  }
  function saveLog(e) {
    e.preventDefault();
    const book = state.books.find((b) => b.id === $("#log-book-id").value);
    if (!book) return;
    const pages = Number($("#log-pages").value);
    if (!pages || pages < 1) return;
    const when = $("#log-when").value ? new Date($("#log-when").value).toISOString() : new Date().toISOString();
    const note = $("#log-note").value.trim();
    const minutes = Number($("#log-minutes").value) || 0;
    const editId = $("#log-id").value;
    if (editId) {
      const lg = book.logs.find((x) => x.id === editId);
      if (lg) { lg.pages = pages; lg.date = when; lg.note = note; lg.minutes = minutes; }
    } else {
      book.logs.push({ id: uid(), date: when, pages, minutes, note });
    }
    resetTimer();
    closeModals();
    commit();
    checkNewBadges();
    refreshDetail();
    toast(editId ? "✎" : "📖", editId ? "Log updated" : "Logged " + pages + " " + unitLabel(book), book.title);
  }

  let finishRating = 0;
  function openFinishModal(book) {
    $("#finish-book-id").value = book.id;
    $("#finish-book-name").textContent = book.title;
    $("#finish-date").value = todayISODate();
    finishRating = book.rating || 0;
    paintStars($("#finish-stars"), finishRating);
    showModal("finish-modal");
  }
  function saveFinish(e) {
    e.preventDefault();
    const book = state.books.find((b) => b.id === $("#finish-book-id").value);
    if (!book) return;
    const wasFinished = book.status === "finished";
    book.status = "finished";
    book.finishedAt = $("#finish-date").value ? new Date($("#finish-date").value).toISOString() : new Date().toISOString();
    book.rating = finishRating || book.rating || null;
    const read = pagesRead(book);
    if (book.totalPages && read < book.totalPages) {
      book.logs.push({ id: uid(), date: book.finishedAt, pages: book.totalPages - read, minutes: 0, note: "Finished the book" });
    }
    closeModals();
    commit();
    checkNewBadges();
    if (!wasFinished) confetti();
    toast("🏁", "Finished!", book.title);
  }
  function rateBook(book) {
    $("#finish-modal-title").textContent = "Rate this book";
    $("#finish-book-id").value = book.id;
    $("#finish-book-name").textContent = book.title;
    $("#finish-date").value = (book.finishedAt || new Date().toISOString()).slice(0, 10);
    finishRating = book.rating || 0;
    paintStars($("#finish-stars"), finishRating);
    showModal("finish-modal");
  }

  // ---------------------------------------------------------------------------
  // Reading-session timer
  // ---------------------------------------------------------------------------
  let timerStart = null, timerInterval = null;
  function resetTimer() {
    if (timerInterval) clearInterval(timerInterval);
    timerInterval = null; timerStart = null;
    const btn = $("#timer-btn"), read = $("#timer-read");
    if (btn) btn.textContent = "⏱ Start timer";
    if (read) { read.hidden = true; read.textContent = "00:00"; }
  }
  function toggleTimer() {
    if (timerStart) {
      const mins = Math.max(0, Math.round((Date.now() - timerStart) / 60000));
      $("#log-minutes").value = (Number($("#log-minutes").value) || 0) + mins;
      resetTimer();
    } else {
      timerStart = Date.now();
      $("#timer-btn").textContent = "⏹ Stop timer";
      $("#timer-read").hidden = false;
      timerInterval = setInterval(() => {
        const s = Math.floor((Date.now() - timerStart) / 1000);
        $("#timer-read").textContent = String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0");
      }, 1000);
    }
  }

  // ---------------------------------------------------------------------------
  // Barcode scanner
  // ---------------------------------------------------------------------------
  let scanStream = null, scanLoop = null, scanDetector = null;
  async function openScan() {
    if (!("BarcodeDetector" in window)) { toast("ℹ️", "Scanner not supported here", "Your browser can't scan — type the ISBN instead."); return; }
    try { scanDetector = new window.BarcodeDetector({ formats: ["ean_13", "ean_8", "upc_a"] }); }
    catch (e) { try { scanDetector = new window.BarcodeDetector(); } catch (e2) { toast("ℹ️", "Scanner unavailable", "Type the ISBN instead."); return; } }
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { toast("⚠️", "No camera access", "Type the ISBN instead."); return; }
    try { scanStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } }); }
    catch (e) { toast("⚠️", "Camera blocked", "Allow camera access, or type the ISBN."); return; }
    const v = $("#scan-video");
    v.srcObject = scanStream;
    try { await v.play(); } catch (e) { /* ignore */ }
    showModal("scan-modal");
    scanLoop = setInterval(async () => {
      if (!scanDetector || !scanStream) return;
      try {
        const codes = await scanDetector.detect(v);
        if (codes && codes.length) {
          const raw = String(codes[0].rawValue || "").replace(/[^0-9Xx]/g, "");
          if (raw.length >= 10) {
            stopScan();
            $("#scan-modal").hidden = true;
            $("#f-isbn").value = raw;
            handleFetch();
          }
        }
      } catch (e) { /* keep scanning */ }
    }, 500);
  }
  function stopScan() {
    if (scanLoop) clearInterval(scanLoop);
    scanLoop = null;
    if (scanStream) { scanStream.getTracks().forEach((t) => t.stop()); scanStream = null; }
    const v = $("#scan-video"); if (v) v.srcObject = null;
  }

  // ---------------------------------------------------------------------------
  // Star inputs
  // ---------------------------------------------------------------------------
  function paintStars(container, rating) {
    container.dataset.rating = rating;
    $$("span", container).forEach((s) => s.classList.toggle("on", Number(s.dataset.star) <= rating));
  }
  function wireStars(container, onSet) {
    container.addEventListener("click", (e) => { const s = e.target.closest("[data-star]"); if (!s) return; const v = Number(s.dataset.star); onSet(v); paintStars(container, v); });
    container.addEventListener("mouseover", (e) => { const s = e.target.closest("[data-star]"); if (!s) return; const v = Number(s.dataset.star); $$("span", container).forEach((x) => x.classList.toggle("on", Number(x.dataset.star) <= v)); });
    container.addEventListener("mouseleave", () => paintStars(container, Number(container.dataset.rating)));
  }

  // ---------------------------------------------------------------------------
  // Modal plumbing
  // ---------------------------------------------------------------------------
  function showModal(id) { $("#" + id).hidden = false; }
  function closeModals() {
    stopScan();
    resetTimer();
    $$(".modal-backdrop").forEach((m) => (m.hidden = true));
    $("#finish-modal-title").textContent = "Finish this book";
  }

  // ---------------------------------------------------------------------------
  // Data import / export / file connect / Goodreads
  // ---------------------------------------------------------------------------
  function exportJSON() {
    const blob = new Blob([JSON.stringify(state, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = "enkelas-bookshelf.json"; a.click();
    URL.revokeObjectURL(url);
    toast("⬇️", "Exported", "enkelas-bookshelf.json downloaded");
  }
  function importJSON(file) {
    const reader = new FileReader();
    reader.onload = () => {
      try {
        state = normalize(JSON.parse(reader.result));
        knownBadges = new Set();
        commit();
        knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
        toast("⬆️", "Imported", state.books.length + " books loaded");
      } catch (e) { toast("⚠️", "Import failed", "That file isn't valid bookshelf JSON."); }
    };
    reader.readAsText(file);
  }
  async function connectFile() {
    if (!supportsFS) { toast("ℹ️", "Use Export / Import", "This browser can't link a file directly. Your data is saved in-browser."); return; }
    try {
      const [handle] = await window.showOpenFilePicker({ types: [{ description: "JSON", accept: { "application/json": [".json"] } }], multiple: false })
        .catch(async () => { const h = await window.showSaveFilePicker({ suggestedName: "bookshelf.json", types: [{ description: "JSON", accept: { "application/json": [".json"] } }] }); return [h]; });
      fileHandle = handle;
      const text = await (await handle.getFile()).text();
      if (text.trim()) { try { state = normalize(JSON.parse(text)); knownBadges = new Set(); } catch (e) { /* keep */ } }
      await persist();
      render();
      knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
      toast("🔗", "File connected", "Changes now save to your JSON file.");
    } catch (e) { if (e && e.name !== "AbortError") { console.warn(e); toast("⚠️", "Couldn't connect file", ""); } }
  }

  // Minimal RFC-4180-ish CSV parser (handles quotes and embedded commas/newlines).
  function parseCSV(text) {
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
  function importGoodreads(file) {
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
        const idx = (name) => header.indexOf(name);
        const cTitle = idx("Title"), cAuthor = idx("Author"), cRating = idx("My Rating"),
          cPages = idx("Number of Pages"), cShelf = idx("Exclusive Shelf"), cShelves = idx("Bookshelves"),
          cReview = idx("My Review"), cDateRead = idx("Date Read"), cISBN = idx("ISBN"),
          cISBN13 = idx("ISBN13"), cYear = idx("Original Publication Year");
        if (cTitle < 0) throw 0;
        const clean = (s) => {
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
          const tags = cShelves >= 0 ? parseList(clean(row[cShelves]).replace(/to-read|currently-reading|read/gi, "").replace(/\s+/g, " ")) : [];
          const finishedAt = status === "finished" ? (dateRead ? new Date(dateRead).toISOString() : new Date().toISOString()) : null;
          const book = {
            id: uid(), title, author, totalPages: pages, coverUrl: isbn ? coverFromIsbn(isbn) : "", isbn,
            review, description: "", tags, collections: [], format: "physical",
            seriesName: "", seriesNumber: null, publishedYear: year, quotes: [], readCount: 1, finishHistory: [],
            status, rating: rating || null, startedAt: null, finishedAt, addedAt: new Date().toISOString(), logs: [],
          };
          if (status === "finished" && pages > 0) book.logs.push({ id: uid(), date: finishedAt, pages, minutes: 0, note: "Imported from Goodreads" });
          state.books.push(book);
          added++;
        }
        knownBadges = new Set();
        commit();
        knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
        toast("📥", "Goodreads import", added + " book" + (added === 1 ? "" : "s") + " added");
      } catch (e) { console.warn(e); toast("⚠️", "Import failed", "That doesn't look like a Goodreads CSV export."); }
    };
    reader.readAsText(file);
  }

  // ---------------------------------------------------------------------------
  // Event wiring
  // ---------------------------------------------------------------------------
  function switchView(view) {
    activeView = view;
    $$(".tab").forEach((t) => t.classList.toggle("active", t.dataset.view === view));
    $$(".view").forEach((v) => (v.hidden = v.id !== "view-" + view));
  }

  function onMainClick(e) {
    const actBtn = e.target.closest("[data-action]");
    if (actBtn) {
      const book = state.books.find((b) => b.id === actBtn.dataset.id);
      if (!book) return;
      const action = actBtn.dataset.action;
      if (action === "log") openLogModal(book);
      else if (action === "detail") openDetailModal(book);
      else if (action === "finish") openFinishModal(book);
      else if (action === "edit") openBookModal({ book });
      else if (action === "cover") { openBookModal({ book }); setTimeout(() => $("#btn-fetch").focus(), 80); }
      else if (action === "rate") rateBook(book);
      else if (action === "start") { book.status = "reading"; book.startedAt = new Date().toISOString(); commit(); toast("📖", "Started reading", book.title); }
      else if (action === "dnf") { if (confirm(`Mark “${book.title}” as did-not-finish?`)) { book.status = "dnf"; book.finishedAt = book.finishedAt || new Date().toISOString(); commit(); toast("🚧", "Did not finish", book.title); } }
      else if (action === "edit-log") { const lg = book.logs.find((x) => x.id === actBtn.dataset.log); if (lg) openLogModal(book, lg); }
      else if (action === "del-log") { const lg = book.logs.find((x) => x.id === actBtn.dataset.log); if (lg && confirm(`Delete this log of ${num(lg.pages)} pages?`)) { book.logs = book.logs.filter((x) => x.id !== lg.id); commit(); toast("🗑", "Log removed", book.title); } }
      else if (action === "delete") { if (confirm(`Remove “${book.title}” from your bookshelf? This can't be undone.`)) { state.books = state.books.filter((b) => b.id !== book.id); commit(); toast("🗑", "Removed", book.title); } }
      return;
    }
    const tagChip = e.target.closest("[data-tag]");
    if (tagChip) {
      const tag = tagChip.dataset.tag;
      if (activeView === "library") { libraryTag = tag; $("#library-tag").value = tag; renderLibrary(); }
      else if (activeView === "want") { wantQuery = tag; $("#want-search").value = tag; renderWant(); }
      else { readingQuery = tag; $("#reading-search").value = tag; renderReading(); }
      return;
    }
    const colChip = e.target.closest("[data-collection]");
    if (colChip) {
      const col = colChip.dataset.collection;
      if (activeView === "library") { libraryCollection = col; $("#library-collection").value = col; renderLibrary(); }
      else { switchView("library"); libraryCollection = col; $("#library-collection").value = col; renderLibrary(); }
      return;
    }
    const addBtn = e.target.closest("[data-add]");
    if (addBtn) openBookModal({ status: addBtn.dataset.add });
  }

  function init() {
    $("#tabs").addEventListener("click", (e) => { const tab = e.target.closest(".tab"); if (tab) switchView(tab.dataset.view); });
    $("#main").addEventListener("click", onMainClick);

    // Search + filters
    $("#reading-search").addEventListener("input", (e) => { readingQuery = e.target.value.trim(); renderReading(); });
    $("#want-search").addEventListener("input", (e) => { wantQuery = e.target.value.trim(); renderWant(); });
    $("#library-search").addEventListener("input", (e) => { libraryQuery = e.target.value.trim(); renderLibrary(); });
    $("#library-tag").addEventListener("change", (e) => { libraryTag = e.target.value; renderLibrary(); });
    $("#library-collection").addEventListener("change", (e) => { libraryCollection = e.target.value; renderLibrary(); });
    $("#library-sort").addEventListener("change", renderLibrary);
    $("#library-view-toggle").addEventListener("click", (e) => { const b = e.target.closest("[data-libview]"); if (b) { libraryView = b.dataset.libview; renderLibrary(); } });

    // Genre + collection quick-add chips
    $("#tag-suggest").addEventListener("click", (e) => { const chip = e.target.closest("[data-add-tag]"); if (!chip) return; const t = parseList($("#f-tags").value); t.push(chip.dataset.addTag); $("#f-tags").value = parseList(t.join(",")).join(", "); renderTagHelpers(); });
    $("#collection-suggest").addEventListener("click", (e) => { const chip = e.target.closest("[data-add-collection]"); if (!chip) return; const t = parseList($("#f-collections").value); t.push(chip.dataset.addCollection); $("#f-collections").value = parseList(t.join(",")).join(", "); renderTagHelpers(); });
    $("#f-tags").addEventListener("input", renderTagHelpers);
    $("#f-collections").addEventListener("input", renderTagHelpers);
    $("#f-format").addEventListener("change", updatePagesLabel);

    // Detail modal actions
    $("#detail-body").addEventListener("click", (e) => {
      const btn = e.target.closest("[data-detail-action]");
      if (!btn) return;
      const book = state.books.find((x) => x.id === currentDetailId);
      if (!book) return;
      const act = btn.dataset.detailAction;
      if (act === "log") { closeModals(); openLogModal(book); }
      else if (act === "edit") { closeModals(); openBookModal({ book }); }
      else if (act === "reread") { book.readCount = (book.readCount || 1) + 1; book.finishHistory = book.finishHistory || []; book.finishHistory.push(new Date().toISOString()); book.finishedAt = new Date().toISOString(); persist(); render(); refreshDetail(); confetti(); toast("🔁", "Re-read logged", book.title + " · " + book.readCount + "×"); }
      else if (act === "del-quote") { book.quotes = (book.quotes || []).filter((q) => q.id !== btn.dataset.quote); persist(); refreshDetail(); }
    });
    $("#detail-body").addEventListener("submit", (e) => {
      if (e.target.id !== "quote-form") return;
      e.preventDefault();
      const book = state.books.find((x) => x.id === currentDetailId);
      if (!book) return;
      const text = $("#q-text").value.trim();
      if (!text) return;
      book.quotes = book.quotes || [];
      book.quotes.push({ id: uid(), text, page: $("#q-page").value ? Number($("#q-page").value) : null });
      persist(); refreshDetail();
      toast("❝", "Quote saved", book.title);
    });

    // Book modal
    $("#book-form").addEventListener("submit", saveBookFromForm);
    $("#btn-fetch").addEventListener("click", handleFetch);
    $("#btn-scan").addEventListener("click", openScan);
    $("#f-cover").addEventListener("input", (e) => setCoverPreview(e.target.value.trim()));
    $("#cover-candidates").addEventListener("click", (e) => { const img = e.target.closest("[data-cover]"); if (!img) return; $$("#cover-candidates img").forEach((i) => i.classList.remove("sel")); img.classList.add("sel"); $("#f-cover").value = img.dataset.cover; setCoverPreview(img.dataset.cover); });
    $$("input[name='f-status']").forEach((r) => r.addEventListener("change", () => toggleStatusFields(r.value)));
    wireStars($("#f-stars"), (v) => (modalRating = v));

    // Log + finish
    $("#log-form").addEventListener("submit", saveLog);
    $("#finish-form").addEventListener("submit", saveFinish);
    $("#timer-btn").addEventListener("click", toggleTimer);
    wireStars($("#finish-stars"), (v) => (finishRating = v));

    // Goals
    $("#goal-save").addEventListener("click", () => {
      state.settings.goal = {
        year: Number($("#goal-year").value) || new Date().getFullYear(),
        target: Number($("#goal-target").value) || 0,
        pagesTarget: Number($("#goal-pages").value) || 0,
        dailyPages: Number($("#goal-daily").value) || 0,
      };
      commit();
      checkNewBadges();
      toast("🎯", "Goals saved", state.settings.goal.target + " books in " + state.settings.goal.year);
    });

    // Year in Review
    $("#btn-year-review").addEventListener("click", () => openYearReview(new Date().getFullYear()));
    $("#year-body").addEventListener("click", (e) => { const b = e.target.closest("[data-year-nav]"); if (b && !b.disabled) openYearReview(Number(b.dataset.yearNav)); });

    // Data menu
    $("#btn-export").addEventListener("click", exportJSON);
    $("#btn-import").addEventListener("click", () => $("#import-input").click());
    $("#import-input").addEventListener("change", (e) => { if (e.target.files[0]) importJSON(e.target.files[0]); e.target.value = ""; });
    $("#btn-goodreads").addEventListener("click", () => $("#goodreads-input").click());
    $("#goodreads-input").addEventListener("change", (e) => { if (e.target.files[0]) importGoodreads(e.target.files[0]); e.target.value = ""; });
    $("#btn-connect-file").addEventListener("click", connectFile);
    $("#btn-theme").addEventListener("click", toggleTheme);

    // Modal close
    $$(".modal-backdrop").forEach((m) => m.addEventListener("click", (e) => { if (e.target === m) closeModals(); }));
    document.addEventListener("click", (e) => { if (e.target.closest("[data-close-modal]")) closeModals(); });
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeModals(); });

    if (!supportsFS) $("#btn-connect-file").style.display = "none";

    applyTheme(loadTheme());
    render();
    knownBadges = new Set(computeBadges().filter((b) => b.unlocked).map((b) => b.id));
    switchView("reading");
    setupOfflineAndPersistence();
  }

  document.addEventListener("DOMContentLoaded", init);
})();
