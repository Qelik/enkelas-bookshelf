# Enkela's Bookshelf — iOS

The native SwiftUI client. Shares the Cloudflare Worker backend and the blob
format with the PWA at the repo root, which is **not touched by anything in this
folder** — see [`../IOS-PLAN.md`](../IOS-PLAN.md) for the full plan and milestones.

Requires Xcode 26 / Swift 6. Deployment target iOS 17.

## Layout

```
ios/
  BookshelfCore/                Swift package: wire types, normalizer, store, reading maths, lookup
  BookshelfApp/                 The iOS app target's sources (SwiftUI only)
  BookshelfWidgets/             The widget extension: widgets + the Live Activity
  BookshelfApp.xcodeproj
  BookshelfApp-Info.plist       ┐ outside their target folders on purpose —
  BookshelfApp.entitlements     │ those folders are synchronized groups, so
  BookshelfWidgets-Info.plist   │ anything inside is picked up as a source
  BookshelfWidgets.entitlements ┘ or a resource
  Tools/                        The JS↔Swift golden-file generator, and the icon renderer
```

## The app icon

`Tools/make-app-icon.swift` draws it with CoreGraphics and writes the PNG:

```sh
swift ios/Tools/make-app-icon.swift /tmp/icons
```

CoreGraphics rather than an SVG toolchain because this machine has none
(`rsvg-convert`, ImageMagick, Pillow all absent) and `swift` ships with Xcode.
The upside is that the icon is **reproducible from source** — regenerate at any
size, and a colour change is a diff rather than a binary blob nobody can review.

It renders three variants and a contact sheet showing each at 1024, 180 and 60
points. The 60 is the one that decides: the first draft had a cream shelf under
cream spines, which merged into one blob at that size and made the middle book
vanish. The shelf is rose now. `spines` is the one shipping — almost every
reading app is an open book, and a shelf is what this app actually is.

The plum is the same hue family (≈290) the app and the web version already draw
for a book with no cover art, so the icon belongs to the set of colours behind it.

Two hard requirements, both enforced in the renderer:

- **No alpha channel.** An App Store icon with one is rejected at upload, which
  is why the bitmap context is `.noneSkipLast`. Check with
  `sips -g hasAlpha <file>`.
- **No baked-in rounded corners.** iOS masks the icon itself; a pre-rounded
  square gets rounded twice.

One 1024 universal image is all that's in the catalog — Xcode derives the rest
(`AppIcon60x60@2x`, `AppIcon76x76@2x~ipad`). Dark and tinted appearance variants
for iOS 18+ are not provided yet; the system falls back to this one.

The split is strict: `BookshelfCore` has no SwiftUI in it and `BookshelfApp` has no
business logic. That is what lets the rules that must match the web app be tested
in a second on macOS, and it is worth keeping.

Both targets link `BookshelfCore`, which is how the app and the extension agree on
the snapshot and Live Activity types they exchange.

`BookshelfCore` is a package rather than app-target code for one practical
reason: **`swift test` runs it on macOS with no simulator and no scheme**, so the
rules that must match the web app exactly cost a second to check.

```sh
cd ios/BookshelfCore && swift test          # the important one
```

Building the app:

```sh
xcodebuild -project ios/BookshelfApp.xcodeproj -scheme BookshelfApp \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build
```

`BookshelfApp/` is a *synchronized* Xcode group, so new Swift files are picked up
by adding them to the folder — no project-file edit, no merge conflicts in
`project.pbxproj`.

## The normalizer contract

`normalize()` in `../src/app.ts` decides what a bookshelf *is*: what fields exist,
what a missing one defaults to, which junk gets stripped. Both clients read and
write the same blob through the same endpoint, so if
[`Normalizer.swift`](BookshelfCore/Sources/BookshelfCore/Normalizer.swift)
disagrees with the JavaScript by one field, a user loses data the moment they
switch devices — quietly.

So the port isn't tested against anyone's *reading* of the JavaScript. It's tested
against the JavaScript:

```sh
ios/Tools/generate-golden.sh    # runs the REAL window.__test.normalize in headless Chrome
```

That serves the repo root, loads `app.js`, runs `normalize()` over
[`Tools/normalizer-corpus.json`](Tools/normalizer-corpus.json) plus the shared
`fixtures/sample-bookshelf.json`, and records what it actually produced into
`BookshelfCore/Tests/BookshelfCoreTests/Golden/normalizer-golden.json`. The Swift
tests diff against that, field by field.

