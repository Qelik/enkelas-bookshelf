# Real-device QA checklist — Enkela's Bookshelf

Preview testing can't catch the "works on my machine, weird on a phone" class of
bugs. Run this pass on real hardware after each meaningful release, before telling
Enkela it's ready. Tick the boxes; note anything odd.

**Automated first:** open `tests.html` on the live site — all data-logic tests should
pass before you start manual QA.

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
- [ ] Read ≥1 min linked to a book → "Session saved · N min" toast; the log appears on the book.
- [ ] Long-press the position readout → diagnostics show ePub, linked book, position, session.
- [ ] Try a large / image-heavy ePub — images load, pages turn without freezing.
- [ ] Feed a non-ePub / corrupt file → clear error, no crash.

## 10. Onboarding (fresh device)
- [ ] New browser profile / after **Clear data** while signed out → welcome modal appears.
- [ ] Each option works (import / add / goal / install); "Skip" dismisses and doesn't reappear.

---

_When everything above passes on both an iPhone and an Android device, it's ready to hand over._
