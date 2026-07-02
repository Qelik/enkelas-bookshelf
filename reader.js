/* Enkela's Bookshelf — built-in ePub reader.
 * - ePubs are unzipped with the vendored JSZip and stored per-device in IndexedDB.
 * - Chapters are paginated with CSS columns; page turns are a real 3D leaf you
 *   can tap OR grab and drag, with lighting that follows the fold.
 * - Active reading time is tracked (pauses when the tab is hidden or you idle),
 *   reading speed is learned, and the time left is predicted per chapter or for
 *   the whole book. Sessions can be saved to a linked bookshelf book.
 */
(function () {
  "use strict";

  const GAP = 48;            // must match .reader-content column-gap
  const IDLE_MS = 120000;    // stop the clock after 2 min without a page turn/touch
  const DEFAULT_CPM = 1000;  // chars/minute (~200 wpm) until we've learned your pace
  const ETA_KEY = "enkelas-reader-etamode";
  const FS_KEY = "enkelas-reader-fontsize";
  const THEME_KEY = "enkelas-reader-theme";

  const $ = (sel) => document.querySelector(sel);

  // ---------------------------------------------------------------------------
  // Tiny helpers
  // ---------------------------------------------------------------------------
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }
  function toast(emoji, title, sub) {
    const stack = $("#toast-stack");
    if (!stack) return;
    const el = document.createElement("div");
    el.className = "toast";
    el.innerHTML = `<span class="t-emoji">${emoji}</span><div><div class="t-title">${esc(title)}</div>${sub ? `<div class="t-sub">${esc(sub)}</div>` : ""}</div>`;
    stack.appendChild(el);
    setTimeout(() => { el.style.opacity = "0"; el.style.transition = "all .3s"; }, 2600);
    setTimeout(() => el.remove(), 3000);
  }
  function fmtMins(mins) {
    if (mins < 1) return "under a minute";
    if (mins < 60) return mins + " min";
    const h = Math.floor(mins / 60), m = mins % 60;
    return h + "h" + (m ? " " + m + "m" : "");
  }
  function dirOf(path) { const i = path.lastIndexOf("/"); return i >= 0 ? path.slice(0, i + 1) : ""; }
  function resolvePath(baseDir, rel) {
    const parts = (baseDir + rel).split("/");
    const out = [];
    parts.forEach((p) => { if (p === "..") out.pop(); else if (p !== "." && p !== "") out.push(p); });
    return out.join("/");
  }
  async function sha256hex(buf) {
    if (window.crypto && crypto.subtle) {
      const h = await crypto.subtle.digest("SHA-256", buf);
      return Array.from(new Uint8Array(h)).map((b) => b.toString(16).padStart(2, "0")).join("");
    }
    // Non-secure context fallback: cheap fingerprint of size + first bytes.
    const v = new Uint8Array(buf.slice(0, 4096));
    let h = buf.byteLength >>> 0;
    v.forEach((b) => { h = ((h * 31) + b) >>> 0; });
    return "fp-" + h.toString(16) + "-" + buf.byteLength;
  }

  // ---------------------------------------------------------------------------
  // IndexedDB (per-device epub storage)
  // ---------------------------------------------------------------------------
  function openDb() {
    return new Promise((resolve, reject) => {
      const r = indexedDB.open("enkelas-ereader", 1);
      r.onupgradeneeded = () => r.result.createObjectStore("epubs", { keyPath: "id" });
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
    });
  }
  async function idbAll() {
    const db = await openDb();
    return new Promise((resolve, reject) => {
      const q = db.transaction("epubs").objectStore("epubs").getAll();
      q.onsuccess = () => resolve(q.result || []);
      q.onerror = () => reject(q.error);
    });
  }
  async function idbGet(id) {
    const db = await openDb();
    return new Promise((resolve, reject) => {
      const q = db.transaction("epubs").objectStore("epubs").get(id);
      q.onsuccess = () => resolve(q.result || null);
      q.onerror = () => reject(q.error);
    });
  }
  async function idbPut(rec) {
    const db = await openDb();
    return new Promise((resolve, reject) => {
      const q = db.transaction("epubs", "readwrite").objectStore("epubs").put(rec);
      q.onsuccess = () => resolve();
      q.onerror = () => reject(q.error);
    });
  }
  async function idbDel(id) {
    const db = await openDb();
    return new Promise((resolve, reject) => {
      const q = db.transaction("epubs", "readwrite").objectStore("epubs").delete(id);
      q.onsuccess = () => resolve();
      q.onerror = () => reject(q.error);
    });
  }

  // ---------------------------------------------------------------------------
  // ePub parsing
  // ---------------------------------------------------------------------------
  async function parseEpub(buf) {
    if (!window.JSZip) throw new Error("JSZip missing");
    const zip = await JSZip.loadAsync(buf);
    const containerFile = zip.file("META-INF/container.xml");
    if (!containerFile) throw new Error("Not an ePub (no container.xml)");
    const cdoc = new DOMParser().parseFromString(await containerFile.async("string"), "application/xml");
    const rootEl = cdoc.querySelector("rootfile");
    if (!rootEl) throw new Error("Broken ePub (no rootfile)");
    const opfPath = rootEl.getAttribute("full-path");
    const opfDir = dirOf(opfPath);
    const opfFile = zip.file(opfPath);
    if (!opfFile) throw new Error("Broken ePub (missing OPF)");
    const opf = new DOMParser().parseFromString(await opfFile.async("string"), "application/xml");
    const grab = (tag) => { const el = opf.getElementsByTagNameNS("*", tag)[0]; return el ? el.textContent.trim() : ""; };
    const title = grab("title") || "Untitled";
    const author = grab("creator") || "";
    const manifest = {};
    Array.from(opf.getElementsByTagNameNS("*", "item")).forEach((it) => {
      manifest[it.getAttribute("id")] = {
        href: it.getAttribute("href") || "",
        type: it.getAttribute("media-type") || "",
        props: it.getAttribute("properties") || "",
      };
    });
    const spine = Array.from(opf.getElementsByTagNameNS("*", "itemref"))
      .map((ir) => manifest[ir.getAttribute("idref")])
      .filter((m) => m && /html/i.test(m.type))
      .map((m) => resolvePath(opfDir, decodeURIComponent(m.href)));
    if (!spine.length) throw new Error("Broken ePub (empty spine)");
    // Chapter labels: EPUB3 nav doc first, NCX fallback.
    const labels = {};
    try {
      const navItem = Object.values(manifest).find((m) => /\bnav\b/.test(m.props));
      if (navItem) {
        const navPath = resolvePath(opfDir, decodeURIComponent(navItem.href));
        const navDoc = new DOMParser().parseFromString(await zip.file(navPath).async("string"), "text/html");
        navDoc.querySelectorAll("nav a[href]").forEach((a) => {
          const p = resolvePath(dirOf(navPath), decodeURIComponent(a.getAttribute("href").split("#")[0]));
          if (p && !labels[p]) labels[p] = a.textContent.trim();
        });
      } else {
        const ncxItem = Object.values(manifest).find((m) => /ncx/i.test(m.type));
        if (ncxItem) {
          const ncxPath = resolvePath(opfDir, decodeURIComponent(ncxItem.href));
          const ncx = new DOMParser().parseFromString(await zip.file(ncxPath).async("string"), "application/xml");
          Array.from(ncx.getElementsByTagNameNS("*", "navPoint")).forEach((np) => {
            const lbl = np.getElementsByTagNameNS("*", "text")[0];
            const src = np.getElementsByTagNameNS("*", "content")[0];
            if (lbl && src) {
              const p = resolvePath(dirOf(ncxPath), decodeURIComponent((src.getAttribute("src") || "").split("#")[0]));
              if (p && !labels[p]) labels[p] = lbl.textContent.trim();
            }
          });
        }
      }
    } catch (e) { /* labels are optional */ }
    return { zip, title, author, spine, labels };
  }

  // ---------------------------------------------------------------------------
  // Reader state
  // ---------------------------------------------------------------------------
  let rec = null;          // IndexedDB record of the open book
  let book = null;         // { zip, title, author, spine, labels, chars[], totalChars }
  let chapterCache = new Map(); // spine index -> sanitized HTML
  let blobUrls = [];
  let pos = { ch: 0, page: 0 };
  let pag = { step: 1, pages: 1 };
  let turning = false;
  let session = null;      // { seconds, chars, lastActivity, savedSeconds }
  let tickTimer = null;
  let etaMode = "chapter";
  let els = null;

  function grabEls() {
    els = {
      overlay: $("#reader-overlay"),
      bookEl: $("#reader-book"),
      current: $("#reader-current"),
      currentContent: $("#reader-current-content"),
      under: $("#reader-under"),
      underContent: $("#reader-under-content"),
      leaf: $("#reader-leaf"),
      leafContent: $("#reader-leaf-content"),
      leafShade: $("#leaf-shade"),
      titleEl: $("#reader-book-title"),
      chapterEl: $("#reader-chapter-title"),
      posEl: $("#reader-pos"),
      etaEl: $("#reader-eta"),
      timerEl: $("#reader-timer"),
    };
  }

  // ---------------------------------------------------------------------------
  // Chapter loading + sanitizing
  // ---------------------------------------------------------------------------
  async function chapterHTML(i) {
    if (chapterCache.has(i)) return chapterCache.get(i);
    const path = book.spine[i];
    const f = book.zip.file(path);
    if (!f) return "<p>(Missing chapter)</p>";
    const src = await f.async("string");
    const doc = new DOMParser().parseFromString(src, "text/html");
    doc.querySelectorAll("script, style, link, iframe, object, embed, audio, video").forEach((n) => n.remove());
    Array.from(doc.querySelectorAll("*")).forEach((el) => {
      Array.from(el.attributes).forEach((a) => {
        if (/^on/i.test(a.name)) el.removeAttribute(a.name);
        if ((a.name === "href" || a.name === "src") && /^javascript:/i.test(a.value)) el.removeAttribute(a.name);
      });
    });
    const dir = dirOf(path);
    const imgs = Array.from(doc.querySelectorAll("img[src], image"));
    for (const img of imgs) {
      const isSvgImage = img.tagName.toLowerCase() === "image";
      const ref = img.getAttribute("src") || img.getAttribute("href") || img.getAttribute("xlink:href");
      if (!ref || /^(https?:|data:)/i.test(ref)) continue;
      const p = resolvePath(dir, decodeURIComponent(ref));
      const file = book.zip.file(p);
      if (!file) { img.remove(); continue; }
      const blob = await file.async("blob");
      const url = URL.createObjectURL(blob);
      blobUrls.push(url);
      if (isSvgImage) { img.setAttribute("href", url); img.removeAttribute("xlink:href"); }
      else img.setAttribute("src", url);
    }
    const html = doc.body ? doc.body.innerHTML : src;
    chapterCache.set(i, html);
    if (chapterCache.size > 6) chapterCache.delete(chapterCache.keys().next().value);
    return html;
  }
  async function computeChars() {
    const chars = [];
    for (let i = 0; i < book.spine.length; i++) {
      const f = book.zip.file(book.spine[i]);
      if (!f) { chars.push(0); continue; }
      const s = await f.async("string");
      chars.push(s.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").length);
    }
    book.chars = chars;
    book.totalChars = chars.reduce((a, b) => a + b, 0) || 1;
    updateBars();
  }

  // ---------------------------------------------------------------------------
  // Pagination (CSS columns → horizontal pages)
  // ---------------------------------------------------------------------------
  function layout(contentEl) {
    const w = contentEl.clientWidth || contentEl.parentElement.clientWidth;
    contentEl.style.columnWidth = w + "px";
    const step = w + GAP;
    const pages = Math.max(1, Math.round((contentEl.scrollWidth + GAP) / step));
    return { step, pages, w };
  }
  function setPage(contentEl, page, step) {
    contentEl.style.transform = "translateX(" + (-page * step) + "px)";
  }
  async function showChapter(i, page, fromEnd) {
    const html = await chapterHTML(i);
    els.currentContent.innerHTML = html;
    els.currentContent.style.transform = "translateX(0)";
    pag = layout(els.currentContent);
    pos.ch = i;
    pos.page = fromEnd ? pag.pages - 1 : Math.min(page || 0, pag.pages - 1);
    setPage(els.currentContent, pos.page, pag.step);
    updateBars();
    saveProgress();
  }

  // ---------------------------------------------------------------------------
  // Page turning — the 3D leaf
  // ---------------------------------------------------------------------------
  async function prepareTurn(dir) {
    // Returns a "turn" object or null when at the very start/end of the book.
    const forward = dir > 0;
    let target;
    if (forward) {
      if (pos.page < pag.pages - 1) target = { ch: pos.ch, page: pos.page + 1 };
      else if (pos.ch < book.spine.length - 1) target = { ch: pos.ch + 1, page: 0 };
      else return null;
    } else {
      if (pos.page > 0) target = { ch: pos.ch, page: pos.page - 1 };
      else if (pos.ch > 0) target = { ch: pos.ch - 1, page: -1 }; // -1 = last page
      else return null;
    }
    const prior = { ch: pos.ch, page: pos.page, html: els.currentContent.innerHTML, pag: { ...pag } };
    const leafFace = els.leafContent;
    if (forward) {
      // Leaf shows the page we're leaving; cover the view with it BEFORE the
      // target is swapped in underneath, so nothing flashes.
      leafFace.innerHTML = prior.html;
      leafFace.style.columnWidth = prior.pag.step - GAP + "px";
      setPage(leafFace, prior.page, prior.pag.step);
      els.leaf.hidden = false;
      els.leaf.classList.remove("anim");
      setLeafAngle(0);
      await showChapter(target.ch, target.page, target.page === -1);
    } else {
      // Leaf carries the target page back in over the current one.
      const html = await chapterHTML(target.ch);
      els.underContent.innerHTML = html;
      els.underContent.style.transform = "translateX(0)";
      const tpag = layout(els.underContent);
      const tpage = target.page === -1 ? tpag.pages - 1 : target.page;
      leafFace.innerHTML = html;
      leafFace.style.columnWidth = tpag.step - GAP + "px";
      setPage(leafFace, tpage, tpag.step);
      target.page = tpage;
      target.pag = tpag;
    }
    els.leaf.hidden = false;
    els.leaf.classList.remove("anim");
    setLeafAngle(forward ? 0 : -180);
    // force reflow so the starting angle is committed before animating
    void els.leaf.offsetWidth;
    return { forward, target, prior };
  }
  function setLeafAngle(deg) {
    els.leaf.style.transform = "rotateY(" + deg + "deg)";
    // lighting follows the fold: strongest when the page stands upright
    const t = Math.abs(deg) / 180;
    els.leafShade.style.opacity = String(Math.sin(t * Math.PI) * 0.45);
  }
  function finishTurn(turn, committed) {
    return new Promise((resolve) => {
      const endDeg = turn.forward
        ? (committed ? -180 : 0)
        : (committed ? 0 : -180);
      els.leaf.classList.add("anim");
      setLeafAngle(endDeg);
      let finished = false; // done() can fire from transitionend AND the safety timeout
      const done = async () => {
        if (finished) return;
        finished = true;
        els.leaf.removeEventListener("transitionend", done);
        els.leaf.classList.remove("anim");
        if (turn.forward && !committed) {
          // put the original page back
          els.currentContent.innerHTML = turn.prior.html;
          pag = layout(els.currentContent);
          pos.ch = turn.prior.ch;
          pos.page = Math.min(turn.prior.page, pag.pages - 1);
          setPage(els.currentContent, pos.page, pag.step);
        }
        if (!turn.forward && committed) {
          els.currentContent.innerHTML = els.leafContent.innerHTML;
          pag = turn.target.pag;
          pos.ch = turn.target.ch;
          pos.page = turn.target.page;
          setPage(els.currentContent, pos.page, pag.step);
        }
        els.leaf.hidden = true;
        updateBars();
        saveProgress();
        if (committed && turn.forward) countPageRead(turn.prior);
        markActivity();
        turning = false;
        resolve();
      };
      els.leaf.addEventListener("transitionend", done);
      // safety net in case transitionend is swallowed
      setTimeout(done, 600);
    });
  }
  async function turnPage(dir) {
    if (turning || !book) return;
    turning = true;
    const turn = await prepareTurn(dir);
    if (!turn) { turning = false; return; }
    await finishTurn(turn, true);
  }

  // Grab a page corner and drag it — the leaf follows your finger.
  // NB: pointerup can arrive before the async page preparation resolves (a fast
  // tap), so the drag record is created synchronously and the turn is awaited.
  function setupDragTurn() {
    let drag = null;
    const start = (e, dir) => {
      if (turning || !book || drag) return;
      turning = true;
      const d = { startX: e.clientX, width: els.bookEl.clientWidth || 600, moved: false, turn: null };
      d.ready = prepareTurn(dir).then((turn) => { d.turn = turn; return turn; });
      drag = d;
    };
    const move = (e) => {
      if (!drag || !drag.turn) return; // leaf not ready yet — ignore micro-moves
      const dx = e.clientX - drag.startX;
      if (Math.abs(dx) > 6) drag.moved = true;
      if (drag.turn.forward) {
        const t = Math.min(1, Math.max(0, -dx / drag.width));
        setLeafAngle(-t * 180);
      } else {
        const t = Math.min(1, Math.max(0, dx / drag.width));
        setLeafAngle(-180 + t * 180);
      }
    };
    const end = async (e) => {
      if (!drag) return;
      const d = drag; drag = null;
      const turn = await d.ready;
      if (!turn) { turning = false; return; } // already at the cover / back page
      const dx = e.clientX - d.startX;
      if (!d.moved) { await finishTurn(turn, true); return; } // a plain tap
      const t = turn.forward ? -dx / d.width : dx / d.width;
      await finishTurn(turn, t > 0.28);
    };
    const zoneNext = $("#reader-zone-next"), zonePrev = $("#reader-zone-prev");
    const capture = (z, e) => { try { z.setPointerCapture(e.pointerId); } catch (err) { /* pointer not active — drag still works via the window fallback */ } };
    zoneNext.addEventListener("pointerdown", (e) => { capture(zoneNext, e); start(e, 1); });
    zonePrev.addEventListener("pointerdown", (e) => { capture(zonePrev, e); start(e, -1); });
    [zoneNext, zonePrev].forEach((z) => {
      z.addEventListener("pointermove", move);
      z.addEventListener("pointerup", end);
      z.addEventListener("pointercancel", (e) => end(e));
    });
    // If capture failed and the pointer is released outside the zone,
    // finish the turn anyway so the leaf never gets stranded mid-air.
    window.addEventListener("pointerup", (e) => { if (drag) end(e); });
  }

  // ---------------------------------------------------------------------------
  // Time tracking + ETA
  // ---------------------------------------------------------------------------
  function markActivity() { if (session) session.lastActivity = Date.now(); }
  function countPageRead(prior) {
    if (!session || !book.chars || !book.chars.length) return;
    const perPage = (book.chars[prior.ch] || 0) / Math.max(1, prior.pag.pages);
    session.chars += perPage;
  }
  function cpm() {
    const learned = rec && rec.stats && rec.stats.cpm;
    if (session && session.seconds > 120 && session.chars > 500) {
      const live = session.chars / (session.seconds / 60);
      return learned ? (learned + live) / 2 : live;
    }
    return learned || DEFAULT_CPM;
  }
  function etaText() {
    if (!book || !book.chars || !book.chars.length) return "⏱ estimating…";
    const chapChars = book.chars[pos.ch] || 0;
    const leftInChapter = chapChars * Math.max(0, (pag.pages - pos.page - 1) / Math.max(1, pag.pages));
    let chars = leftInChapter;
    if (etaMode === "book") for (let i = pos.ch + 1; i < book.chars.length; i++) chars += book.chars[i];
    const mins = Math.ceil(chars / Math.max(200, cpm()));
    return "⏱ ≈ " + fmtMins(mins) + " left in " + (etaMode === "book" ? "the book" : "this chapter");
  }
  function bookPct() {
    if (!book.chars || !book.chars.length) return 0;
    let before = 0;
    for (let i = 0; i < pos.ch; i++) before += book.chars[i];
    before += (book.chars[pos.ch] || 0) * ((pos.page + 1) / Math.max(1, pag.pages));
    return Math.min(100, Math.round((before / book.totalChars) * 100));
  }
  function updateBars() {
    if (!book) return;
    const label = book.labels[book.spine[pos.ch]] || "Chapter " + (pos.ch + 1);
    els.chapterEl.textContent = label;
    els.posEl.textContent = "Ch " + (pos.ch + 1) + "/" + book.spine.length + " · page " + (pos.page + 1) + "/" + pag.pages + (book.chars ? " · " + bookPct() + "%" : "");
    els.etaEl.textContent = etaText();
  }
  function startClock() {
    session = { seconds: 0, chars: 0, lastActivity: Date.now(), lastTick: Date.now() };
    clearInterval(tickTimer);
    // Wall-clock deltas rather than tick counting: browsers throttle timers in
    // background tabs, and we don't want reading time to silently undercount.
    tickTimer = setInterval(() => {
      if (!session) return;
      const now = Date.now();
      const dt = Math.min(5, Math.max(0, Math.round((now - session.lastTick) / 1000)));
      session.lastTick = now;
      if (document.hidden) return;                        // not looking at the book
      if (now - session.lastActivity > IDLE_MS) return;   // wandered off mid-page
      session.seconds += dt;
      rec.stats.seconds = (rec.stats.seconds || 0) + dt;
      const m = Math.floor(session.seconds / 60), s = session.seconds % 60;
      els.timerEl.textContent = "⏱ " + m + ":" + String(s).padStart(2, "0");
      if (session.seconds % 15 < dt) els.etaEl.textContent = etaText();
      if (session.seconds % 60 < dt) { updateSpeed(); idbPut(rec); }
    }, 1000);
  }
  function updateSpeed() {
    if (!session || session.seconds < 120 || session.chars < 500) return;
    const live = session.chars / (session.seconds / 60);
    rec.stats.cpm = rec.stats.cpm ? rec.stats.cpm * 0.7 + live * 0.3 : live;
  }

  // ---------------------------------------------------------------------------
  // Open/close + progress
  // ---------------------------------------------------------------------------
  function saveProgress() {
    if (!rec || !book) return;
    rec.progress = { ch: pos.ch, page: pos.page, pct: book.chars ? bookPct() : 0 };
    idbPut(rec);
  }
  async function openBook(id) {
    const r = await idbGet(id);
    if (!r) { toast("⚠️", "Book not found", "Try uploading it again."); return; }
    try {
      grabEls();
      book = await parseEpub(r.data);
      rec = r;
      rec.lastOpened = new Date().toISOString();
      rec.stats = rec.stats || { seconds: 0, cpm: 0 };
      chapterCache = new Map();
      etaMode = localStorage.getItem(ETA_KEY) === "book" ? "book" : "chapter";
      const fs = Number(localStorage.getItem(FS_KEY)) || 19;
      els.overlay.style.setProperty("--rd-fs", fs + "px");
      els.overlay.dataset.rdTheme = localStorage.getItem(THEME_KEY) || "paper";
      els.titleEl.textContent = book.title;
      document.querySelectorAll(".modal-backdrop").forEach((m) => (m.hidden = true));
      els.overlay.hidden = false;
      const p = rec.progress || { ch: 0, page: 0 };
      await showChapter(Math.min(p.ch || 0, book.spine.length - 1), p.page || 0);
      book.chars = null;
      computeChars(); // async; ETA appears when ready
      startClock();
      toast("📖", "Enjoy your book", book.title + (rec.progress && rec.progress.pct ? " · " + rec.progress.pct + "%" : ""));
    } catch (e) {
      console.warn(e);
      toast("⚠️", "Couldn't open that ePub", e.message || "The file may be corrupted.");
    }
  }
  function closeReader() {
    if (!els || els.overlay.hidden) return;
    clearInterval(tickTimer);
    updateSpeed();
    saveProgress();
    const secs = session ? session.seconds : 0;
    const charsRead = session ? session.chars : 0;
    // Hand the session to the bookshelf as a reading log.
    if (secs >= 60 && rec.linkedBookId && window.BookshelfAPI) {
      const linked = window.BookshelfAPI.getBooks().find((b) => b.id === rec.linkedBookId);
      let pages = 0;
      if (linked && linked.totalPages && book && book.totalChars) {
        pages = Math.round((charsRead / book.totalChars) * linked.totalPages);
      }
      window.BookshelfAPI.addReadingLog(rec.linkedBookId, { minutes: Math.round(secs / 60), pages, note: "📖 eReader session" });
    } else if (secs >= 60) {
      toast("⏱", "Nice session!", Math.round(secs / 60) + " min — link this ePub to a book to log it automatically.");
    }
    idbPut(rec);
    session = null;
    blobUrls.forEach((u) => URL.revokeObjectURL(u));
    blobUrls = [];
    book = null; rec = null;
    els.overlay.hidden = true;
  }

  // ---------------------------------------------------------------------------
  // eReader library modal
  // ---------------------------------------------------------------------------
  async function renderList() {
    const wrap = $("#ereader-list");
    const items = (await idbAll()).sort((a, b) => (b.lastOpened || b.addedAt || "").localeCompare(a.lastOpened || a.addedAt || ""));
    const books = window.BookshelfAPI ? window.BookshelfAPI.getBooks() : [];
    if (!items.length) {
      wrap.innerHTML = `<p class="empty">No ePubs yet. Upload one and it'll be waiting for you here — bookmark, reading speed and all.</p>`;
      return;
    }
    wrap.innerHTML = items.map((r) => {
      const pct = r.progress && r.progress.pct ? r.progress.pct + "%" : "not started";
      const mins = Math.round((r.stats && r.stats.seconds || 0) / 60);
      const options = [`<option value="">— not linked —</option>`]
        .concat(books.map((b) => `<option value="${esc(b.id)}"${r.linkedBookId === b.id ? " selected" : ""}>${esc(b.title)}</option>`)).join("");
      return `<div class="ereader-item" data-epub="${esc(r.id)}">
        <span class="er-icon">📕</span>
        <div class="er-meta">
          <div class="er-title">${esc((r.meta && r.meta.title) || r.name)}</div>
          <div class="er-sub">${esc((r.meta && r.meta.author) || "")}${(r.meta && r.meta.author) ? " · " : ""}${pct}${mins ? " · " + mins + " min read" : ""}</div>
          <div class="er-link-row"><span class="muted">Log sessions to:</span>
            <select class="select er-link">${options}</select>
          </div>
        </div>
        <div class="er-actions">
          <button class="primary er-read">▶ Read</button>
          <button class="ghost er-delete" title="Remove from this device">🗑</button>
        </div>
      </div>`;
    }).join("");
  }
  async function handleUpload(file) {
    if (!file) return;
    try {
      const buf = await file.arrayBuffer();
      const id = await sha256hex(buf);
      const existing = await idbGet(id);
      if (existing) { toast("ℹ️", "Already in your eReader", (existing.meta && existing.meta.title) || file.name); return; }
      const parsed = await parseEpub(buf);
      // Auto-link when a bookshelf book has a matching title.
      let linkedBookId = "";
      if (window.BookshelfAPI) {
        const t = parsed.title.toLowerCase();
        const hit = window.BookshelfAPI.getBooks().find((b) => b.title && (b.title.toLowerCase() === t || t.includes(b.title.toLowerCase()) || b.title.toLowerCase().includes(t)));
        if (hit) linkedBookId = hit.id;
      }
      await idbPut({
        id, name: file.name, data: buf,
        meta: { title: parsed.title, author: parsed.author },
        addedAt: new Date().toISOString(), lastOpened: "",
        progress: { ch: 0, page: 0, pct: 0 },
        stats: { seconds: 0, cpm: 0 },
        linkedBookId,
      });
      toast("📚", "Added to your eReader", parsed.title + (linkedBookId ? " · linked to your bookshelf" : ""));
      renderList();
    } catch (e) {
      console.warn(e);
      toast("⚠️", "Couldn't read that file", e.message || "Is it a valid .epub?");
    }
  }

  // ---------------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------------
  function init() {
    grabEls();
    $("#ereader-upload-btn").addEventListener("click", () => $("#ereader-file").click());
    $("#ereader-file").addEventListener("change", (e) => { handleUpload(e.target.files[0]); e.target.value = ""; });
    $("#ereader-list").addEventListener("click", (e) => {
      const item = e.target.closest(".ereader-item");
      if (!item) return;
      const id = item.dataset.epub;
      if (e.target.closest(".er-read")) openBook(id);
      else if (e.target.closest(".er-delete")) {
        if (confirm("Remove this ePub from this device? Your bookshelf logs stay.")) idbDel(id).then(renderList);
      }
    });
    $("#ereader-list").addEventListener("change", async (e) => {
      const sel = e.target.closest(".er-link");
      if (!sel) return;
      const item = e.target.closest(".ereader-item");
      const r = await idbGet(item.dataset.epub);
      if (r) { r.linkedBookId = sel.value; await idbPut(r); }
    });

    $("#reader-close").addEventListener("click", closeReader);
    $("#reader-font-minus").addEventListener("click", () => bumpFont(-1));
    $("#reader-font-plus").addEventListener("click", () => bumpFont(1));
    $("#reader-theme-btn").addEventListener("click", cycleTheme);
    $("#reader-eta").addEventListener("click", () => {
      etaMode = etaMode === "chapter" ? "book" : "chapter";
      try { localStorage.setItem(ETA_KEY, etaMode); } catch (e) { /* ignore */ }
      els.etaEl.textContent = etaText();
    });
    setupDragTurn();
    document.addEventListener("keydown", (e) => {
      if (!els || els.overlay.hidden) return;
      if (e.key === "ArrowRight" || e.key === " ") { e.preventDefault(); turnPage(1); }
      else if (e.key === "ArrowLeft") { e.preventDefault(); turnPage(-1); }
      else if (e.key === "Escape") closeReader();
    });
    window.addEventListener("resize", () => {
      if (!book || els.overlay.hidden) return;
      const frac = pag.pages > 1 ? pos.page / (pag.pages - 1) : 0;
      pag = layout(els.currentContent);
      pos.page = Math.round(frac * (pag.pages - 1));
      setPage(els.currentContent, pos.page, pag.step);
      updateBars();
    });
    document.addEventListener("pointerdown", () => markActivity(), true);
    window.addEventListener("beforeunload", () => { if (rec) { updateSpeed(); saveProgress(); } });
  }
  function bumpFont(dir) {
    const cur = Number(localStorage.getItem(FS_KEY)) || 19;
    const next = Math.max(14, Math.min(26, cur + dir));
    try { localStorage.setItem(FS_KEY, String(next)); } catch (e) { /* ignore */ }
    els.overlay.style.setProperty("--rd-fs", next + "px");
    if (book) {
      pag = layout(els.currentContent);
      pos.page = Math.min(pos.page, pag.pages - 1);
      setPage(els.currentContent, pos.page, pag.step);
      updateBars();
    }
  }
  function cycleTheme() {
    const order = ["paper", "sepia", "night"];
    const cur = els.overlay.dataset.rdTheme || "paper";
    const next = order[(order.indexOf(cur) + 1) % order.length];
    els.overlay.dataset.rdTheme = next;
    try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* ignore */ }
  }

  window.EReader = {
    openLibrary() {
      renderList();
      $("#ereader-modal").hidden = false;
    },
  };

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
