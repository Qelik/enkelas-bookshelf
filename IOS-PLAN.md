# Enkela's Bookshelf → native iOS (Swift / SwiftUI)

Plan for rebuilding the PWA as a native iOS app using stock iOS components, while
keeping the existing Cloudflare Worker backend and the on-the-wire JSON format
unchanged so the web app and the iOS app stay in sync with each other.

**Target:** iOS 17.0 minimum (SwiftData, Swift Charts `Gauge`, `ContentUnavailableView`,
`.scrollTargetBehavior`). Xcode 16+, Swift 6 language mode where practical.

---

## 0. Approach & rejected alternatives

**Chosen: full SwiftUI rewrite of the UI, ported business logic, shared backend.**

The DOM/`innerHTML` rendering layer (roughly 60% of `src/app.ts`) does not survive
the port at all — it becomes SwiftUI views. The *rules* (normalization, progress
math, streaks, badges, challenges, recommender scoring, cover waterfall, sync
conflict resolution) port almost line-for-line and are the valuable part.

Rejected:

- **Capacitor / WKWebView wrapper** — ships in a week, but every screen stays
  non-native: no system navigation, no Dynamic Type, no widgets, no App Intents,
  no VisionKit scanner. Explicitly not what was asked for.
- **Rewriting the backend in Swift (Vapor) too** — the Worker already handles auth,
  sync conflicts, the spoiler gate, and the community board, and the PWA depends
  on it. Keep it. iOS is a second client, not a fork.

**Non-negotiable constraint:** the JSON blob PUT to `/api/data` must be byte-shape
compatible with what `normalize()` (`src/app.ts:236`) produces. If iOS writes a blob
the web app can't read, or drops fields it doesn't understand, users lose data the
moment they switch devices. This drives the data layer design below.

---

## 0.1 Layout — the PWA is not touched

The existing app keeps working exactly as it does today. Nothing at the repo root
is modified, moved, or deleted.

```
Enkela's Bookshelf/
  index.html  app.js  reader.js  sw.js  styles.css  src/   ← UNCHANGED
  manifest.json  icon-*.png  tests.html  QA.md            ← UNCHANGED
  fixtures/                                                ← shared, read-only
  sync-worker/                                             ← ADDITIVE only (§8)
  ios/                                                     ← NEW, all Swift work
    BookshelfApp.xcodeproj
    BookshelfApp/
    BookshelfTests/
    README.md
```

**Why in-repo rather than a sibling repo:** `fixtures/sample-bookshelf.json` is the
conformance fixture both clients must agree on, `sync-worker/` is shared, and
`src/types.d.ts` ↔ the Swift `Wire*` structs are a paired contract that should move
in one commit. A split repo makes every contract change a two-repo dance.

Tradeoff: GitHub Pages serves the whole repo, so `ios/` sources become publicly
readable. That's already true of `src/*.ts`, so it changes nothing in practice — but
if that's unwanted, a sibling repo `Enkela's Bookshelf iOS/` works too and only
costs the shared-fixture convenience. **Flip this before M0 or not at all.**

Guardrails while building:

- Never edit files at the repo root or in `src/` as part of iOS work.
- `sync-worker/` changes are **additive routes + new D1 tables only** — no existing
  route's request or response shape changes, so the deployed PWA keeps working
  against the same Worker mid-rollout.
- `sw.js` `CACHE` / `APP_VERSION` bumps are only needed if PWA shell files change.
  iOS work doesn't touch them, so `scripts/preflight.mjs` stays green.

---

## 1. Feature inventory → native mapping

### Navigation shell

Current: 4 bottom-nav groups with sub-tabs (`NAV_GROUPS`, `src/app.ts:4689`),
10 `<section class="view">` panes in `index.html`, hand-rolled show/hide + history.

| Web | iOS |
|---|---|
| Bottom nav groups (Reading / Shelf / Progress / Community) | `TabView` with 4 tabs, SF Symbols |
| Sub-nav within a group (Want / Library / Owned) | `Picker(.segmented)` in the toolbar, or separate `NavigationStack` roots |
| `#view-book` detail pane + `history.pushState` | `NavigationStack(path:)` with a `NavigationPath`, `.navigationDestination(for: Book.ID)` |
| 20+ `.modal-backdrop` divs, `showModal()` | `.sheet` / `.fullScreenCover` / `.alert` / `.confirmationDialog` |
| Custom toast (`toast()`, `src/app.ts:3605`) | Small custom overlay view — no stock equivalent worth faking; keep it, ~40 lines |
| Confetti (`confetti()`, `src/app.ts:1019`) | `Canvas` + `TimelineView`, or SpriteKit emitter |

