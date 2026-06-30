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
  let fileHandle = null;          // File System Access API handle (if connected)
  let knownBadges = new Set();    // ids of badges already unlocked (for toast detection)
  let activeView = "reading";
  let storagePersisted = false;   // whether the browser granted persistent storage
  let readingQuery = "";          // search text for the Reading view
  let libraryQuery = "";          // search text for the Library view
  let libraryTag = "";            // active genre/tag filter in the Library view

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
  function parseTags(str) {
    const seen = new Set(), out = [];
    String(str || "").split(",").forEach((t) => {
      const v = t.trim();
      const key = v.toLowerCase();
      if (v && !seen.has(key)) { seen.add(key); out.push(v); }
    });
    return out;
  }
  function allTags() {
    const seen = new Map(); // lowercase -> display
    state.books.forEach((b) => (b.tags || []).forEach((t) => {
      const key = t.toLowerCase();
      if (!seen.has(key)) seen.set(key, t);
    }));
    return Array.from(seen.values()).sort((a, b) => a.localeCompare(b));
  }
  function bookMatches(book, q) {
    if (!q) return true;
    q = q.toLowerCase();
    return book.title.toLowerCase().includes(q)
      || (book.author || "").toLowerCase().includes(q)
      || (book.tags || []).some((t) => t.toLowerCase().includes(q));
  }
  function tagsHTML(book, clickable) {
    if (!book.tags || !book.tags.length) return "";
    return `<div class="tags">${book.tags.map((t) =>
      `<span class="tag${clickable ? " clickable" : ""}"${clickable ? ` data-tag="${esc(t)}"` : ""}>${esc(t)}</span>`).join("")}</div>`;
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------
  function defaultState() {
    return {
      version: SCHEMA_VERSION,
      settings: { goal: { year: new Date().getFullYear(), target: 12 } },
      books: [],
    };
  }
  function loadState() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return defaultState();
      const parsed = JSON.parse(raw);
      return normalize(parsed);
    } catch (e) {
      console.warn("Could not load saved data, starting fresh.", e);
      return defaultState();
    }
  }
  function normalize(data) {
    const base = defaultState();
    if (!data || typeof data !== "object") return base;
    base.settings.goal = Object.assign(base.settings.goal, (data.settings && data.settings.goal) || {});
    base.books = Array.isArray(data.books) ? data.books.map((b) => ({
      id: b.id || uid(),
      title: b.title || "Untitled",
      author: b.author || "",
      totalPages: Number(b.totalPages) || 0,
      coverUrl: b.coverUrl || "",
      isbn: b.isbn || "",
      review: b.review || "",
      tags: Array.isArray(b.tags) ? b.tags.map((t) => String(t).trim()).filter(Boolean) : [],
      status: b.status === "finished" ? "finished" : "reading",
      rating: b.rating ? Number(b.rating) : null,
      startedAt: b.startedAt || null,
      finishedAt: b.finishedAt || null,
      addedAt: b.addedAt || new Date().toISOString(),
      logs: Array.isArray(b.logs) ? b.logs.map((l) => ({
        id: l.id || uid(),
        date: l.date || new Date().toISOString(),
        pages: Number(l.pages) || 0,
        note: l.note || "",
      })) : [],
    })) : [];
    return base;
  }

  async function persist() {
    // Always keep localStorage in sync.
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); } catch (e) { console.warn(e); }
    // Mirror to a connected JSON file if the user linked one.
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

  // Re-render everything affected by a data change, then save.
  function commit() {
    render();
    persist();
  }

  // ---------------------------------------------------------------------------
  // Theme (light / dark)
  // ---------------------------------------------------------------------------
  function loadTheme() { try { return localStorage.getItem(THEME_KEY) === "dark" ? "dark" : "light"; } catch (e) { return "light"; } }
  function applyTheme(theme) {
    document.documentElement.setAttribute("data-theme", theme);
    const btn = $("#btn-theme");
    if (btn) {
      btn.textContent = theme === "dark" ? "☀️" : "🌙";
      btn.title = theme === "dark" ? "Switch to light mode" : "Switch to dark mode";
    }
  }
  function toggleTheme() {
    const next = loadTheme() === "dark" ? "light" : "dark";
    try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* ignore */ }
    applyTheme(next);
  }

  // ---------------------------------------------------------------------------
  // Offline (service worker) + persistent storage — important on phones
  // ---------------------------------------------------------------------------
  async function setupOfflineAndPersistence() {
    // Register the service worker so the app works offline and installs to the
    // home screen. Service workers require http(s) — they're a no-op on file://.
    if ("serviceWorker" in navigator && location.protocol.indexOf("http") === 0) {
      try { await navigator.serviceWorker.register("sw.js"); } catch (e) { /* ignore */ }
    }
    // Ask the browser to keep our data and not auto-evict it (e.g. iOS Safari's
    // 7-day cleanup). Granted more readily once the app is installed/bookmarked.
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
  function booksFinishedInYear(year) {
    return booksFinished().filter((b) => b.finishedAt && new Date(b.finishedAt).getFullYear() === year).length;
  }

  // Unique days on which any reading was logged.
  function readingDaySet() {
    const days = new Set();
    state.books.forEach((b) => b.logs.forEach((l) => {
      const d = new Date(l.date);
      if (!isNaN(d)) days.add(startOfDay(d));
    }));
    return days;
  }
  function readingStreak() {
    const days = readingDaySet();
    if (days.size === 0) return { current: 0, longest: 0 };
    const DAY = 86400000;
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

  function computeBadges() {
    const tp = totalPagesRead();
    const bf = booksFinished().length;
    const goal = state.settings.goal;
    const goalDone = goal && goal.target > 0 && booksFinishedInYear(goal.year) >= goal.target;
    const list = [];
    PAGE_MILESTONES.forEach((m) => list.push({ id: "pages-" + m.n, group: "pages", ...m, value: tp, target: m.n, unlocked: tp >= m.n }));
    BOOK_MILESTONES.forEach((m) => list.push({ id: "books-" + m.n, group: "books", ...m, value: bf, target: m.n, unlocked: bf >= m.n }));
    list.push({
      id: "goal-" + goal.year, group: "special", emoji: "🎯", title: "Goal Crusher",
      desc: "Hit your " + goal.year + " reading goal", value: booksFinishedInYear(goal.year),
      target: goal.target, unlocked: !!goalDone,
    });
    const firstRated = state.books.some((b) => b.rating);
    list.push({
      id: "first-rating", group: "special", emoji: "🌟", title: "Critic",
      desc: "Rated your first book", value: firstRated ? 1 : 0, target: 1, unlocked: firstRated,
    });
    const streak = readingStreak();
    [
      { d: 3, emoji: "🔥", title: "On a Roll", desc: "3-day reading streak" },
      { d: 7, emoji: "📅", title: "Weekly Habit", desc: "7-day reading streak" },
      { d: 30, emoji: "🚀", title: "Unstoppable", desc: "30-day reading streak" },
    ].forEach((s) => list.push({
      id: "streak-" + s.d, group: "special", emoji: s.emoji, title: s.title, desc: s.desc,
      value: streak.longest, target: s.d, unlocked: streak.longest >= s.d,
    }));
    return list;
  }

  // Detect and toast newly-unlocked badges.
  function checkNewBadges() {
    const badges = computeBadges();
    if (knownBadges.size === 0) { badges.forEach((b) => { if (b.unlocked) knownBadges.add(b.id); }); return; }
    badges.forEach((b) => {
      if (b.unlocked && !knownBadges.has(b.id)) {
        knownBadges.add(b.id);
        toast(b.emoji, "Achievement unlocked!", b.title + " — " + b.desc, true);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Open Library integration (cover + details auto-fetch)
  // ---------------------------------------------------------------------------
  function coverFromId(coverId, size) { return `https://covers.openlibrary.org/b/id/${coverId}-${size || "L"}.jpg`; }
  function coverFromIsbn(isbn, size) { return `https://covers.openlibrary.org/b/isbn/${encodeURIComponent(isbn)}-${size || "L"}.jpg`; }

  async function searchOpenLibrary(title, author, isbn) {
    const params = new URLSearchParams();
    if (isbn) params.set("isbn", isbn.replace(/[^0-9Xx]/g, ""));
    if (title) params.set("title", title);
    if (author) params.set("author", author);
    params.set("limit", "6");
    params.set("fields", "key,title,author_name,cover_i,number_of_pages_median,first_publish_year,isbn,subject");
    const url = "https://openlibrary.org/search.json?" + params.toString();
    const res = await fetch(url);
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
    renderLibrary();
    renderAchievements();
    renderGoal();
    renderStatsView();
    renderStorageStatus();
  }

  function renderStats() {
    const tp = totalPagesRead();
    const bf = booksFinished().length;
    const reading = state.books.filter((b) => b.status === "reading").length;
    const unlocked = computeBadges().filter((b) => b.unlocked).length;
    const streak = readingStreak();
    $("#stats-strip").innerHTML = `
      <div class="stat"><div class="num">${num(bf)}</div><div class="lbl">Books read</div></div>
      <div class="stat"><div class="num">${num(tp)}</div><div class="lbl">Pages read</div></div>
      <div class="stat"><div class="num">${num(reading)}</div><div class="lbl">Reading now</div></div>
      <div class="stat"><div class="num">${num(streak.current)}</div><div class="lbl">Day streak 🔥</div></div>
      <div class="stat"><div class="num">${num(unlocked)}</div><div class="lbl">Badges earned</div></div>`;
  }

  function coverHTML(book, cls) {
    if (book.coverUrl) {
      return `<img class="cover ${cls || ""}" src="${esc(book.coverUrl)}" alt="Cover of ${esc(book.title)}"
              onerror="this.outerHTML='<div class=\\'cover ${cls || ""}\\'>${esc(book.title)}</div>'" />`;
    }
    return `<div class="cover ${cls || ""}">${esc(book.title)}</div>`;
  }

  function renderReading() {
    const all = state.books.filter((b) => b.status === "reading");
    const list = all.filter((b) => bookMatches(b, readingQuery))
      .sort((a, b) => new Date(b.addedAt) - new Date(a.addedAt));
    const wrap = $("#reading-list");
    const empty = $("#reading-empty");
    empty.hidden = list.length > 0;
    empty.textContent = all.length === 0
      ? "You're not reading anything yet. Add a book to start logging your pages."
      : "No books match your search.";
    wrap.innerHTML = list.map((b) => {
      const read = pagesRead(b);
      const pct = b.totalPages ? Math.min(100, Math.round((read / b.totalPages) * 100)) : 0;
      const recent = b.logs.slice().sort((x, y) => new Date(y.date) - new Date(x.date)).slice(0, 5);
      return `<article class="book-card" data-id="${b.id}">
        ${coverHTML(b)}
        <div class="book-meta">
          <h3 class="book-title">${esc(b.title)}</h3>
          <p class="book-author">${esc(b.author) || "Unknown author"}</p>
          <div class="progress"><span style="width:${pct}%"></span></div>
          <p class="progress-label">${num(read)}${b.totalPages ? " / " + num(b.totalPages) : ""} pages${b.totalPages ? " · " + pct + "%" : ""}</p>
          ${tagsHTML(b, true)}
          <div class="card-actions">
            <button class="mini" data-action="log" data-id="${b.id}">＋ Log pages</button>
            <button class="mini" data-action="detail" data-id="${b.id}">📈 Progress</button>
            <button class="mini" data-action="finish" data-id="${b.id}">✓ Finish</button>
            <button class="mini" data-action="edit" data-id="${b.id}">✎ Edit</button>
            <button class="mini danger" data-action="delete" data-id="${b.id}">🗑</button>
          </div>
          ${recent.length ? `<details class="logs"><summary>${b.logs.length} session${b.logs.length === 1 ? "" : "s"}</summary>
            ${recent.map((l) => `<div class="log-row">
              <span class="l-pages">+${num(l.pages)}p</span>
              <span class="l-when">${fmtDateTime(l.date)}</span>
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

  function starsHTML(rating) {
    let out = "";
    for (let i = 1; i <= 5; i++) out += `<span class="${i <= (rating || 0) ? "" : "off"}">★</span>`;
    return `<span class="stars">${out}</span>`;
  }

  function renderLibrary() {
    // Populate the genre filter dropdown (keeping the current selection).
    const tagSel = $("#library-tag");
    const tags = allTags();
    if (libraryTag && !tags.some((t) => t.toLowerCase() === libraryTag.toLowerCase())) libraryTag = "";
    tagSel.innerHTML = `<option value="">All genres</option>` + tags.map((t) => `<option value="${esc(t)}">${esc(t)}</option>`).join("");
    tagSel.value = libraryTag;

    const finished = booksFinished();
    let list = finished
      .filter((b) => bookMatches(b, libraryQuery))
      .filter((b) => !libraryTag || (b.tags || []).some((t) => t.toLowerCase() === libraryTag.toLowerCase()));
    const sort = $("#library-sort").value;
    list.sort((a, b) => {
      if (sort === "finished-asc") return new Date(a.finishedAt || 0) - new Date(b.finishedAt || 0);
      if (sort === "rating-desc") return (b.rating || 0) - (a.rating || 0);
      if (sort === "title-asc") return a.title.localeCompare(b.title);
      return new Date(b.finishedAt || 0) - new Date(a.finishedAt || 0); // finished-desc
    });
    const wrap = $("#library-list");
    const empty = $("#library-empty");
    empty.hidden = list.length > 0;
    empty.textContent = finished.length === 0
      ? "No finished books yet. Add books you've already read, or finish one you're reading."
      : "No books match your search or filter.";
    wrap.innerHTML = list.map((b) => `
      <article class="book-card lib-card" data-id="${b.id}">
        ${coverHTML(b)}
        <h3 class="book-title">${esc(b.title)}</h3>
        <p class="book-author">${esc(b.author) || "Unknown author"}</p>
        ${starsHTML(b.rating)}
        <p class="lib-date">Finished ${fmtDate(b.finishedAt)} · ${num(pagesRead(b) || b.totalPages)}p</p>
        ${tagsHTML(b, true)}
        <div class="card-actions">
          <button class="mini" data-action="detail" data-id="${b.id}">📈 Progress</button>
          <button class="mini" data-action="rate" data-id="${b.id}">★ Rate</button>
          <button class="mini" data-action="edit" data-id="${b.id}">✎ Edit</button>
          <button class="mini danger" data-action="delete" data-id="${b.id}">🗑</button>
        </div>
        ${b.review ? `<details class="review"><summary>My review</summary><p class="review-text">${esc(b.review)}</p></details>` : ""}
      </article>`).join("");
  }

  function renderAchievements() {
    const badges = computeBadges();
    const groups = { pages: $("#badges-pages"), books: $("#badges-books"), special: $("#badges-special") };
    Object.values(groups).forEach((el) => (el.innerHTML = ""));
    badges.forEach((b) => {
      const next = b.unlocked ? "" : `<div class="b-prog">${num(b.value)} / ${num(b.target)}</div>`;
      groups[b.group].insertAdjacentHTML("beforeend", `
        <div class="badge ${b.unlocked ? "unlocked" : "locked"}">
          <div class="emoji">${b.emoji}</div>
          <div class="b-title">${esc(b.title)}</div>
          <div class="b-desc">${esc(b.desc)}</div>
          ${next}
        </div>`);
    });
    $("#ach-pages-value").textContent = "· " + num(totalPagesRead()) + " total";
    $("#ach-books-value").textContent = "· " + num(booksFinished().length) + " total";
  }

  function renderGoal() {
    const goal = state.settings.goal;
    const done = booksFinishedInYear(goal.year);
    const target = goal.target || 0;
    const pct = target ? Math.min(100, (done / target) * 100) : 0;
    const r = 52, circ = 2 * Math.PI * r;
    const fg = $("#goal-ring-fg");
    fg.style.strokeDasharray = circ.toFixed(1);
    fg.style.strokeDashoffset = (circ * (1 - pct / 100)).toFixed(1);
    $("#goal-count").textContent = done;
    $("#goal-of").textContent = "of " + target;
    if (document.activeElement !== $("#goal-year")) $("#goal-year").value = goal.year;
    if (document.activeElement !== $("#goal-target")) $("#goal-target").value = target;
    const hint = $("#goal-hint");
    if (target && done >= target) hint.textContent = `🎉 Goal smashed! ${done} books in ${goal.year}.`;
    else if (target) hint.textContent = `${target - done} to go in ${goal.year}.`;
    else hint.textContent = "";
  }

  function renderStatsView() {
    const logs = [];
    state.books.forEach((b) => b.logs.forEach((l) => {
      const d = new Date(l.date);
      if (!isNaN(d)) logs.push({ d, pages: Number(l.pages) || 0 });
    }));
    const empty = logs.length === 0;
    $("#stats-empty").hidden = !empty;

    const streak = readingStreak();
    const perDay = {};
    logs.forEach((x) => { const k = startOfDay(x.d); perDay[k] = (perDay[k] || 0) + x.pages; });
    const daysRead = Object.keys(perDay).length;
    const tp = totalPagesRead();
    const avg = daysRead ? Math.round(tp / daysRead) : 0;
    const best = Object.values(perDay).reduce((m, v) => Math.max(m, v), 0);

    $("#stat-cards").innerHTML = `
      <div class="stat"><div class="num">${num(streak.current)}</div><div class="lbl">Current streak 🔥</div></div>
      <div class="stat"><div class="num">${num(streak.longest)}</div><div class="lbl">Longest streak</div></div>
      <div class="stat"><div class="num">${num(daysRead)}</div><div class="lbl">Days read</div></div>
      <div class="stat"><div class="num">${num(avg)}</div><div class="lbl">Avg pages / day read</div></div>
      <div class="stat"><div class="num">${num(best)}</div><div class="lbl">Best day</div></div>`;

    $("#chart-daily").innerHTML = empty ? "" : svgBars(dailyItems(perDay), "pages");
    $("#chart-monthly").innerHTML = empty ? "" : svgBars(monthlyItems(logs), "pages");
  }

  function dailyItems(perDay) {
    const DAY = 86400000;
    const today = startOfDay(new Date());
    const items = [];
    for (let i = 29; i >= 0; i--) {
      const t = today - i * DAY;
      const d = new Date(t);
      items.push({
        full: d.toLocaleDateString(undefined, { month: "short", day: "numeric" }),
        value: perDay[t] || 0,
        tick: i % 5 === 0 ? (d.getMonth() + 1) + "/" + d.getDate() : "",
      });
    }
    return items;
  }
  function monthlyItems(logs) {
    const NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const now = new Date();
    const buckets = [];
    for (let i = 11; i >= 0; i--) {
      const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
      buckets.push({ y: d.getFullYear(), m: d.getMonth(), value: 0 });
    }
    logs.forEach((x) => {
      const b = buckets.find((bk) => bk.y === x.d.getFullYear() && bk.m === x.d.getMonth());
      if (b) b.value += x.pages;
    });
    return buckets.map((b) => ({ full: NAMES[b.m] + " " + b.y, value: b.value, tick: NAMES[b.m] }));
  }
  function svgBars(items, unit) {
    const slot = 26, H = 170, padT = 16, padB = 26, padX = 8;
    const W = Math.max(items.length * slot + padX * 2, 320);
    const areaH = H - padT - padB;
    const maxV = Math.max(1, ...items.map((i) => i.value));
    const baseY = padT + areaH;
    let out = `<line class="grid-line" x1="${padX}" y1="${padT}" x2="${W - padX}" y2="${padT}"/>`;
    out += `<text class="val-label" x="${padX}" y="${padT - 5}" font-size="9">${num(maxV)} ${unit}</text>`;
    out += `<line class="grid-line" x1="${padX}" y1="${baseY}" x2="${W - padX}" y2="${baseY}"/>`;
    items.forEach((it, i) => {
      const bh = it.value > 0 ? Math.max(2, (it.value / maxV) * areaH) : 0;
      const x = padX + i * slot + slot * 0.18;
      const bw = slot * 0.64;
      const y = baseY - bh;
      out += `<rect class="bar" x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${bh.toFixed(1)}" rx="2"><title>${esc(it.full)}: ${num(it.value)} ${unit}</title></rect>`;
      if (it.tick) out += `<text class="axis-label" x="${(padX + i * slot + slot / 2).toFixed(1)}" y="${H - 9}" text-anchor="middle" font-size="9">${esc(it.tick)}</text>`;
    });
    return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMinYMid meet" role="img" aria-label="bar chart">${out}</svg>`;
  }

  // ---------------------------------------------------------------------------
  // Book detail + per-book progress chart
  // ---------------------------------------------------------------------------
  function openDetailModal(book) {
    $("#detail-title").textContent = book.title;
    const read = pagesRead(book);
    const pct = book.totalPages ? Math.min(100, Math.round((read / book.totalPages) * 100)) : 0;
    const logs = book.logs.slice().sort((a, b) => new Date(b.date) - new Date(a.date));
    const statusLabel = book.status === "finished" ? "Finished" : "Currently reading";
    const dates = book.status === "finished"
      ? (book.finishedAt ? "Finished " + fmtDate(book.finishedAt) : "")
      : (book.startedAt ? "Started " + fmtDate(book.startedAt) : "");
    $("#detail-body").innerHTML = `
      <div class="detail-top">
        ${coverHTML(book)}
        <div class="detail-info">
          <h4>${esc(book.title)}</h4>
          <p class="by">${esc(book.author) || "Unknown author"}</p>
          <div class="detail-meta">
            <span>${statusLabel}${book.rating ? " · " + starsHTML(book.rating) : ""}</span>
            <span>${num(read)}${book.totalPages ? " / " + num(book.totalPages) : ""} pages${book.totalPages ? " · " + pct + "%" : ""}</span>
            ${dates ? `<span>${dates}</span>` : ""}
          </div>
          ${tagsHTML(book, false)}
          <div class="detail-actions">
            ${book.status === "reading" ? `<button class="mini" data-detail-action="log" data-id="${book.id}">＋ Log pages</button>` : ""}
            <button class="mini" data-detail-action="edit" data-id="${book.id}">✎ Edit</button>
          </div>
        </div>
      </div>
      <div class="detail-section">
        <h5>📈 Reading progress</h5>
        <div class="progress-chart">${svgProgress(book)}</div>
      </div>
      <div class="detail-section">
        <h5>Sessions (${book.logs.length})</h5>
        <div class="logs detail-logs">
          ${logs.length ? logs.map((l) => `<div class="log-row">
            <span class="l-pages">+${num(l.pages)}p</span>
            <span class="l-when">${fmtDateTime(l.date)}</span>
            <span class="l-note">${l.note ? "“" + esc(l.note) + "”" : ""}</span>
          </div>`).join("") : `<p class="muted">No sessions logged yet.</p>`}
        </div>
      </div>
      ${book.review ? `<div class="detail-section"><h5>My notes</h5><p class="detail-review">${esc(book.review)}</p></div>` : ""}`;
    showModal("detail-modal");
  }

  // Cumulative pages-read-over-time line/area chart for one book.
  function svgProgress(book) {
    const logs = book.logs.slice()
      .filter((l) => !isNaN(new Date(l.date)))
      .sort((a, b) => new Date(a.date) - new Date(b.date));
    if (!logs.length) return `<p class="muted">No reading sessions yet — log some pages to see your progress.</p>`;
    const W = 520, H = 200, padL = 44, padR = 16, padT = 14, padB = 30;
    const aw = W - padL - padR, ah = H - padT - padB;
    let cum = 0;
    const pts = logs.map((l) => { cum += Number(l.pages) || 0; return { t: new Date(l.date).getTime(), y: cum, date: l.date }; });
    const total = book.totalPages || cum;
    const maxY = Math.max(total, cum, 1);
    const t0 = pts[0].t, t1 = pts[pts.length - 1].t, span = t1 - t0;
    const xOf = (t, i) => span > 0 ? padL + ((t - t0) / span) * aw : padL + (pts.length === 1 ? aw : (i / (pts.length - 1)) * aw);
    const yOf = (v) => padT + ah - (v / maxY) * ah;
    const baseY = padT + ah;
    const linePath = pts.map((p, i) => (i ? "L" : "M") + xOf(p.t, i).toFixed(1) + " " + yOf(p.y).toFixed(1)).join(" ");
    const areaPath = `M${xOf(pts[0].t, 0).toFixed(1)} ${baseY.toFixed(1)} `
      + pts.map((p, i) => "L" + xOf(p.t, i).toFixed(1) + " " + yOf(p.y).toFixed(1)).join(" ")
      + ` L${xOf(t1, pts.length - 1).toFixed(1)} ${baseY.toFixed(1)} Z`;
    const dots = pts.map((p, i) => `<circle class="prog-dot" cx="${xOf(p.t, i).toFixed(1)}" cy="${yOf(p.y).toFixed(1)}" r="3.5"><title>${fmtDate(p.date)}: ${num(p.y)}${book.totalPages ? " / " + num(book.totalPages) : ""} pages</title></circle>`).join("");
    let target = "";
    if (book.totalPages) {
      const ty = yOf(book.totalPages);
      target = `<line class="prog-target" x1="${padL}" y1="${ty.toFixed(1)}" x2="${W - padR}" y2="${ty.toFixed(1)}"/>`
        + `<text class="prog-axis" x="${W - padR}" y="${(ty - 4).toFixed(1)}" text-anchor="end" font-size="9">goal ${num(book.totalPages)}p</text>`;
    }
    const axis = `<line x1="${padL}" y1="${baseY}" x2="${W - padR}" y2="${baseY}" stroke="var(--line)" stroke-width="1"/>`
      + `<text class="prog-axis" x="${padL - 6}" y="${(padT + 4).toFixed(1)}" text-anchor="end" font-size="9">${num(maxY)}</text>`
      + `<text class="prog-axis" x="${padL - 6}" y="${baseY.toFixed(1)}" text-anchor="end" font-size="9">0</text>`
      + `<text class="prog-axis" x="${padL}" y="${H - 10}" font-size="9">${fmtDate(pts[0].date)}</text>`
      + (pts.length > 1 ? `<text class="prog-axis" x="${W - padR}" y="${H - 10}" text-anchor="end" font-size="9">${fmtDate(pts[pts.length - 1].date)}</text>` : "");
    return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet" role="img" aria-label="reading progress over time">`
      + `${axis}${target}<path class="prog-area" d="${areaPath}"/><path class="prog-line" d="${linePath}"/>${dots}</svg>`;
  }

  function renderStorageStatus() {
    const el = $("#storage-status");
    if (fileHandle) {
      el.textContent = "💾 synced to file";
      el.title = "Changes are written to your connected JSON file.";
      return;
    }
    const lock = storagePersisted ? " 🔒" : "";
    el.textContent = (supportsFS ? "💾 saved in this browser" : "💾 saved on this device") + lock;
    el.title = storagePersisted
      ? "Your data is stored persistently and won't be auto-cleared by the browser."
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
    $("#book-modal-title").textContent = book ? "Edit book" : (opts.status === "finished" ? "Add a read book" : "Add a book");
    $("#f-id").value = book ? book.id : "";
    $("#f-title").value = book ? book.title : "";
    $("#f-author").value = book ? book.author : "";
    $("#f-pages").value = book && book.totalPages ? book.totalPages : "";
    $("#f-isbn").value = book ? book.isbn : "";
    $("#f-cover").value = book ? book.coverUrl : "";
    $("#f-review").value = book ? (book.review || "") : "";
    $("#f-tags").value = book && book.tags ? book.tags.join(", ") : "";
    renderTagHelpers();
    $("#cover-candidates").innerHTML = "";
    setCoverPreview(book ? book.coverUrl : "");

    const status = book ? book.status : (opts.status || "reading");
    $$("input[name='f-status']").forEach((r) => (r.checked = r.value === status));
    toggleStatusFields(status);
    $("#f-started").value = (book && book.startedAt) ? book.startedAt.slice(0, 10) : todayISODate();
    $("#f-finished").value = (book && book.finishedAt) ? book.finishedAt.slice(0, 10) : todayISODate();
    modalRating = book && book.rating ? book.rating : 0;
    paintStars($("#f-stars"), modalRating);

    showModal("book-modal");
    setTimeout(() => $("#f-title").focus(), 50);
  }

  function toggleStatusFields(status) {
    $("#reading-fields").hidden = status !== "reading";
    $("#finished-fields").hidden = status !== "finished";
  }

  function setCoverPreview(url) {
    const box = $("#f-cover-preview");
    box.innerHTML = url ? `<img src="${esc(url)}" alt="cover" onerror="this.parentNode.innerHTML='<span class=\\'cover-ph\\'>No cover</span>'" />` : `<span class="cover-ph">No cover</span>`;
  }

  // Datalist autocomplete + quick-add chips for genres already used elsewhere.
  function renderTagHelpers() {
    const tags = allTags();
    $("#tags-datalist").innerHTML = tags.map((t) => `<option value="${esc(t)}"></option>`).join("");
    const current = parseTags($("#f-tags").value).map((t) => t.toLowerCase());
    const suggest = tags.filter((t) => !current.includes(t.toLowerCase())).slice(0, 12);
    $("#tag-suggest").innerHTML = suggest.map((t) => `<span class="tag" data-add-tag="${esc(t)}">+ ${esc(t)}</span>`).join("");
  }

  async function handleFetch() {
    const title = $("#f-title").value.trim();
    const author = $("#f-author").value.trim();
    const isbn = $("#f-isbn").value.trim();
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
      const firstCover = top.cover_i ? coverFromId(top.cover_i) : (top.isbn ? coverFromIsbn(top.isbn[0]) : "");
      if (firstCover) { $("#f-cover").value = firstCover; setCoverPreview(firstCover); }
      // Suggest a few genres from Open Library subjects (only if none entered yet).
      if (!$("#f-tags").value.trim() && Array.isArray(top.subject)) {
        const picks = top.subject
          .filter((s) => s.length < 24 && !/\d|fiction in|accessible|reading level|nyt:/i.test(s))
          .slice(0, 3);
        if (picks.length) { $("#f-tags").value = picks.join(", "); renderTagHelpers(); }
      }
      renderCandidates(docs);
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
    const wrap = $("#cover-candidates");
    wrap.innerHTML = urls.map((u) => `<img src="${esc(u)}" data-cover="${esc(u.replace("-M.jpg", "-L.jpg"))}" alt="cover option" />`).join("");
  }

  function saveBookFromForm(e) {
    e.preventDefault();
    const id = $("#f-id").value;
    const status = $$("input[name='f-status']").find((r) => r.checked).value;
    const existing = id ? state.books.find((b) => b.id === id) : null;
    const title = $("#f-title").value.trim();
    if (!title) return;

    const book = existing || { id: uid(), addedAt: new Date().toISOString(), logs: [] };
    book.title = title;
    book.author = $("#f-author").value.trim();
    book.totalPages = Number($("#f-pages").value) || 0;
    book.isbn = $("#f-isbn").value.trim();
    book.coverUrl = $("#f-cover").value.trim();
    book.review = $("#f-review").value.trim();
    book.tags = parseTags($("#f-tags").value);
    book.status = status;

    if (status === "reading") {
      book.startedAt = $("#f-started").value ? new Date($("#f-started").value).toISOString() : new Date().toISOString();
      book.finishedAt = book.finishedAt || null;
    } else {
      book.finishedAt = $("#f-finished").value ? new Date($("#f-finished").value).toISOString() : new Date().toISOString();
      book.startedAt = book.startedAt || book.finishedAt;
      book.rating = modalRating || book.rating || null;
      // Ensure an already-read book contributes its pages to milestones:
      // if there are no logs yet, record the full read as one session.
      if (book.logs.length === 0 && book.totalPages > 0) {
        book.logs.push({ id: uid(), date: book.finishedAt, pages: book.totalPages, note: "Added as already read" });
      }
    }

    if (!existing) state.books.push(book);
    closeModals();
    commit();
    checkNewBadges();
    toast("✅", existing ? "Book updated" : "Book added", title);
  }

  // ---------------------------------------------------------------------------
  // Log / finish / rate dialogs
  // ---------------------------------------------------------------------------
  function openLogModal(book, log) {
    $("#log-book-id").value = book.id;
    $("#log-id").value = log ? log.id : "";
    $("#log-book-name").textContent = book.title;
    $("#log-modal-title").textContent = log ? "Edit reading session" : "Log a reading session";
    $("#log-pages").value = log ? log.pages : "";
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
    const editId = $("#log-id").value;
    if (editId) {
      const lg = book.logs.find((x) => x.id === editId);
      if (lg) { lg.pages = pages; lg.date = when; lg.note = note; }
    } else {
      book.logs.push({ id: uid(), date: when, pages, note });
    }
    closeModals();
    commit();
    checkNewBadges();
    toast(editId ? "✎" : "📖", editId ? "Log updated" : "Logged " + pages + " pages", book.title);
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
    book.status = "finished";
    book.finishedAt = $("#finish-date").value ? new Date($("#finish-date").value).toISOString() : new Date().toISOString();
    book.rating = finishRating || book.rating || null;
    // Top up logs so the full book counts toward page milestones.
    const read = pagesRead(book);
    if (book.totalPages && read < book.totalPages) {
      book.logs.push({ id: uid(), date: book.finishedAt, pages: book.totalPages - read, note: "Finished the book" });
    }
    closeModals();
    commit();
    checkNewBadges();
    toast("🏁", "Finished!", book.title);
  }

  function rateBook(book) {
    // Reuse the finish modal purely as a rating dialog for already-finished books.
    $("#finish-modal-title").textContent = "Rate this book";
    $("#finish-book-id").value = book.id;
    $("#finish-book-name").textContent = book.title;
    $("#finish-date").value = (book.finishedAt || new Date().toISOString()).slice(0, 10);
    finishRating = book.rating || 0;
    paintStars($("#finish-stars"), finishRating);
    showModal("finish-modal");
  }

  // ---------------------------------------------------------------------------
  // Star inputs
  // ---------------------------------------------------------------------------
  function paintStars(container, rating) {
    container.dataset.rating = rating;
    $$("span", container).forEach((s) => s.classList.toggle("on", Number(s.dataset.star) <= rating));
  }
  function wireStars(container, onSet) {
    container.addEventListener("click", (e) => {
      const star = e.target.closest("[data-star]");
      if (!star) return;
      const v = Number(star.dataset.star);
      onSet(v);
      paintStars(container, v);
    });
    container.addEventListener("mouseover", (e) => {
      const star = e.target.closest("[data-star]");
      if (!star) return;
      const v = Number(star.dataset.star);
      $$("span", container).forEach((s) => s.classList.toggle("on", Number(s.dataset.star) <= v));
    });
    container.addEventListener("mouseleave", () => paintStars(container, Number(container.dataset.rating)));
  }

  // ---------------------------------------------------------------------------
  // Modal plumbing
  // ---------------------------------------------------------------------------
  function showModal(id) { $("#" + id).hidden = false; }
  function closeModals() { $$(".modal-backdrop").forEach((m) => (m.hidden = true)); $("#finish-modal-title").textContent = "Finish this book"; }

  // ---------------------------------------------------------------------------
  // Data import / export / file connect
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
        checkNewBadges();
        toast("⬆️", "Imported", state.books.length + " books loaded");
      } catch (e) { toast("⚠️", "Import failed", "That file isn't valid bookshelf JSON."); }
    };
    reader.readAsText(file);
  }
  async function connectFile() {
    if (!supportsFS) {
      toast("ℹ️", "Use Export / Import", "This browser can't link a file directly. Your data is saved in-browser.");
      return;
    }
    try {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description: "JSON", accept: { "application/json": [".json"] } }],
        multiple: false,
      }).catch(async () => {
        // If user wants a brand-new file instead of opening one.
        const h = await window.showSaveFilePicker({ suggestedName: "bookshelf.json", types: [{ description: "JSON", accept: { "application/json": [".json"] } }] });
        return [h];
      });
      fileHandle = handle;
      // If the file already has data, load it; otherwise write current state into it.
      const fileData = await handle.getFile();
      const text = await fileData.text();
      if (text.trim()) {
        try { state = normalize(JSON.parse(text)); knownBadges = new Set(); } catch (e) { /* keep current state */ }
      }
      await persist();
      render();
      checkNewBadges();
      toast("🔗", "File connected", "Changes now save to your JSON file.");
    } catch (e) {
      if (e && e.name !== "AbortError") { console.warn(e); toast("⚠️", "Couldn't connect file", ""); }
    }
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
      else if (action === "edit-log") {
        const lg = book.logs.find((x) => x.id === actBtn.dataset.log);
        if (lg) openLogModal(book, lg);
      }
      else if (action === "del-log") {
        const lg = book.logs.find((x) => x.id === actBtn.dataset.log);
        if (lg && confirm(`Delete this log of ${num(lg.pages)} pages?`)) {
          book.logs = book.logs.filter((x) => x.id !== lg.id);
          commit();
          toast("🗑", "Log removed", book.title);
        }
      }
      else if (action === "delete") {
        if (confirm(`Remove “${book.title}” from your bookshelf? This can't be undone.`)) {
          state.books = state.books.filter((b) => b.id !== book.id);
          commit();
          toast("🗑", "Removed", book.title);
        }
      }
      return;
    }
    const tagChip = e.target.closest("[data-tag]");
    if (tagChip) {
      const tag = tagChip.dataset.tag;
      if (activeView === "library") { libraryTag = tag; $("#library-tag").value = tag; renderLibrary(); }
      else { readingQuery = tag; $("#reading-search").value = tag; renderReading(); }
      return;
    }
    const addBtn = e.target.closest("[data-add]");
    if (addBtn) openBookModal({ status: addBtn.dataset.add });
  }

  function init() {
    // Tabs
    $("#tabs").addEventListener("click", (e) => {
      const tab = e.target.closest(".tab");
      if (tab) switchView(tab.dataset.view);
    });

    // Main delegated clicks (cards + add buttons)
    $("#main").addEventListener("click", onMainClick);

    // Search + genre filter
    $("#reading-search").addEventListener("input", (e) => { readingQuery = e.target.value.trim(); renderReading(); });
    $("#library-search").addEventListener("input", (e) => { libraryQuery = e.target.value.trim(); renderLibrary(); });
    $("#library-tag").addEventListener("change", (e) => { libraryTag = e.target.value; renderLibrary(); });
    $("#library-sort").addEventListener("change", renderLibrary);

    // Quick-add genre chips in the book form
    $("#tag-suggest").addEventListener("click", (e) => {
      const chip = e.target.closest("[data-add-tag]");
      if (!chip) return;
      const tags = parseTags($("#f-tags").value);
      tags.push(chip.dataset.addTag);
      $("#f-tags").value = parseTags(tags.join(",")).join(", ");
      renderTagHelpers();
    });
    $("#f-tags").addEventListener("input", renderTagHelpers);

    // Actions inside the detail modal (it lives outside #main)
    $("#detail-body").addEventListener("click", (e) => {
      const b = e.target.closest("[data-detail-action]");
      if (!b) return;
      const book = state.books.find((x) => x.id === b.dataset.id);
      if (!book) return;
      closeModals();
      if (b.dataset.detailAction === "log") openLogModal(book);
      else if (b.dataset.detailAction === "edit") openBookModal({ book });
    });

    // Book modal
    $("#book-form").addEventListener("submit", saveBookFromForm);
    $("#btn-fetch").addEventListener("click", handleFetch);
    $("#f-cover").addEventListener("input", (e) => setCoverPreview(e.target.value.trim()));
    $("#cover-candidates").addEventListener("click", (e) => {
      const img = e.target.closest("[data-cover]");
      if (!img) return;
      $$("#cover-candidates img").forEach((i) => i.classList.remove("sel"));
      img.classList.add("sel");
      $("#f-cover").value = img.dataset.cover;
      setCoverPreview(img.dataset.cover);
    });
    $$("input[name='f-status']").forEach((r) => r.addEventListener("change", () => toggleStatusFields(r.value)));
    wireStars($("#f-stars"), (v) => (modalRating = v));

    // Log + finish forms
    $("#log-form").addEventListener("submit", saveLog);
    $("#finish-form").addEventListener("submit", (e) => saveFinish(e));
    wireStars($("#finish-stars"), (v) => (finishRating = v));

    // Goal
    $("#goal-save").addEventListener("click", () => {
      state.settings.goal = { year: Number($("#goal-year").value) || new Date().getFullYear(), target: Number($("#goal-target").value) || 0 };
      commit();
      checkNewBadges();
      toast("🎯", "Goal saved", state.settings.goal.target + " books in " + state.settings.goal.year);
    });

    // Data menu
    $("#btn-export").addEventListener("click", exportJSON);
    $("#btn-import").addEventListener("click", () => $("#import-input").click());
    $("#import-input").addEventListener("change", (e) => { if (e.target.files[0]) importJSON(e.target.files[0]); e.target.value = ""; });
    $("#btn-connect-file").addEventListener("click", connectFile);

    // Theme
    $("#btn-theme").addEventListener("click", toggleTheme);

    // Modal close (backdrop click, ✕, cancel, Esc)
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