**After any change to `normalize()`: run `npm run build`, regenerate the golden,
and commit it.** A failing golden test means the port is out of date, not that
the test is wrong — read the diff and follow the JavaScript.

The harness freezes `Date` and `crypto.randomUUID` so the comparison can be
strict rather than excluding every field `normalize()` invents.

### Known deviations

Exactly one, asserted rather than assumed (see `JS.stringOr` and
`NormalizerGoldenTests.casesAllowedToCoerce`):

- `b.title || "Untitled"` assigns the raw value with no `String()` around it, so
  `{"title": 12}` normalizes to the number `12` in JavaScript and to `"12"` here.
  Only non-string input reaches it, the app never writes one, and both clients
  display the same text — so the string fields stay `String` instead of dragging
  the whole model into `JSONValue`.

Two rules that look like bugs and are not, because the web app does them:

- `readCount` of `0` becomes `1`; a `rating` of `0` becomes *absent*, but a
  `seriesNumber` of `0` is kept.
- A quote's `page: ""` becomes `0`, while a journal entry's becomes `nil` — the
  guards genuinely differ (`!= null` vs `!= null && !== ""`).

## The reading timer

Runs off an **absolute start instant mirrored to `UserDefaults`**, not a tick
count — ported from `toggleTimer`/`restoreTimer` in the web app. iOS suspends and
eventually kills a backgrounded app, so a counter held in memory silently resets;
storing when it started means reopening the book resumes the same session with
the right elapsed time. Verified by killing the app mid-session and relaunching.

Three rules, all from the web app:

- Only *this* book's session resumes. Glancing at another book gets a clean slate
  and must not discard the one that's running.
- Closing the sheet calls `pauseDisplay`, not `stop` — only an explicit Stop or
  saving the log ends a session.
- Sessions older than 12 hours are abandoned rather than resumed. Nobody read
  overnight.

**Live Activity is not built.** It needs a Widget Extension target, which belongs
with WidgetKit in M7 rather than as a one-off here.

## Where the shelf lives

`Application Support/bookshelf.json` — deliberately *not* Documents, which is
visible in the Files app now that `UIFileSharingEnabled` is on. Exports belong
somewhere a user can reach; the live database does not.

Writes are atomic and coalesced (400ms), with a flush on `scenePhase != .active`.
Every mutation goes through `BookshelfStore.commit`, which stamps `updatedAt` —
that field is what the sync endpoint's optimistic concurrency compares, so a
change that skips it is a change the server will later refuse or overwrite.

If the file can't be read, the app starts empty **and says so**, loudly. Starting
fresh in silence is how someone's only copy gets overwritten by the next save.

## Network lookup

Open Library first, Google Books last — the order from `findCoverFor()` in the
web app. Both go through a 10-second timeout rather than URLSession's 60: Open
Library routinely 504s under load and takes a full minute to do it, and nobody
watches a spinner that long.

Failures are typed (`OpenLibrary.LookupError`) so the UI can tell "nothing found"
from "the service is down" — one means *type it in yourself*, the other means
*try again shortly*. A lookup failure never blocks saving.

`LiveLookupTests` hits the real API and is off unless `BOOKSHELF_LIVE=1`; a test
that needs the network fails on a train and teaches you nothing.

## Sync

Offline-first. The shelf on disk is the source of truth; the account is a copy
that catches up. A failed sync never loses a local change.

The rule that matters:

- A **pull** resolves itself — whichever side has the newer `updatedAt` wins,
  because one of them is simply behind.
- A **409 on push** does not. Both devices edited from the same base, so neither
  copy contains the other's changes and picking silently throws away real
  reading. The user chooses; the choice goes in the conflict log.

One deliberate improvement on the web app: a pull will *not* adopt a newer server
copy while this device is dirty. Over there the prompt is a blocking `confirm()`
so the window is tiny; a SwiftUI sheet can be dismissed by the app being killed,
which would leave the next pull free to overwrite unsynced work.

The session token lives in the **Keychain** (`AfterFirstUnlockThisDeviceOnly`),
never `UserDefaults`, and the client reads it from there on every request rather
than caching it — see `SyncClient.tokenProvider` for the cold-launch race that
caused.

### Pointing at another Worker