### Screens

| Web view | iOS screen | Components |
|---|---|---|
| Reading (`renderReading`) | `ReadingView` | `List` of cards, `ProgressView(value:)`, swipe actions for "Log session" |
| Want / TBR + Read-next picks (`readNextPicks`, `src/app.ts:1457`) | `WantView` | `List`, top `ScrollView(.horizontal)` of pick cards with reasons |
| Library grid / shelf-of-spines / by-author (`renderLibrary`, `shelfHTML`, `authorHTML`) | `LibraryView` | `LazyVGrid` (grid), custom shelf layout (spines), `List` with `Section` headers (author) |
| Shelf drag-reorder (`setupShelfDnD`, `src/app.ts:1684`) | same | `.draggable`/`.dropDestination`, or `List` `.onMove` — **~60 lines of pointer-event code deleted** |
| Owned (`renderOwned`) | `OwnedView` | `List`, `.searchable`, filter `Menu` |
| Journey (`renderJourney`) | `JourneyView` | `List` timeline sections |
| Goals (`renderGoal`, `renderGoalExtra`, `renderChallenges`) | `GoalsView` | `Gauge(.accessoryCircularCapacity)` for the ring, `ProgressView` for pacing |
| Stats (`renderStatsView`, `svgBars`, `svgCalendar`) | `StatsView` | **Swift Charts** — see §5 |
| Achievements (`renderAchievements`) | `BadgesView` | `LazyVGrid` of badge tiles |
| Community recs (`renderCommunity`) | `CommunityView` | `List`, `Menu` category filter, `.refreshable` |
| Book detail (`openBookPage`, `src/app.ts:1988`) | `BookDetailView` | `Form`/`List` sections: progress chart, logs, quotes, journal, characters, vocab |
| Settings modal (`renderSettings`) | `SettingsView` | `Form` with `Section`, `NavigationLink`, `Toggle` |
| Year in Review (`openYearReview`) | `YearReviewView` | `TabView(.page)` story cards, `ShareLink` |

### Input & capture

| Web | iOS |
|---|---|
| `BarcodeDetector` + hand-rolled EAN-13 decoder (`src/app.ts:4198`–`4307`, ~110 lines) | **`DataScannerViewController`** (VisionKit), `.barcode(symbologies: [.ean13, .ean8, .upce])`. Entire decoder is deleted. |
| Camera `getUserMedia` preview | VisionKit owns the camera, no `AVCaptureSession` needed |
| Add/edit book form (`openBookModal`, `saveBookFromForm`) | `Form` in a `.sheet`: `TextField`, `Picker` for format, `Stepper` for pages, `DatePicker` |
| Star rating (`wireStars`, `paintStars`) | Small `HStack` of `Image(systemName:)` with a drag gesture, ~30 lines |
| Tag entry with autocomplete chips (`renderTagHelpers`) | `TextField` + suggestion `Menu`, or a `TokenField`-style flow layout |
| Session timer (`toggleTimer`, `src/app.ts:4134`) | `TimelineView(.periodic)` + **Live Activity** (ActivityKit) on the Lock Screen / Dynamic Island |
| Mood picker | `Picker` or a segmented emoji row |

### Files, sharing, data

| Web | iOS |
|---|---|
| `showOpenFilePicker` / `showSaveFilePicker` ("Connect file", `connectFile`) | **Drop.** Replaced by `.fileImporter` / `.fileExporter` + `FileDocument`. iOS has no live-linked-file model. |
| `exportJSON` / `exportEverything` (`src/app.ts:4491`, `4511`) | `.fileExporter`, plus `ShareLink` to AirDrop/Files/iCloud |
| `importJSON`, `importGoodreads` (CSV) | `.fileImporter` with `[.json, .commaSeparatedText]`; keep the CSV parser (`parseCSV`, `src/app.ts:4580`) verbatim |
| `navigator.share` + canvas share cards (`shareBookCard`, `shareYearCard`, `drawGiftCard`) | **`ImageRenderer`** over a real SwiftUI view + `ShareLink`. ~280 lines of `CanvasRenderingContext2D` code (`src/app.ts:2342`–`2680`) collapse to a SwiftUI view per card. |
| Gift-list deep link (`giftListUrl`, base64url payload) | Universal Links + `.onOpenURL`; keep the same URL format so web ↔ iOS links interop |
| Club invite link (`clubInviteUrl`) | Same — Universal Link, `apple-app-site-association` served from the Pages site |
| `localStorage` (39 call sites) | `@AppStorage`/`UserDefaults` for prefs; **Keychain** for the auth token (see §4) |
| Service worker + manifest + install prompt | **Delete.** The OS is the installer. Offline is the default for a native app. |
| Storage-persistence panel, backup-health nags (`renderStorageStatus`, `renderBackupHealth`) | Mostly delete — iCloud device backup covers it. Keep "last exported" as a light Settings row. |

