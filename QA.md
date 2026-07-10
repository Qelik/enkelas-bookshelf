# Real-device QA checklist — Enkela's Bookshelf

Preview testing can't catch the "works on my machine, weird on a phone" class of
bugs. Run this pass on real hardware after each meaningful release, before telling
Enkela it's ready. Tick the boxes; note anything odd.

**Automated first:**
- `./scripts/run-tests.sh` — runs `tests.html` headlessly (or open it on the live site); all data-logic tests must pass.
- `node scripts/preflight.mjs` — release checklist: SW cache bump, APP_VERSION, precache list, syntax, worker-config drift.
- `cd sync-worker && ./test-endpoints.sh` — worker endpoint tests against a local `wrangler dev` (auth, sync 409s, spoiler gate, recs).
- Import fixtures for manual checks live in `fixtures/` (`sample-bookshelf.json`, `sample-goodreads.csv`).

**Dev toggles (paste in the browser console):**
- Perf timing: `localStorage.setItem("enkelas-perf","1")` then reload → `[perf] render …ms` logs.
- Reader diagnostics: in the ePub reader, **long-press the position readout** (bottom bar).
- Force-fresh app files: **Settings → App → Refresh app files**.

---

## 1. iPhone — Safari + PWA install
- [ ] Open the live URL in Safari; page loads, header shows the ⚙️ and sync status.
- [ ] Share → **Add to Home Screen**; launches full-screen (no Safari chrome).
- [ ] Status bar / notch: content isn't hidden behind it; accent strip looks right.
- [ ] Add a book, log a session, finish a book — confetti + toasts fire.
- [ ] Close the app fully, reopen — data is still there.
- [ ] Dark mode follows the toggle and persists across relaunch.

## 2. Android — Chrome + PWA install
- [ ] Open in Chrome; an **Install app** affordance appears (or test **Settings → Install app**).
- [ ] Install; launches standalone from the home screen.
- [ ] Same add/log/finish/reopen checks as above.

## 3. Barcode scanning (real books)
- [ ] **Owned → Scan to check**: scan a book you own → "You already have this."
- [ ] Scan a book you don't own → "Safe to buy!"
- [ ] Add flow → **Scan barcode**: fills ISBN and fetches cover/details.
- [ ] Try glare, slight blur, and an upside-down barcode — decoder still reads it (iOS uses the hand-rolled EAN-13 fallback).
- [ ] Deny camera permission → calm "Camera blocked" message, ISBN entry still works.

## 4. Offline behaviour
- [ ] Go airplane mode. Header shows **📴 Offline**.
- [ ] Add / edit / log books offline — all succeed and persist locally.
- [ ] Reconnect. Header returns to **☁️ Syncing… → ☁️ Synced · just now**; changes reach the account.
- [ ] Kill the app while offline mid-edit, reopen — no data loss.

## 5. Sync status & Settings
- [ ] Signed out: status reads **💾 saved on this device**; tapping it opens Settings.
- [ ] Sign in: status → **☁️ Synced · <time>**; Settings shows "Last synced …".
- [ ] Let the session expire (or clear the token) → **🔑 Sign in to sync**.
- [ ] **Export backup** downloads JSON; **Import backup** restores it (counts match).
- [ ] **Clear data on this device**: wipes local books; if signed in, they return on next sync.

## 6. Two users, one phone
- [ ] Sign in as user A, confirm A's books. Sign out (device becomes a blank shelf).
- [ ] Sign in as user B → only B's books; none of A's leak through.
- [ ] Sign back in as A → A's library restored from the account.