`enkelas-sync-api` in `UserDefaults`, mirroring the web app's localStorage key:

```sh
PREFS=$(xcrun simctl get_app_container booted com.enkela.bookshelf data)/Library/Preferences
/usr/libexec/PlistBuddy -c "Add :enkelas-sync-api string http://127.0.0.1:8799" "$PREFS/com.enkela.bookshelf.plist"
```

`NSAllowsLocalNetworking` is set so `wrangler dev` over http can be reached;
remote hosts still require HTTPS.

## The ePub reader

**Own engine, no third-party library** — this reverses the plan's original
Readium recommendation. Three reasons it flipped:

1. `BookshelfCore` has no dependencies, deliberately, and Readium brings a
   sizeable transitive tree for a feature whose distinctive parts (the session
   clock, the learned reading speed, logging to the shelf) are ours regardless.
2. The pagination approach already existed and is browser-based — `reader.ts`
   uses CSS multi-column, and `WKWebView` is a browser. The port was direct.
3. The ePub subset actually needed is small and rigidly specified.

What that cost: a ~250-line ZIP reader (`ZipArchive`, inflate via Apple's
`Compression`) and an OPF/nav/NCX parser. Both EPUB 2 and EPUB 3 tables of
contents are read, because plenty of real books are still EPUB 2.

### An ePub is untrusted content

A book is a file from the internet whose chapters are arbitrary HTML. Before
anything is rendered, `ReaderDocument.sanitize` strips scripts, inline handlers,
remote `src`/`href`, and embedded frames — a remote image in a book is a tracking
pixel reporting that this person is reading this page. A CSP backs that up, and
the archive is served through a custom URL scheme that can only reach inside the
book. JavaScript stays enabled because pagination needs it, so the book's own
scripts have to be removed rather than merely refused.

### Fixtures

`ios/Tools/make-epub-fixture.sh` builds the test books with the system `zip`, not
with our own code — an archive written by the thing under test would agree with
its own bugs.

## Badges, challenges and streaks

Transcribed from `computeBadges()` / `computeChallenges()` / `streakFromDays()`
rather than reinvented. These are claims about someone's reading shown on both
clients, and a badge the phone grants that the browser doesn't reads as one of
them lying.

Two rules worth knowing because they look like bugs:

- Streak badges measure the **longest** run, not the current one. Losing today's
  streak shouldn't take away a badge that was genuinely earned.
- Reading days are bucketed in **local** time. A session logged at 11pm belongs
  to that evening; bucketing by UTC would move half of everyone's late-night
  reading onto the next day and silently break streaks west of Greenwich.

Unlike the normalizer, these aren't diffed against the JavaScript — the web app
doesn't expose them on `window.__test`. They're transcribed and unit-tested
against the same thresholds.

## Community and clubs

Public, user-generated content, so **report** and **block** are first-class, not
buried — that's App Store guideline 1.2 and the minimum for a board strangers can
post to. Both call the routes added in MW:

- Reporting names a reason from a fixed set the Worker validates. Three distinct
  reporters hide an item automatically; the UI says which of those happened.
- Blocking is one-directional and silent. The server filters per viewer, and the
  client filters again so a block feels instant rather than waiting for a refresh.

**The spoiler gate is entirely server-side.** You are only ever *sent* comments at
or below your own progress; the client never filters, it renders what arrived and
shows the count of what didn't. That is why the count is the only thing the UI can
say about comments further into the book — the text never left the server.

Live updates use a 60-second, club-scoped WebSocket ticket rather than the session
token, because a socket URL ends up in proxy and access logs. The socket carries
only a nudge saying something changed; the client answers by re-fetching *through*
the gate, so the gate is never enforced twice.

### A note on the test suites

`StubServer` registers a `URLProtocol`, which is process-wide. `.serialized` only
orders tests *within* a suite, so once a second suite started using the stub the
two overwrote each other's routes. Both are now nested under one serialized parent
(`StubbedNetwork`). If you add another networked suite, nest it there too.

## Status

**M0 through M7 complete.**

- **M0** — wire types, the normalizer, the golden pipeline, JSON import/export.
- **M1** — persistent store, tab shell, Reading / Want / Library / Owned, search,
  sort and tag filter, book detail, session logging, add-and-edit with metadata
  lookup, import/export in Settings.