---

## 2. Data layer

### 2.1 Wire format is the contract

`src/types.d.ts` already defines the exact shape. Port it 1:1 to Codable structs:

```swift
struct WireBook: Codable {
    var id: String
    var title: String
    var author: String
    var totalPages: Int
    var coverUrl: String
    var isbn: String
    var review: String
    var description: String
    var tags: [String]
    var collections: [String]
    var format: BookFormat        // physical | ebook | audio
    var seriesName: String
    var seriesNumber: Int?
    var publishedYear: Int?
    var quotes: [Quote]
    var readCount: Int
    var finishHistory: [FinishRecord]
    var journal: [JournalEntry]
    var characters: [BookCharacter]
    var vocab: [VocabEntry]
    var bookmark: Bookmark?
    var dnfReason: String
    var pickReason: String
    var expectation: Int?
    var loanDue: String
    var owned: Bool
    var location: String
    var coverTriedAt: String?
    var lentTo: String
    var lentAt: String?
    var status: BookStatus        // want | reading | finished | dnf
    var rating: Double?
    var startedAt: String?
    var finishedAt: String?
    var addedAt: String
    var logs: [ReadingLog]
}

struct WireState: Codable {
    var version: Int
    var updatedAt: String
    var settings: Settings
    var shelfOrder: [String]
    var books: [WireBook]
}
```

Dates stay **ISO-8601 strings**, not `Date`, in the wire types. Round-tripping
through `Date` risks reformatting (`"2026-06-01T00:00:00.000Z"` vs
`"2026-06-01T00:00:00Z"`) and producing a blob that differs from what the web app
wrote. Convert to `Date` only at the view-model boundary.

### 2.2 Port `normalize()` exactly

`normalize()` (`src/app.ts:236`, ~80 lines) is the rebuild whitelist: it fills
defaults, coerces types, and drops unknown fields. Port it as `Normalizer.swift`
and cover it with a test that round-trips `fixtures/sample-bookshelf.json`:

```
JSON → WireState → JSON  must be semantically identical to the JS normalize() output
```

Run the same fixture through both implementations once and diff. This is the single
highest-value test in the project — everything else is cosmetic; this one prevents
data loss.

### 2.3 Local persistence: SwiftData

```swift
@Model final class Book {
    #Unique<Book>([\.remoteID])
    var remoteID: String
    var title: String
    …
    @Relationship(deleteRule: .cascade) var logs: [ReadingLog]
}
```

- SwiftData is the local source of truth and drives the UI via `@Query`.
- `Book.toWire()` / `Book.init(wire:)` bridge to the Codable structs for sync,
  export, and import.
- ~~**Unknown-field preservation:** store unknown keys on a `var extras: Data?`~~
  **Wrong — corrected during M0.** `normalize()` is a rebuild whitelist: it
  constructs a fresh object from known fields only and *drops* everything else.
  Preserving extras on the phone would make the two clients produce different
  blobs from the same input, which is the exact failure the round-trip test
  exists to catch. Match the JavaScript and drop them.
  The one place extras genuinely survive is `settings.goal`, where the web app
  uses `Object.assign` — so that stays a raw dictionary rather than a struct.
- Do **not** turn on SwiftData's CloudKit mirroring. The Worker is already the sync
  transport; two sync systems on the same store will fight.

Alternative if SwiftData's migration story feels risky: keep a single canonical
`state.json` in the app container and hold everything in an `@Observable` store in
memory (the app is a few thousand books at most — the web version already holds it
all in one JS object). Simpler, fully faithful to the current architecture, no
schema migrations. **Recommendation: start here, move to SwiftData only if the
book count or query complexity demands it.** It removes an entire class of risk
from milestone 1.

### 2.4 ePub blobs

IndexedDB (`src/reader.ts:115`–`160`) → files in
`Application Support/epubs/<id>.epub`, with a small SwiftData/JSON index holding
metadata, progress, bookmarks, and highlights. Mark the directory
`.isExcludedFromBackup = false` (we *want* them backed up) but be aware of size;
offer a per-book "remove file, keep progress" action.

