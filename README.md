# 📚 Enkela's Bookshelf

A cozy, **backend-free** reading tracker. Everything runs in the browser and your
data is stored as JSON — no server required, no account required.

Written in **strict TypeScript** (compiled with the Go-native TypeScript 7 toolchain);
sources live in `src/`, and the compiled `app.js`/`reader.js`/`sw.js` are committed at
the repo root so the site still deploys as plain static files with zero CI. Serve the
folder over HTTP (`python3 -m http.server`) to run it — the app loads as ES modules,
which browsers do not allow from `file://`.

**▶ Live app: https://qelik.github.io/enkelas-bookshelf/**
On a phone, open that link and use the browser's **Share → Add to Home Screen** so the data sticks and it works offline.

## Features

- **Want to Read (TBR)** — keep a wishlist of books to read next; one tap moves a book to "currently reading."
- **Currently reading** — add a book and log each reading session (pages + date/time + an optional note, plus an optional built-in **session timer**). A progress bar fills as you go, with an **estimated finish date** based on your recent pace.
- **Formats** — mark a book as physical 📖, e-book 📱, or audiobook 🎧 (audiobooks track minutes).
- **Series & collections** — group books in a series (with book numbers) and file them on custom shelves like "Favourites" or "Book club."
- **Did-not-finish** — mark a book DNF instead of forcing a finish.
- **Barcode scanner** — on a phone, tap 📷 Scan in the add-book form to read a book's ISBN barcode and auto-fill it (Chrome/Android).
- **Goodreads import** — bring in your whole Goodreads library from its CSV export (📥 Goodreads in the header).
- **Library views** — browse as a **grid**, a visual **bookshelf** of spines, or **by author**. Search by title/author/tag, filter by genre or shelf, sort by recent/rating/length/title.
- **Quotes & highlights** — save favourite lines per book (in the 📈 Progress view).
- **Reading logs** — every session is timestamped, and each one can be **edited or deleted** later.
- **Library** — books you've finished, with star ratings, finish dates, and covers. **Search** by title/author/tag, **filter by genre**, and sort by recent, rating, or title.
- **Genre tags** — tag books with genres (auto-suggested from Open Library, with quick-add chips and autocomplete). Tap a tag to filter by it.
- **Per-book progress chart** — tap **📈 Progress** on any book for a detail view with a cumulative pages-over-time chart, a goal line, and the full session history.
- **Already-read books** — add books you read in the past, with their finish date and rating.
- **Notes & reviews** — keep per-book notes or a review; they show on the reading and library cards.
- **Yearly goal** — set how many books you want to read this year and watch the progress ring fill.
- **Goals** — set a books-per-year goal (with a progress ring), an optional **pages-per-year** goal, and a **daily reading goal** with a today check-in; a pacing line tells you if you're ahead of or behind schedule.
- **Reading challenges** — playful yearly challenges (read 5 genres, finish a 500+ page book, books from 3 decades, a book every month, …) that unlock as you go.
- **Owned shelf** — mark books you physically own (🏠 on any book's page, or the checkbox in the add/edit form). The **Owned** tab is your shelf-at-home: search it in the bookshop, or **scan a barcode** to instantly see "you already have this one" before buying a duplicate.
- **Achievement badges** — unlock milestones for pages read (100 → 50,000), books finished (1st, 5th, 10th, …), reading **streaks** (3 / 7 / 30 days), plus special badges. A toast (and 🎉 confetti) pops when you earn one.
- **Reading streaks** — consecutive-day reading streaks (current + longest).
- **Stats & charts** — a Stats tab with a **reading calendar heatmap**, pages-per-day and pages-per-month charts, a **by-genre** breakdown, a **ratings distribution**, and a shareable **Year in Review** recap.
- **Dark mode** — a 🌙 / ☀️ toggle in the header; your choice is remembered.
- **Auto cover art** — covers are fetched automatically from the free [Open Library](https://openlibrary.org) API by title/author/ISBN, with a Google Books fallback. Books that come in without a cover (e.g. from a Goodreads import) are quietly backfilled in the background. Wrong cover? Pick another candidate or paste your own image URL.
- **Reading clubs (spoiler-safe)** — read a book together with friends (⚙️ Settings → 👥 Reading clubs, requires sign-in). Start a club, share the **8-letter invite code** or an **invite link** (📤 Share invite — opening the link joins automatically, even if the friend signs in first). Every member sets how far through they are, and comments are **locked until you've read that far** — the server only ever sends you comments at or below your own progress, so spoilers physically can't reach you. Includes per-comment reactions (❤️🤯😂😢👀), a member progress board, and live updates while the club is open.
- **Community recommendations** — a shared 🌟 Community board where every reader can recommend books per genre and vote 👍/👎; books you've already finished are hidden by default.
- **Read next** — a private, fully on-device recommender: the Want tab opens with up to three picks from your own list, scored against your ratings, favourite genres and authors, series in progress, DNFs, what you own, and how long a book has waited — each with the reasons spelled out. Nothing leaves the device.
- **eReader extras** — inside the built-in ePub reader: a 📑 contents drawer, 🔖 bookmarks, 🖍 text highlights (they survive font-size changes), ✍ save-a-quote straight to the book's page, 🔍 full-book search, and a session summary card (minutes, pages, progress, streak) when you close the book.
- **Data safety** — Settings shows a backup-health panel (what's on the device, when you last exported, whether storage is protected); a gentle backup reminder appears if exports get stale; **📦 Export everything** bundles books + settings + your ePubs (bookmarks and highlights included) into one restorable file; and a 🗂 sync-conflict history lists every time two devices disagreed and which copy won.
- **Shelf insights** — the Stats tab's insight cards now include your shelf: unread owned books (and which has waited longest), series waiting to be continued, possible duplicate editions, favourite genres/authors with nothing queued, and a pick that fits your recent reading rhythm.

## Running it

Just open `index.html` in your browser — double-click it, or:

```sh
# optional: serve it locally (covers + the "Connect file" feature work best this way)
cd "Enkela's Bookshelf"
python3 -m http.server 8000
# then visit http://localhost:8000
```

> Cover lookup needs an internet connection (it calls Open Library). Everything else works offline.

## Accounts & cross-device sync (optional)

Sign in with **email + full name + password** (👤 in the header) to sync your bookshelf
privately across devices — phone and computer stay in step automatically. Each account's
data is isolated; nobody else can see it. Sign-in is **optional** — without it the app works
exactly as before, fully local on the one device.

- Backend: a small **Cloudflare Worker + KV** (free tier) in [`sync-worker/`](sync-worker/) — see its README to deploy your own. Passwords are salted + PBKDF2-hashed; sessions are signed, expiring tokens.
- The app points at the worker via `SYNC_API` in `app.js` (a per-device `localStorage` override, `enkelas-sync-api`, is also supported).
- No "forgot password" email in this version — the owner resets a password with one `wrangler kv key delete` command (see the worker README).
- **Reading clubs & the community board** share the same worker, backed by a **D1 database** (`schema-clubs.sql`) plus a **Durable Object** per club for live updates. The spoiler gate is enforced server-side (`pos_pct <= your progress`, progress is forward-only), so no client bug can leak a spoiler.

## Where your data lives

Because there's no backend, data is persisted in three complementary ways:

1. **Automatically, in your browser** (`localStorage`) — saves on every change. This is the default and works in every browser, on phones and desktop alike. It survives closing the tab, restarting the browser, and rebooting the device.
2. **In a real `bookshelf.json` file** — click **🔗 Connect file** (desktop Chrome/Edge only) to link a JSON file on your computer. From then on, every change is written straight to that file. This is the truest "data in a JSON file" mode.
3. **Export / Import** — **⬇ Export** downloads `enkelas-bookshelf.json` anytime; **⬆ Import** loads one back. Great for backups or moving between devices/browsers.

The little **💾 indicator** in the header tells you where data is stored. A **🔒** means the browser granted *persistent* storage and won't auto-clear it.

## Using it on a phone (and keeping the data safe)

`localStorage` does persist between visits on a phone — it is **not** wiped when Enkela closes the page. But to make it genuinely safe, do two things:

1. **Host it at a URL** (see below) and open *that* on the phone — not a downloaded local file. A stable web address gives the data a stable home.
2. **Add it to the Home Screen.** In the phone browser's share menu, choose **"Add to Home Screen."** This installs it as an app (it's a PWA): it opens full-screen, **works offline**, and — crucially on **iOS** — its data is exempt from Safari's rule that clears unused sites after ~7 days. Opening it from the Home Screen icon keeps the bookshelf safe long-term.

On top of that, the app automatically asks the browser for *persistent* storage on load, which further protects the data from being evicted.

> Data is still per-browser/per-device. To move it to a new phone, use **Export** on the old one and **Import** on the new one. Exporting occasionally is a good backup habit.

## Putting it online (hosting)

The app is just static files, so any static host works for free:

- **GitHub Pages** — push this folder to a repo, enable Pages → you get `https://<user>.github.io/<repo>/`.
- **Netlify / Vercel / Cloudflare Pages** — drag-and-drop the folder, get an HTTPS URL.

Hosting over **HTTPS** is what enables the offline/installable (PWA) features.

### Data shape

```json
{
  "version": 1,
  "settings": { "goal": { "year": 2026, "target": 24 } },
  "books": [
    {
      "id": "…",
      "title": "The Name of the Wind",
      "author": "Patrick Rothfuss",
      "totalPages": 662,
      "coverUrl": "https://covers.openlibrary.org/b/id/8231856-L.jpg",
      "isbn": "9780756404741",
      "review": "Kvothe's voice pulls you in immediately.",
      "tags": ["Fantasy", "Adventure"],
      "status": "reading",
      "rating": null,
      "startedAt": "2026-06-01T00:00:00.000Z",
      "finishedAt": null,
      "addedAt": "2026-06-01T09:12:00.000Z",
      "logs": [
        { "id": "…", "date": "2026-06-01T21:30:00.000Z", "pages": 40, "note": "Great opening." }
      ]
    }
  ]
}
```

## Files

| File | Purpose |
|------|---------|
| `index.html` | Page structure, modals |
| `styles.css` | All styling (warm "bookshelf" theme + dark mode) |
| `app.js` | State, persistence, rendering, achievements, charts, Open Library lookups |
| `reader.js` | Built-in ePub reader (page turns, sessions, TOC/bookmarks/highlights/search) |
| `manifest.json` | PWA manifest (makes it installable to the home screen) |
| `sw.js` | Service worker (offline support) |
| `sync-worker/` | Optional Cloudflare Worker backend (accounts, sync, clubs, community) |
| `icon-192.png`, `icon-512.png`, `apple-touch-icon.png` | App icons |

## Tests & releasing

- `./scripts/run-tests.sh` — serves the folder and runs `tests.html` (the no-build data-logic tests) in headless Chrome. Or just open `tests.html` on the served app.
- `node scripts/preflight.mjs` — pre-release checklist: catches an unbumped `sw.js` cache version, a stale `APP_VERSION`, precache typos, syntax errors, and drift between the two wrangler configs.
- `cd sync-worker && ./test-endpoints.sh` — spins up `wrangler dev --local` and exercises the API end-to-end: auth, sync conflicts (409), the clubs spoiler gate, and the community board.
- `fixtures/` — sample import files for manual QA (a bookshelf export and a Goodreads CSV).
- Before shipping: bump the `CACHE` version in `sw.js` (and `APP_VERSION` in `app.js`) whenever shell files change, then run the QA pass in `QA.md`.