- **M3** — accounts, Keychain, push/pull, 409 resolution, conflict log, change
  password, sign out, and account deletion (App Store guideline 5.1.1(v)).
- **M2** — session logging with a persisted timer, finish (with the page
  top-up), re-read, DNF, bookmark, lending, and all four note kinds.
- **M4** — goals with pacing, streaks, badges, challenges, Swift Charts for
  pages-per-day/month, genres and ratings, plain-language insights, the calendar
  heatmap, and Year in Review with a shareable card.
- **M5** — ePub import and library, ZIP + OPF/nav/NCX parsing, paginated reader
  with themes and font size, contents/bookmarks/highlights drawer, full-book
  search, highlight and save-a-quote from the selection menu,
  character-weighted progress, learned reading speed and time-left, and
  sessions logged to the linked book.
- **M6** — community board with voting, reading clubs with the spoiler gate,
  live updates, and the report/block moderation UI.
- **M7** — three widgets and a Live Activity, four App Intents with Siri
  phrases, Spotlight indexing, reminders, Handoff, haptics, and an iPad split
  view. See below.

### The share card

The web app draws its cards on a `<canvas>` — roughly 120 lines of manual text
measuring and wrapping. Here the card *is* a SwiftUI view and `ImageRenderer`
turns that same view into the image, so what gets shared is exactly what was on
screen and there is one layout rather than two.

Two things the export does differently from the on-screen card: it renders at the
device's `displayScale` (the default is 1×, which looks soft on a Retina screen —
the real output is 1200×1489), and it pins itself to the light palette. A card
rendered in dark mode and dropped into a bright chat looks broken.

## System surfaces (M7)

### The widget extension

`BookshelfWidgets` is a second target in the same project. Three things about it
are not obvious and each one cost a build to find out:

- **`NSExtension` cannot be generated.** `GENERATE_INFOPLIST_FILE` has no
  `INFOPLIST_KEY_` passthrough for it, so `BookshelfWidgets-Info.plist` exists
  purely to declare `com.apple.widgetkit-extension`. Without it the built
  `.appex` is not an extension and installing the app fails outright with
  *"Failed to create app extension placeholder"* — not at runtime, at install.
- **Both plists and both entitlements live outside their target folders.** Those
  folders are `PBXFileSystemSynchronizedRootGroup`s, so anything inside is picked
  up as a source or a resource.
- **`CFBundleURLTypes` is load-bearing.** A widget cannot open a screen, only a
  URL. Without the `bookshelf:` scheme registered, every widget tap is a dead tap.

### Why the widgets don't read the shelf

A widget extension runs in about 30 MB and is killed for exceeding it, while
`bookshelf.json` is unbounded — every book, every session, every note — and has
to be decoded *and normalized* in full before one field can be read.

So the app derives `WidgetSnapshot`: a few dozen bytes of exactly what the
widgets draw, written to the App Group on every commit (debounced) and on
backgrounding. The extension's whole job is decoding one small struct. It also
keeps the coupling honest — the widget depends on that shape, not on the wire
format.

Reloads are coalesced and compared before writing. WidgetKit's budget is measured
in reloads per day, and one edit in the app can commit three times.

### The Live Activity

This is the payoff for `ReadingTimer` storing an **absolute start instant**
rather than a tick count. The activity carries that instant and the system draws
the clock from it via `Text(timerInterval:)`, so a running session stays correct
on the Lock Screen with the app suspended, killed, or never woken again — nothing
pushes an update once a second.

`ReadingActivityAttributes` lives in `BookshelfCore` behind
`#if canImport(ActivityKit)`, because the app and the extension must agree on the
type exactly; two copies that drift by one field stop matching and the activity
silently never appears. The `#if` is what keeps `swift test` working on macOS.

`LiveActivityController`'s methods are `async` rather than fire-and-forget:
`Activity` is not `Sendable`, so handing one to a detached task is a data race
the compiler rejects.

### App Intents

Intents run in their own process — no live `BookshelfStore`, no `@Environment`.
Each one loads the shelf from disk, mutates it, and calls `saveNow()`, which is
why the store was built around a `ShelfStorage` of closures rather than a
singleton.

`LogPagesIntent` passes the page you're *on*, not a delta, so re-running it
cannot double-count. `StopReadingIntent` logs minutes and deliberately leaves the
page alone: it knows how long you read, not where you got to, and inventing a
page would corrupt the progress bar.