---

## 3. Business logic to port (mostly mechanical)

These are pure functions today and become pure Swift:

| Web | Lines | Notes |
|---|---|---|
| `pagesRead`, `pagesBefore`, `estimateFinish` | ~40 | direct |
| `readingStreak`, `streakFromDays`, `perDayMap` | ~50 | direct; use `Calendar.startOfDay` |
| `computeBadges`, `checkNewBadges` | ~40 | direct |
| `computeChallenges` | ~30 | direct |
| `readNextPicks` (the on-device recommender) | ~70 | direct; keep it on-device, it's a selling point |
| `shelfInsightLines`, `sessionInsights`, `tasteProfile`, `coachNudges` | ~120 | direct |
| `duplicateGroups`, `shelfDoctorIssues`, `mergeDuplicateGroup` | ~90 | direct |
| `parseCSV` + `importGoodreads` | ~90 | direct |
| `searchOpenLibrary`, `findCoverFor`, `backfillCovers`, `cleanSubjects` | ~150 | becomes `async/await` + `URLSession`; drops the `imgOk()` `Image` probe in favour of a `HEAD`/decode check |
| `mergeShelfOrder` | ~16 | direct |

The `derived()` memo cache (`src/app.ts:317`) is unnecessary — SwiftUI recomputes
cheaply and `@Observable` handles invalidation. Delete it.

---

## 4. Accounts & sync

### 4.1 Client

One `actor SyncClient` wrapping `URLSession`, mirroring `apiFetch` (`src/app.ts:441`):

```
POST /api/register            { email, fullName, password }
POST /api/login               { email, password }
POST /api/password/change
POST /api/password/forgot
POST /api/password/reset
GET  /api/data                → { blob, updatedAt }
PUT  /api/data                { blob, updatedAt, baseUpdatedAt, force? }
GET/POST /api/clubs…
GET/POST /api/recs…
WS   /api/clubs/{id}/ws
```

Base URL `https://enkelas-bookshelf-sync.enkela.workers.dev`, overridable in a
hidden debug setting (mirrors the `enkelas-sync-api` localStorage override).

### 4.2 Conflict handling — port it faithfully

`putData` (`sync-worker/src/worker.ts`) does optimistic concurrency: mismatched
`baseUpdatedAt` returns **409 with the server's blob**. The client
(`pushData`/`pullData`/`adoptServer`, `src/app.ts:512`–`597`) resolves by
`updatedAt` and records the outcome in a conflict log. Port this exactly, including
the log — it's the reason "where did my session go?" is answerable today.

Also handle **413** ("bookshelf too large to sync") with the same user-facing copy.

### 4.3 Token storage — security note