## 7. Large library (500+ books)
- [ ] Import a big Goodreads CSV (or duplicate entries to simulate scale).
- [ ] Scroll Library grid — covers lazy-load, scrolling stays smooth.
- [ ] Switch tabs / add a log with `enkelas-perf` on — note `render` ms; flag if a single render exceeds ~150 ms (that's the trigger for the deferred virtualization work).
- [ ] Shelf Doctor opens and lists issues without hanging.

## 8. Shelf Doctor
- [ ] Open **Settings → Shelf Doctor**. Groups match reality (missing covers/authors/genres/dates, series-without-number, duplicates).
- [ ] **Find cover** / **Fetch genres** on a book actually fills it in.
- [ ] **Merge** on a duplicate pair combines logs/tags and removes the extra.

## 9. ePub reader
- [ ] Upload an ePub; it opens and restores your last page on reopen.
- [ ] Read ≥1 min linked to a book → session-summary card on close (minutes, ~pages, % progress, streak); the log appears on the book.
- [ ] Long-press the position readout → diagnostics show ePub, linked book, position, session.
- [ ] Try a large / image-heavy ePub — images load, pages turn without freezing.
- [ ] Feed a non-ePub / corrupt file → clear error, no crash.
- [ ] **Contents drawer (📑)**: chapter list opens, current chapter marked, tapping one jumps there.
- [ ] **Bookmarks**: 🔖 lights up on a bookmarked page; the bookmark appears under 📑 → Bookmarks; tapping it returns to that page (also after changing font size); 🗑 removes it.
- [ ] **Highlights**: select text mid-page → floating bar appears → 🖍 Highlight marks it; still marked after leaving/returning to the chapter and after A+/A−; listed under 📑 → Highlights; delete removes the mark.
- [ ] **Save quote**: with the ePub linked, ✍ Save quote puts the selection in the book's Quotes on its bookshelf page; unlinked → friendly "link it first" toast.
- [ ] **Search (🔍)**: a word you know is in the book returns snippets; tapping one lands on the right page with the match flashed.

## 9b. Data safety
- [ ] Settings → Your data shows the backup-health panel (books count, last export, storage protection, ePub note).
- [ ] **⬇ Export backup** downloads JSON and "Last backup export" updates to "just now".
- [ ] **📦 Export everything** (with ≥1 ePub uploaded) downloads a bigger file; on a clean profile, importing it restores books AND the ePubs appear in the eReader.
- [ ] **Import backup** still accepts a plain old export (`fixtures/sample-bookshelf.json` works).
- [ ] Force a sync conflict (edit on two devices, then sync) → resolve it → it's listed under Settings → 🗂 Sync conflict history.

## 9c. Read next (TBR picks)
- [ ] With a few finished+rated books and ≥2 TBR books, the Want tab shows the "✨ Read next?" strip with reason chips.
- [ ] Tapping a pick opens the book page; ▶ Start reading moves it to Reading.
- [ ] A brand-new library (no finished books) shows no strip — no nonsense picks.

## 10. Onboarding (fresh device)
- [ ] New browser profile / after **Clear data** while signed out → welcome modal appears.
- [ ] Each option works (import / add / goal / install); "Skip" dismisses and doesn't reappear.

## 11. Reading clubs (needs two accounts, ideally two devices)
- [ ] Signed out: **Settings → Reading clubs** prompts to sign in instead of opening.
- [ ] Create a club → invite code shows in the footer; **Copy code** puts it on the clipboard.
- [ ] **📤 Share invite** opens the native share sheet (or copies a link on desktop).
- [ ] On the second device, open the invite **link** while signed out → sign-in appears → after signing in it joins the club automatically.
- [ ] Join by typing the 8-letter code also works (lowercase input is accepted).
- [ ] Member board: both members appear with progress bars; your own row is highlighted.
- [ ] Spoiler gate: user A at 60% posts a comment; user B at 20% sees "🔒 1 comment ahead", NOT the text. B drags progress past 60% → the comment appears.
- [ ] Progress is forward-only: dragging the slider back down does not hide already-unlocked comments or lower your %.
- [ ] Reactions: tap ❤️ on a comment → count updates for both members; tap again to remove.
- [ ] Live-ish updates: with both devices in the same club, a comment from A shows up on B within seconds (WebSocket) — or ≤20 s if the socket can't connect (poll backstop).
- [ ] Unread dots: activity in a club you're not looking at shows a dot in your club list; opening it clears the dot.
- [ ] **Leave** removes you; rejoining with the code works.

## 12. Community recommendations
- [ ] 🌟 Community tab loads the shared board without signing in (voting requires sign-in).
- [ ] Recommend a book you've finished → it appears with your name; your 👍 is pre-counted.
- [ ] Vote 👍/👎 on someone else's pick; tap again to un-vote; switch votes.
- [ ] Books you've finished are hidden by default; "Show them" reveals them.

---

_When everything above passes on both an iPhone and an Android device, it's ready to hand over._