`StartReadingIntent` sets `openAppWhenRun`, which launches the app but gives the
intent no way to say *where* to land — hence `PendingDeepLink`, read and cleared
on the way up.

### One route in

Four systems need to open a book and none can hand over a view: a widget emits a
URL, Spotlight returns an item identifier, an intent runs in another process, and
Handoff arrives as an `NSUserActivity`. They all funnel through `DeepLink` and
`Router`, so there is one definition of what "open a book" means.

Spotlight items are **not** eligible for public indexing, and neither is the
Handoff activity. What someone reads is nobody else's business.

### Reminders

Permission is asked for when the user flips the switch, never at launch — iOS
only lets an app ask once, and a prompt with no context gets declined. Loan
reminders are rebuilt wholesale from the shelf, because a reminder for a book
already returned is the fastest way to get notifications muted.

The daily nudge names the book you're actually reading — "20 pages left of
*Intermezzo*. That's one sitting." That rules out a repeating request, whose
content is **fixed at scheduling time** and so can't name a book that changes. So
each day gets its own one-shot written for that day's shelf, `Reminders.queuedDays`
of them at a time, re-armed on every activation. Fourteen days, because iOS caps
an app at 64 pending and the loan reminders need room too. Someone who doesn't
open the app for a fortnight stops being nudged, which is the right way round.

`ReadingNudges` picks the message, ordered by which true thing is most worth
hearing. The default for a book in progress is **where you left off** — the page,
what's left, and how many sittings that is at your own average pace — because
that's what actually gets someone back in. A bookmark note outranks all of it,
since your own words about where you stopped beat any derived number:

> **You left a note in Intermezzo**
> "the bit where she finally calls him" — pick it back up?

Stronger signals still win: a book 20 pages from the end says so, and one
untouched for a month is greeted as such rather than told its page number. With
nothing on the go it suggests from the want-to-read pile, rotating by day, and
mentions how long a book has been waiting or which series it continues.

A pace claim needs at least two sessions to average — one session is not a pace,
and claiming it is would be the app guessing.

It is written around one rule: **only say things that are true.** It's tempting to write "it's just getting good", but the
app has never read the book. What it does know is real and quite enough — how far
in you are, how many pages are left, how long it has sat there, whether a streak
is on the line — so the playfulness goes in the framing, not in invented facts
about the plot. A book with no page count gets no page or percentage claims at
all, which is a tested case.

The choice is deterministic, seeded by book and day. Notifications are written up
to a fortnight ahead and re-armed on every launch, so a random pick would rewrite
tomorrow's message each time the app opened.

The toggles re-check authorization on appear: permission can be revoked in
Settings while the app is closed, and a switch left on would promise
notifications that never arrive.

### What still needs the developer portal

The App Group `group.com.enkela.bookshelf` has to be registered for the team and
enabled on both bundle IDs. It works on the simulator without that; on a device
`containerURL` returns nil, and the code degrades to placeholder widgets rather
than crashing.

## Scanning a book

Point the camera at the barcode on the back cover: Reading or Shelf → **+** →
Scan a barcode.

The interesting part isn't the camera, it's **what counts as a book**. A book's
barcode is an EAN-13 and for books the EAN-13 *is* the ISBN-13 — but a phone waved
at a shelf also reads the EAN-5 price code printed beside it, and the barcode on a
cereal box. So `ISBN.normalize` does the gatekeeping:

- validates the check digit, so a misread fails instead of adding the wrong book
- requires a Bookland prefix (`978`/`979`) — `5449000000996` is a valid EAN-13
  and it's a can of Coke
- converts ISBN-10 to ISBN-13, since older paperbacks print only the 10
- accepts `X` as a check digit, and only as a check digit

All of that is in `BookshelfCore` with tests, because **`DataScannerViewController`
does not work in the Simulator** — `isSupported` is false with no camera. The
manual-entry path is therefore not a fallback bolted on for completeness; it is
the only path testable here, and the one that works when a barcode is scuffed.

New books go through `NewBook.make`, which routes via `normalize()`. The editor
uses the same function. Building a `WireBook` by hand would produce a different
shape from one the browser created, and the difference would surface later as a
spurious sync conflict.

## The shelf, as a shelf

Shelf tab → the bookcase button. Books stand on wooden planks with their titles
running up the spine; tapping one opens it.