The web app keeps the session token in `localStorage`. On iOS it goes in the
**Keychain** (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`) —
not `UserDefaults`, which is a plist inside the (backed-up, restorable) container.
Handle 401 by clearing the token and re-prompting, matching `handleAuthExpired`.

### 4.4 Background sync

- `BGAppRefreshTask` registered for periodic pull.
- Push on `scenePhase == .background` (debounced, like `schedulePush`).
- `NWPathMonitor` for the offline state that `setSyncStatus("offline")` shows.

### 4.5 Clubs live channel

`new WebSocket(…)` (`src/app.ts:3178`) → `URLSessionWebSocketTask` with an explicit
reconnect/backoff loop and teardown on `scenePhase` change. The spoiler gate is
server-side, so the client just renders what it receives — no client-side filtering
to re-implement, and no way for a client bug to leak a spoiler.

---

## 5. Charts — Swift Charts

Delete all hand-written SVG (`svgBars`, `svgCalendar`, `svgProgress`, ~130 lines):

| Chart | Swift Charts |
|---|---|
| Pages per day / per month | `BarMark(x: .value("Day", d), y: .value("Pages", p))` |
| Genre breakdown | `BarMark` horizontal, or `SectorMark` (iOS 17) |
| Ratings distribution | `BarMark` |
| Per-book cumulative progress + goal line | `LineMark` + `RuleMark`/`AreaMark` |
| Calendar heatmap | `Chart` with `RectangleMark(x: week, y: weekday)` + `.foregroundStyle(by:)` — a genuine 15-line version of the current 30-line SVG builder |
| Yearly goal ring | `Gauge(value:) { } .gaugeStyle(.accessoryCircularCapacity)` |

Free wins: `.chartScrollableAxes`, drag-to-inspect via `.chartOverlay`, VoiceOver
chart descriptions, Dynamic Type-aware axis labels.

---

## 6. The ePub reader (the hard part)

`src/reader.ts` is 1,239 lines: JSZip unzip, OPF/NCX parsing, CSS-column
pagination, a 3D drag-to-turn leaf animation, char-count-based ETA, idle-aware
session clock, TOC, bookmarks, highlights that survive font-size changes, and
full-book search.

### Option A — Readium Swift Toolkit (recommended)

`ReadiumShared` + `ReadiumStreamer` + `ReadiumNavigator` (SPM). Gives EPUB 2/3
parsing, pagination, decorations (highlights), search, TTS, and locators that are
stable across font-size changes — which is exactly the problem `wrapTextRange` /
`findOccurrence` (`src/reader.ts:401`–`440`) solves by hand today.

Port on top of it: the session clock (`startClock`, `markActivity`, `IDLE_MS`,
`SESSION_GAP`), the learned `cpm` ETA (`src/reader.ts:829`–`845`), the quote-to-book
action, and the session summary card. Roughly 250 lines of our logic survives; the
other ~950 are replaced by the toolkit.

Cost: a large third-party dependency tree, and the page-turn animation is
Readium's, not the current 3D leaf.

### Option B — Own engine

`ZIPFoundation` (unzip) + `XMLParser` (OPF/NCX) + `WKWebView` per chapter with the
same CSS-column pagination — a fairly direct port of the existing renderer, since
the current one already runs in a browser engine. The 3D leaf turn survives as-is
(CSS transforms in the web view) or becomes a SwiftUI `rotation3DEffect`.

Cost: we own EPUB edge cases (fixed layout, RTL, embedded fonts, media overlays)
forever.

### Recommendation

**Decision at M5: B, not A.** Reversed after building it. `BookshelfCore` has no
dependencies by design, and Readium is a large transitive tree for a feature
whose distinctive parts are ours anyway. The pagination approach already existed
and was browser-based, so porting it into `WKWebView` was direct — the actual
cost was a ~250-line ZIP reader and an OPF parser, both of which are now tested
against archives the system `zip` produced.

Either way: EPUB import via `.fileImporter` + a `CFBundleDocumentTypes` entry for
`org.idpf.epub-container`, so "Open in Bookshelf" appears in Files, Mail, and Safari.

---

## 7. iOS capabilities the web version can't have

Worth building — this is the justification for going native:

- **WidgetKit** — currently-reading cover + progress bar; streak counter; "pages to
  hit today's goal". Small/medium/Lock Screen.
- **App Intents / Shortcuts / Siri** — "Log 30 pages in <book>", "Start a reading
  session", "What am I reading?". Maps directly onto the existing `BookshelfAPI`
  surface (`src/app.ts:5193`).
- **Live Activity** — the session timer on the Lock Screen and in the Dynamic
  Island; today the timer dies when the tab is backgrounded.
- **Core Spotlight** — books indexed as `CSSearchableItem`, so system search finds
  them; deep-link into `BookDetailView`.
- **Notifications** — daily reading-goal reminder, loan-due reminder (`loanDue` is
  already in the model and currently does nothing but render a badge).
- **Handoff / `NSUserActivity`** — continue reading between iPhone and iPad.
- **Accessibility** — Dynamic Type, VoiceOver, Reduce Motion (the leaf turn), full
  keyboard nav on iPad. Currently a rough spot in the web version.
- **Haptics** — page turn, badge unlock, session saved.
- **Focus filters** — a "Reading" Focus that surfaces the reader.

---

## 8. Worker changes — additive only

Two App Store guidelines require backend work the Worker doesn't have today.
Both are **purely additive**: new routes, new D1 tables, no change to any existing
route's request or response shape, so the deployed PWA keeps working unchanged
against the same Worker throughout.

### 8.0 What exists today (verified)

KV (`BOOKSHELF`) key layout:

| Key | Value |
|---|---|
| `user:<email>` | `{ id, email, fullName, salt, hash, createdAt, pwChangedAt }` |
| `uid:<id>` | `<email>` (reverse index, self-healing) |
| `data:<uid>` | `{ blob, updatedAt }` |
| `rev:<uid>` | session revocation boundary, ms — tokens issued before it are rejected |
| `reset:<sha256b64(token)>` | single-use password-reset record |
| `throttle:<email>`, IP keys | rate limiting |

Sessions are **stateless signed tokens** gated by `rev:<uid>`
(`sync-worker/src/worker.ts:245`, `:258`). That matters: revoking everything is one
KV write, not a session sweep.

D1 (`CLUBS_DB`) tables: `clubs`, `members`, `invites`, `comments`, `reactions`,
`recs`, `rec_votes`.

### 8.1 `DELETE /api/account` — Guideline 5.1.1(v)

Required for any app offering account creation. Currently missing entirely.

```
DELETE /api/account
Authorization: Bearer <token>
Body: { "password": "<current password>" }

200 { ok: true, deleted: { books: n, clubs: n, recs: n } }
401 wrong password  ·  429 throttled
```

**Re-authentication with the current password is required** — this is irreversible
and account-destroying, so a stolen token alone must not be enough to trigger it.
Rate-limit it on the same `throttle:` counters login uses.

Purge order — chosen so a failure at any point leaves the account still
signed-in-able and the delete retryable. Every step is idempotent.

1. **`revokeSessions(uid)`** first. Another device mid-sync would otherwise `PUT
   /api/data` a moment after step 2 and quietly resurrect the blob. Revocation does
   not block a *fresh* login (a new token's `iat` is after the boundary), which is
   exactly what makes the retry possible.
2. **`data:<uid>`** — the private blob, before the account record. Deleting the
   account first would strand the blob with no credential left to authenticate a retry.
3. **D1 purge**, as one `batch()` so a partial failure can't leave a club hostless:
   - `clubs` where `host_uid = uid`: if other members remain, **transfer host** to
     the earliest-joined member — deleting a club out from under five people
     halfway through the book is worse than losing its founder. If sole member,
     delete the club with its `invites`, `comments`, `reactions`.
   - `members` where `uid` → delete. `reactions` where `uid` → delete.
   - `comments` where `uid` → `deleted = 1`. Note this differs from *leaving* a club,
     which keeps your words attributed to "Former member": leaving is a departure,
     deleting your account is a request for erasure.
   - `recs` where `created_by` → `deleted = 1`; `rec_votes` both by them and *on*
     their now-hidden recs → delete, so no rows point at nothing.
   - `invites` by them, `blocks` in both directions, `reports` they filed → delete.
   - Broadcast to each affected club's `ClubRoom` so open sessions see the member
     list change instead of a ghost sitting at 40%.
4. **`user:<email>`, `uid:<uid>`, `throttle:<email>`, the guess counters** — last.
   This is the step that makes it unrecoverable. `rev:<uid>` deliberately *stays*:
   it must outlive the account so any token still in the wild remains dead, and it
   expires on its own TTL.
5. **Sweep `data:<uid>` once more.** KV is eventually consistent, so a request
   already in flight when step 1 landed could still have written one.

Outstanding `reset:` records need no sweep — they're keyed by token hash and aren't
enumerable by uid, and `passwordReset` already re-reads `user:<email>`, finds it
gone, deletes the record and reports the link expired (`worker.ts:455`–`456`).

### 8.2 Moderation — Guideline 1.2 (user-generated content)

The Community board is public UGC. Apple requires all four of: a content filter, a
report mechanism, a block mechanism, and a published EULA with a stated 24-hour
takedown commitment. Clubs are private (≤6 members) but still need report + leave.

New tables (append to `sync-worker/schema-clubs.sql`, all `IF NOT EXISTS` so
re-running the file on the live DB is safe):

```sql
CREATE TABLE IF NOT EXISTS reports (
  id           TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,            -- 'rec' | 'comment'
  target_id    TEXT NOT NULL,
  reporter_uid TEXT NOT NULL,
  reason       TEXT NOT NULL,            -- spam|harassment|sexual|violence|hate|other
  detail       TEXT,
  created_at   TEXT NOT NULL,
  status       TEXT NOT NULL DEFAULT 'open',   -- open|actioned|dismissed
  UNIQUE (kind, target_id, reporter_uid)       -- one report per user per item
);
CREATE INDEX IF NOT EXISTS idx_reports_open ON reports(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reports_target ON reports(kind, target_id);

CREATE TABLE IF NOT EXISTS blocks (
  uid         TEXT NOT NULL,             -- who is blocking
  blocked_uid TEXT NOT NULL,
  created_at  TEXT NOT NULL,
  PRIMARY KEY (uid, blocked_uid)
);
CREATE INDEX IF NOT EXISTS idx_blocks_uid ON blocks(uid);
```

Routes:

```
POST   /api/recs/:id/report                 { reason, detail? }        → 201
POST   /api/clubs/:id/comments/:cid/report  { reason, detail? }        → 201
GET    /api/blocks                          → [{ uid, created_at }]
POST   /api/blocks                          { uid }                    → 201
DELETE /api/blocks/:uid                                                → 200
GET    /api/moderation/reports              (owner only)               → open queue
POST   /api/moderation/reports/:id          (owner only) { action }    → actioned|dismissed
```

Enforcement:

- **Filtering on read.** `/api/recs` and the club comments query gain
  `AND created_by NOT IN (SELECT blocked_uid FROM blocks WHERE uid = ?)`. Blocking
  is one-directional and silent, as users expect.
- **Auto-hide threshold.** 3 distinct reporters on one item → `deleted = 1`
  immediately, status `open` for review. This is what actually satisfies the 24-hour
  commitment without a human permanently on call — the takedown is automatic, the
  review is asynchronous.
- **Content filter on write.** `POST /api/recs` and comment POST run a
  profanity/URL-spam check on `note` / `body` before insert; reject with 422 and a
  clear message. Keep the list small and boring — over-filtering a book-recommendation
  board is its own failure mode.
- **Owner console.** `GET /api/moderation/reports` gated by an `ADMIN_UIDS` env var
  (comma-separated). No UI needed for v1 — `curl` plus a JSON response is a
  legitimate review process for a board this size.
- **EULA.** A terms page hosted on the Pages site, linked from registration, with an
  explicit "no objectionable content" clause and the abuse contact address. Both
  clients add an acceptance checkbox to the register form.

### 8.3 Other submission requirements (client-side)

3. **Privacy manifest** (`PrivacyInfo.xcprivacy`) — declare `UserDefaults` API use
   and the data collected (email, name, reading data). Plus an App Privacy
   "nutrition label" in App Store Connect.
4. **Sign in with Apple** — *not* required here: the requirement applies to apps
   using third-party social login (Google/Facebook). Own email+password is fine.
   Still worth adding for conversion; it maps cleanly onto the existing
   register/login endpoints if the Worker accepts an Apple identity token.
5. **Camera usage string** (`NSCameraUsageDescription`) for the scanner.
6. **Age rating** — UGC pushes it up; expect 12+.

### 8.4 Testing the Worker changes

`sync-worker/test-endpoints.sh` already spins up `wrangler dev --local` and covers
auth, 409 conflicts, the spoiler gate, and the community board. Extend it with:
account deletion (including the wrong-password path and the host-transfer branch),
report → auto-hide at 3, and block → filtered read. Same file, same style.

> Capture responses into a shell variable first (`R=$(curl -s …)`) — inlining curl
> inside a check argument mangles JSON bodies and produces failures that look like
> Worker bugs.

---

## 9. Project structure

All of this lives under `ios/` — nothing outside it is touched (§0.1).

**Revised in M0:** the model and logic live in a local Swift package
(`ios/BookshelfCore/`) that both the app target and the tests depend on, rather
than inside the app target. `swift test` then runs the rules that must match the
web app on macOS in about a second — no simulator, no scheme, no Xcode. The app
target keeps only UI.

```
ios/BookshelfApp/
  App/
    BookshelfApp.swift            // @main, scene phase, deep links
    AppState.swift                // @Observable root store
  Model/
    Wire/                         // Codable mirrors of src/types.d.ts
      WireBook.swift, WireState.swift, Enums.swift
    Normalizer.swift              // port of normalize() — test-locked
    Store.swift                   // persistence + mutations (commit())
    Derived/                      // pagesRead, streaks, badges, challenges, insights
  Sync/
    SyncClient.swift              // URLSession, all /api routes
    SyncEngine.swift              // push/pull/409 resolution/conflict log
    Keychain.swift
    ClubsSocket.swift             // URLSessionWebSocketTask
  Features/
    Reading/  Want/  Library/  Owned/
    Journey/  Goals/  Stats/  Badges/
    BookDetail/  BookForm/  Logging/
    Community/  Clubs/
    Settings/  YearReview/  ShareCards/
  Reader/
    ReaderView.swift, ReaderSession.swift, EpubStore.swift
  Services/
    OpenLibrary.swift             // search + cover waterfall + genres
    CoverCache.swift
    Scanner/DataScannerView.swift // UIViewControllerRepresentable
    GoodreadsCSV.swift
  Widgets/  (extension)
  Intents/  (App Intents)
  Resources/
ios/BookshelfTests/
  NormalizerRoundTripTests.swift  // ← the critical one
  StreakTests.swift, BadgeTests.swift, RecommenderTests.swift
  GoodreadsImportTests.swift, SyncConflictTests.swift
```

`NormalizerRoundTripTests` reads `../../fixtures/sample-bookshelf.json` — a relative
reference out of `ios/`, kept deliberately so the fixture has exactly one copy and
the two clients can't silently drift apart.

---

## 10. Milestones

Each milestone is independently shippable to TestFlight. **MW runs first** and is
independent of all Swift work — it's backend-only, it unblocks two submission
gates, and the existing PWA benefits from it immediately.

| # | Scope | Touches | Rough size |
|---|---|---|---|
| ~~**MW**~~ ✅ | Worker: `DELETE /api/account`, `reports`/`blocks` tables, report + block + moderation routes, content filter, extended `test-endpoints.sh` (112 pass), `terms.html` | `sync-worker/`, `terms.html` | done |
| ~~**M0**~~ ✅ | `ios/` Xcode project, `BookshelfCore` package, `WireState` + `Normalizer`, **golden differential test against the real JS** (27 cases), JSON import/export, app reads an export on device | `ios/` | done |
| ~~**M1**~~ ✅ | Persistent store, tab shell, Reading / Want / Library / Owned, search + sort + tag filter, book detail, session logging, add/edit with Open Library lookup | `ios/` | done |
| ~~**M2**~~ ✅ | Session logging, **persisted timer** (survives an app kill), finish with page top-up, re-read, DNF, bookmark, lending, and all four note kinds (quotes/journal/characters/vocab). Live Activity deferred to M7 — it needs a Widget Extension target | `ios/` | done |
| ~~**M3**~~ ✅ | Auth (Keychain), sync push/pull, 409 resolution, conflict log, foreground/background sync, change password, delete-account UI on MW's endpoint | `ios/` | done |
| ~~**M4**~~ ✅ | Goals with pacing, streaks, badges, challenges, Swift Charts, insights, **calendar heatmap**, **Year in Review** and a shareable card rendered with `ImageRenderer` | `ios/` | done |
| **M5** ✅ | ePub reader — **own engine, not Readium** (see ios/README). Import, ZIP + OPF/nav/NCX parsing, paginated reader, contents/bookmarks/highlights drawer, full-book search, offset-based highlights, save-a-quote, weighted progress, session clock + summary | `ios/` | done |
| ~~**M6**~~ ✅ | Clubs with the server-side spoiler gate, live updates over a scoped WebSocket ticket, community board with voting, and report/block UI on MW's endpoints | `ios/` | done |
| **M7** ✅ | Widget extension target (App Group + snapshot), three widgets, reading-session Live Activity, four App Intents + Siri phrases, Spotlight indexing with deep links, daily/loan reminders, Handoff, haptics, iPad split view | `ios/` | done |
| **M8** | Accessibility pass, Dynamic Type, localization scaffolding, privacy manifest, App Store assets, submission | `ios/` | medium |

Optional follow-up, not on the critical path: surface MW's new endpoints in the PWA
too (a Settings → Delete account row, a report button on community cards). The web
app has no store review to satisfy, but the capability should exist on both clients
so a user isn't forced onto a phone to delete their own account.

---

## 11. Keeping web and iOS in step

- The Worker stays the single source of truth for accounts, sync, clubs, recs.
- `src/types.d.ts` and the Swift `Wire*` structs are a paired contract. Any field
  added on one side must be added on the other **in the same change**, and the
  `extras` passthrough (§2.3) protects users in the window between deploys.
- Keep `fixtures/sample-bookshelf.json` as the shared conformance fixture: the
  existing `tests.html` suite and the new `NormalizerRoundTripTests` both consume it.
- Universal Link formats (`?gift=`, club invite codes) must stay identical so links
  shared from one platform open on the other.

---

## 12. Open decisions

| Decision | Recommendation |
|---|---|
| Where `ios/` lives | In this repo (§0.1). Sibling repo is fine too — decide before M0 |
| Reader engine | Readium first; own-engine port as contained fallback |
| Local store | Plain JSON + `@Observable` store to start; SwiftData only if needed |
| Minimum iOS | 17.0 |
| Cover image caching | Hand-rolled disk cache actor (≈80 lines) — avoids a dependency |
| Sign in with Apple | Add in M8 as an enhancement, not a blocker |
| iPad | Layout-adaptive from M1, dedicated split view in M7 |
| PWA future | Keep it running; it's the Android and desktop story |