Spine *thickness* comes from the page count on a square-root curve — linear put
every normal novel in the same narrow band and let one doorstop eat the whole
range. Spine *height* and the occasional lean come from the same stable hash the
placeholder covers use, so a shelf looks the same on every redraw: random values
would reshuffle it continuously, which is a lava lamp rather than a bookshelf.

`ShelfLayout` lives in Core so the row packing is testable — greedy, in the
shelf's own order, because a shelf that reorders itself to pack tighter is one you
can't find anything on. The tests cover the cases that look obviously right and
are off by one gap: a book wider than the shelf still gets a row instead of
vanishing, and a zero width (the first layout pass, before geometry resolves)
returns one row rather than looping.

## Spine photographs

Book detail → **⋯** → Photograph the spine. The shelf then draws the real book
instead of a coloured rectangle.

The capture screen dims everything outside a tall, narrow guide, because the user
has to see what will be kept. **The guide and the crop come from the same
`SpineCrop.guideRect`** — computing them separately is exactly how the frame and
the resulting photo drift apart.

The subtle part is that the preview is `resizeAspectFill`, so what's on screen is
*already* a crop of the sensor frame. Cropping the captured photo to the guide's
screen coordinates would take a different region than the one framed.
`metadataOutputRectConverted` bridges the two, and its output is in unrotated
sensor space, so the axes swap for a portrait capture before it can index pixels.

`SpineCrop.pixelRect` clamps. That conversion can return values slightly outside
0…1 when the guide touches an edge, and `CGImage.cropping(to:)` returns nil for a
rect that isn't fully inside — a capture that silently does nothing.

**Photos are files on the device, not in the shelf blob.** The blob syncs and the
Worker rejects it over 8 MB; a couple of hundred photographs as base64 would blow
that ceiling and take the whole shelf offline with it. The consequence is real and
worth stating: a spine photo does not follow you to another phone.

Book ids come from imported JSON, so `SpinePhotos.filename` derives a name rather
than trusting one — an id of `../../Documents/x` would otherwise write outside the
directory. A hash is appended because two ids that sanitise to the same characters
would otherwise share a file and show each other's photograph.

The camera needs real hardware, so on the Simulator the screen opens straight onto
the photo-library path, which centre-crops to the same shape. Everything testable
— the crop maths, the storage, the path-traversal guard — is in `BookshelfCore`.

### Finding the spine on its own

`VNDetectRectanglesRequest` runs on the video feed and the guide snaps to what it
finds — corners and all, so a tilted book shows a tilted frame rather than a
rectangle promising a crop the capture won't make. The shutter turns green when a
spine is found. Nothing detected falls back to the centred guide and manual
framing, which is honest and still works.

Vision returns *every* rectangle: the front cover, the table edge, the shelf
itself. Choosing badly is worse than not detecting, because the guide then
confidently frames the wrong thing — so the choosing lives in `SpineDetection`
with tests, including that a paperback face (the biggest and most tempting
rectangle in frame) is rejected.

Three coordinate spaces meet here, and mixing them is what produced the 90° bug:

- **Vision** reports normalised with the origin **bottom-left**. Flipped once, at
  the boundary, in `SpineQuad.init(vision…)`.
- **The preview** shows a centred *crop* of the camera frame, so a detection
  against the whole frame has to go through `inPreview(imageAspect:previewSize:)`
  or it lands somewhere else on screen.
- **The photo** is the full frame, so the detection maps onto it directly — which
  is why the capture straightens the quad with `CIPerspectiveCorrection` rather
  than cropping its bounding box, keeping the background out of the corners.

Focus is continuous rather than a single pass at start-up, which locked onto
whatever was in front of the lens while the user was still raising the phone.
The range is restricted to `.near` so the camera doesn't hunt past a held book to
the wall behind, and tapping the viewfinder focuses on that spot.

### A photographed spine keeps its own proportions

Drawn width comes from the page count, which is a guess. Forcing a photo into it
crops the real spine — by a different amount for every book, so the row stops
looking like a shelf. `ShelfLayout.spine(for:photoAspect:)` takes the photo's
aspect instead, and a book too wide for the shelf is *shortened* rather than
squashed, since the aspect is the one thing a photograph should preserve.

The aspect goes into the **layout**, not just the drawing. A packer measuring one
width while the view draws another is how rows overflow.

### The shelf shows everything

Switching to shelf mode ignores the Want / Library / Owned sections and shows the
whole shelf. Those three are a way of *managing a list*, and none of them contains
`.reading` — so in shelf mode they hid the one book you're most likely to have in
your hand and to have photographed. The section picker is hidden while the shelf
is showing; search and the tag filter still apply.

## Performance: what was making it freeze

Measured on a synthetic 300-book shelf with 12,000 session logs, which is what
these numbers refer to.

**1. Every statistic re-parsed every date.** `ISO8601DateFormatter.date(from:)`
costs ~25µs, and every derivation — streaks, the calendar, badges, insights, the
widget snapshot — walks every log and parses its date string. `ISO8601.fastParse`
now handles the one shape the app and the browser actually write
(`2026-08-04T12:34:56.789Z`) with integer arithmetic and no `Calendar`, falling
back to the formatters for anything else. **~9× faster**; a streak went from
37 ms to 4 ms on a 1,200-session shelf, and it scales linearly from there.

**2. The Progress screen derived everything inside its view bodies.** Eight
separate walks of the whole shelf — `insights()` twice, `badges()` once *per
badge group* inside a `ForEach` — and a SwiftUI body re-runs on any observed
change. That was **~210 ms of main-thread work on every redraw**. It now builds a
`ProgressDigest` once per change to the shelf, off the main actor, via
`.task(id: store.state.updatedAt)`. The individual derivations were deliberately
left alone: they're the ones with golden tests proving they match the web app, so
this changed *when* they run, not what they produce.

**3. The widget snapshot was derived on the main actor after every edit** —
~100 ms per commit. Now off-main; `publishNow()` stays synchronous but is only
used for backgrounding, where a detached task would die with the process.

**4. Spotlight re-indexed the entire library on every foreground**, building a
`CSSearchableItemAttributeSet` per book on the main actor for a result that was
usually already correct. Now skipped unless `updatedAt` changed, and the build
runs off-main. `CSSearchableItem` is not `Sendable`, so the items are created
*and* submitted on the far side rather than returned.

Known and deliberately left: `BookshelfStore.init` parses and normalizes the
whole shelf synchronously, because every view assumes `state` is ready before the
first frame. It is bounded, one-time launch cost, and making it async would mean
every screen growing a loading state.

## A Swift 6 crash worth remembering

The app crashed in `_dispatch_assert_queue_fail` on
`com.apple.SwiftUI.AsyncRenderer` — "Block was expected to execute on queue".

`UIColor(dynamicProvider:)` is imported from Objective-C **without `@Sendable`**,
so in Swift 6 the closure handed to it inherits the isolation of wherever it was
written. It was written inside `@MainActor final class ThemeStore`, which made the
provider main-actor isolated — and UIKit calls a dynamic provider whenever it
resolves a colour for a trait collection, including on SwiftUI's render thread.

The fix is that `AppTheme.color` lives at file scope in `ThemeColor.swift`, where
it is nonisolated. The tell was that the widget extension never crashed: its copy
of the same code was already in a nonisolated extension.

The general rule: **a closure handed to an Objective-C API can be called on any
thread, so it must not be written inside an actor-isolated scope.**

## The theme picker

Two people share this app and want different colours, so the accent is chosen in
Settings › Appearance and stored **per signed-in account, on the device**.

Not in the shelf blob, for two reasons. `normalize()` is a rebuild whitelist — it
reconstructs the document field by field and drops anything it doesn't recognise —
so a `theme` smuggled into settings would be silently erased the first time the
web app touched the shelf. And it is the wrong thing to sync anyway: a colour is
about the phone in your hand, and pushing it would repaint the other person's
device. `ThemeStorage` keys by account id, so two people sharing one iPad each
keep their own, and signing out doesn't hand your colour to the next person. A
colour picked before making an account carries forward into it.

### `.accentColor` is not the tint

Setting `.tint()` at the root was only half the job. `Color.accentColor` is a
*static* that resolves from the asset catalog and **ignores the environment tint
entirely** — so every `.tint(.accentColor)` in the app was actively opting out of
the theme and would have stayed system blue. Those are gone; the few places that
need the colour itself (the calendar heatmap's opacity ramp, the "you" marker in a
club) read `ThemeStore` from the environment.

One exception worth knowing: **swipe-action buttons don't inherit the tint** and
render grey without an explicit one, so those keep `.tint(themes.accent)`.

### Reaching the widgets

The accent rides along in `WidgetSnapshot`, so the Home Screen matches the app —
a widget in one colour beside an app in another looks like two different apps.
Changing the theme republishes the snapshot immediately rather than waiting for
the next shelf edit.

`AppTheme` decodes an unknown name to the default instead of throwing. The app and
the widget are separate binaries that update at different moments; a strict decode
would fail the *whole* snapshot on a theme added by a newer app build and blank
every widget — losing the shelf, the streak and the goal over a colour.

Colours are RGB components rather than SwiftUI `Color`s so `BookshelfCore` stays
free of SwiftUI. Each target does its own four-line conversion, which is why that
bridge appears twice.

### The whole app wears the theme

The accent tints controls; `background` and `surface` tint the page and the cards
on it. **Barely** — the accent's hue at around a tenth strength. The text on top
is the system's label colours, tuned for the system's own greys, so pushing a
background far toward a hue takes the contrast ratio with it.

That constraint is a test, not a hope: `ThemeSurfaceTests` checks every theme in
both appearances against the real label colours and requires 7:1 for body text
and 4.5:1 for secondary — comfortably past the 4.5:1 AA floor. It also checks the
tint is actually visible (>0.4% off plain grey) and not overbearing (<12%), and
that a card is lighter than its page in dark mode, since a darker card reads as a
hole rather than a surface.

`List` and `Form` paint `systemGroupedBackground` themselves, so tinting the
container alone does nothing — `.themedBackground()` hides the scroll background
first. Plain-list rows draw over it too, hence `.listRowBackground(.clear)`.

Appearance is System / Light / Dark, stored per account like the colour. `.system`
maps to a `nil` `preferredColorScheme`, which hands the decision back to iOS —
not to light.

### The icon follows too

`Tools/make-app-icon.swift` renders one icon per theme and they ship as alternate
app icons, switched by `AppIconSwitcher` when the theme changes.

Two things worth knowing:

- **`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` must be a build-setting array,
  not a space-separated string.** As a string it is accepted silently and no
  alternates are compiled. Plum is the *primary* icon, so selecting it means
  passing `nil` to `setAlternateIconName`, not a name.
- **iOS shows "You have changed the icon for Bookshelf" and it can't be
  suppressed** with public API. `AppIconSwitcher` at least checks the current icon
  first, so re-selecting the theme you already have doesn't pop the alert for
  nothing.

The wall colour is derived in **HSB**, not by scaling RGB toward black. Scaling
loses the hue — the accents are pale, so multiplying desaturates them and Blush
and Plum came out near-identical mauve at 60 points, which defeats the whole
point. Working in HSB keeps the hue exactly and lets saturation rise to make up
for the lost brightness.

## The app's title

The Reading screen is titled after whoever is signed in — "Çelik's Bookshelf",
"Enkela's Bookshelf" when signed out — matching `renderTitle()` in the web app,
so a household sharing the app sees the same name in both.

**The home-screen icon name cannot change.** `CFBundleDisplayName` is fixed at
build time and iOS gives an app no way to rename its own icon at runtime.
(`setAlternateIconName` swaps the *image* only.)

### Reader annotations

Bookmarks and highlights are stored as **character offsets into the chapter's
stripped text**, never as pixels or DOM paths. That is the whole reason a
highlight survives a font-size change, a theme switch or a different screen:
every pixel moves, the text does not.

This only holds while two things measure the same characters. The reader renders
the chapter's `<body>`; `XMLLite.strippingTags` therefore also takes the body
only, and `ChapterTextTests` asserts the two agree for every chapter of the
fixture. Counting anything the reader doesn't show — a `<title>`, a stylesheet —
shifts every offset in the chapter and lands a jump in the wrong place.

Highlight and Save quote are contributed to the **system edit menu**
(`ReaderContentWebView.buildMenu`) rather than drawn as a bar of our own.
Selecting text in a web view already raises iOS's menu; a second bar would
overlap the passage and offer a duplicate Copy.

Still open: **M7** (widgets, App Intents, Spotlight, notifications, Handoff,
iPad) and **M8** (accessibility, privacy manifest, submission).

Milestones are in [`../IOS-PLAN.md`](../IOS-PLAN.md).
