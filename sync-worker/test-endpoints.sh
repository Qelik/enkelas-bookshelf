#!/usr/bin/env bash
# Endpoint tests for the sync worker — runs against a LOCAL `wrangler dev`
# (local KV/D1/DO simulations; nothing touches production).
#
#   cd sync-worker && ./test-endpoints.sh
#
# Needs: node/npx (wrangler is a devDependency), curl. Uses python3 for JSON
# field extraction so there's no jq dependency.
set -u
PORT="${PORT:-8799}"
BASE="http://127.0.0.1:$PORT"
DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
LOG="$(mktemp)"

say()  { printf '%s\n' "$*"; }
pass() { PASS=$((PASS+1)); say "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); say "  ✗ $1"; }
# check <name> <expected> <actual>
# NOTE: always capture curl into a variable first (R=$(curl ...)) and pass "$R".
# Inlining "$(curl ... -d "{\"k\":\"$v\"}")" as an argument mangles the escaped
# quotes: the JSON body is truncated and the -H value splits into two arguments,
# so curl quietly requests the wrong thing and the status code you assert on is
# meaningless. That produced four "failures" that looked like worker bugs.
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
json() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }

say "▸ starting wrangler dev --local on :$PORT (log: $LOG)"
# Wipe the local KV state first. `wrangler dev --local` persists KV to
# .wrangler/state/v3/kv BETWEEN runs, and locally there is no CF-Connecting-IP,
# so every curl below shares one rate-limit bucket keyed "unknown". Left alone,
# the per-IP login and register caps accumulate across runs until the suite
# starts failing with 429s that look like real bugs. Only the kv directory goes:
# d1/ holds the seeded clubs schema, which is expensive to recreate.
rm -rf "$DIR/.wrangler/state/v3/kv"

# AUTH_SECRET must clear the worker's 32-character floor or it refuses to serve.
# RESET_DEBUG returns the reset link in the response so the flow is testable with
# no mailer — local dev only, and the preflight check asserts it is never
# committed to either wrangler config.
# Refuse to start on an occupied port rather than silently testing whatever is
# already listening there — a leftover worker running OLD code produces failures
# that look like real regressions and survive every rebuild.
if curl -sf "$BASE/" >/dev/null 2>&1; then
  say "✗ something is already listening on :$PORT — stop it first (pkill -f 'wrangler dev'), or run with PORT=<free port>"
  exit 1
fi

# `set -m` puts the background job in its own process group, so the trap can kill
# wrangler AND its children with `kill -- -PID`. Killing only the subshell PID (as
# this did before) left npx/wrangler/workerd alive holding the port and the state
# directory, and the NEXT run then silently talked to that stale worker.
set -m
# APP_URL has no default in the worker — a guessed base URL would mail out links
# that 404 — so the reset tests have to supply one.
( cd "$DIR" && exec npx wrangler dev --local --config wrangler.toml --port "$PORT" \
    --var AUTH_SECRET:test-secret-for-endpoint-tests-at-least-32-chars \
    --var APP_URL:"$BASE" --var RESET_DEBUG:1 >"$LOG" 2>&1 ) &
WRANGLER_PID=$!
set +m
trap 'kill -- -$WRANGLER_PID 2>/dev/null; kill $WRANGLER_PID 2>/dev/null; wait $WRANGLER_PID 2>/dev/null' EXIT

# Wait (up to 60s) for the worker to answer.
for i in $(seq 1 120); do
  if curl -sf "$BASE/" >/dev/null 2>&1; then break; fi
  if ! kill -0 $WRANGLER_PID 2>/dev/null; then say "wrangler dev died — log tail:"; tail -20 "$LOG"; exit 1; fi
  sleep 0.5
done
if ! curl -sf "$BASE/" >/dev/null 2>&1; then say "worker never came up — log tail:"; tail -20 "$LOG"; exit 1; fi

STAMP=$(date +%s)
U1="alice-$STAMP@test.local"; U2="bob-$STAMP@test.local"; U3="carol-$STAMP@test.local"

say ""
say "Health"
HEALTH=$(curl -s "$BASE/")
check "GET / says ok" "True" "$(printf '%s' "$HEALTH" | json "['ok']")"
CLUBS_ON=$(printf '%s' "$HEALTH" | json "['clubs']")
say "  · clubs binding available locally: $CLUBS_ON"

say ""
say "Auth"
R=$(curl -s -X POST "$BASE/api/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$U1\",\"fullName\":\"Alice Test\",\"password\":\"correct-horse-1\"}")
T1=$(printf '%s' "$R" | json "['token']")
[ -n "$T1" ] && pass "register returns a token" || fail "register returns a token ($R)"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$U1\",\"fullName\":\"Alice Again\",\"password\":\"whatever-123\"}")
check "duplicate email is rejected" "409" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U1\",\"password\":\"wrong-password\"}")
check "wrong password → 401" "401" "$R"
R=$(curl -s -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U1\",\"password\":\"correct-horse-1\"}")
T1=$(printf '%s' "$R" | json "['token']")
[ -n "$T1" ] && pass "login returns a token" || fail "login returns a token ($R)"
R=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/data")
check "data without a token → 401" "401" "$R"
# A corrupt token must read as "not signed in", never a server error: the client
# only re-prompts for login on a 401, so a 500 stranded it in "sync paused".
for BAD in 'not-a-token' 'aaa.@@@@' '@@@.bbb' 'x.y.z'; do
  R=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/data" -H "authorization: Bearer $BAD")
  check "malformed token \"$BAD\" → 401 (not 500)" "401" "$R"
done
# Unknown email and wrong password must be indistinguishable (no account probing).
M1=$(curl -s -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U1\",\"password\":\"definitely-wrong\"}" | json "['error']")
M2=$(curl -s -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d '{"email":"nobody-here-at-all@test.local","password":"definitely-wrong"}' | json "['error']")
check "login doesn't reveal whether an email exists" "$M1" "$M2"
# Security headers are attached once, in fetch(), so no handler can omit them.
HDRS=$(curl -s -D - -o /dev/null "$BASE/" | tr 'A-Z' 'a-z')
printf '%s' "$HDRS" | grep -q 'x-content-type-options: nosniff' && pass "responses set X-Content-Type-Options" || fail "responses set X-Content-Type-Options"
printf '%s' "$HDRS" | grep -q 'cache-control: no-store' && pass "responses set Cache-Control: no-store" || fail "responses set Cache-Control: no-store"

say ""
say "Password policy (new passwords only — old accounts are never re-checked)"
# check_reg <name> <password> — every case must be refused with a 400.
reg_code() { curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/register" -H 'content-type: application/json' \
  -d "{\"email\":\"pol-$1-$STAMP@test.local\",\"fullName\":\"Poll Tester\",\"password\":\"$2\"}"; }
check "under 10 characters is rejected" "400" "$(reg_code short 'short123')"
check "a top-list password is rejected" "400" "$(reg_code common 'password123')"
check "too few distinct characters is rejected" "400" "$(reg_code narrow 'ababababab')"
check "a password containing your name is rejected" "400" "$(reg_code name 'PollTester99')"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/register" -H 'content-type: application/json' \
  -d "{\"email\":\"pol-mail-$STAMP@test.local\",\"fullName\":\"Mail Tester\",\"password\":\"pol-mail-$STAMP-x\"}")
check "a password containing your email is rejected" "400" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/register" -H 'content-type: application/json' \
  -d '{"email":"not-an-email","fullName":"X Y","password":"decent-passphrase-9"}')
check "a bad email address is rejected" "400" "$R"
# The reset link's base URL is required, not guessed: a wrong one mails a 404 to
# someone already locked out. /api must therefore report reset as unavailable
# until all three of RESEND_API_KEY, RESET_FROM and APP_URL are present.
check "reset advertises itself as unconfigured without a mailer" "False" "$(printf '%s' "$HEALTH" | json "['passwordReset']")"

say ""
say "Change password (and session revocation)"
R=$(curl -s -X POST "$BASE/api/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$U3\",\"fullName\":\"Carol Test\",\"password\":\"first-passphrase-9\"}")
T3=$(printf '%s' "$R" | json "['token']")
[ -n "$T3" ] && pass "register a third account" || fail "register a third account ($R)"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/password/change" -H "authorization: Bearer $T3" -H 'content-type: application/json' \
  -d '{"currentPassword":"wrong-passphrase-9","newPassword":"second-passphrase-9"}')
check "wrong current password → 401" "401" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/password/change" -H "authorization: Bearer $T3" -H 'content-type: application/json' \
  -d '{"currentPassword":"first-passphrase-9","newPassword":"password123"}')
check "a weak new password → 400" "400" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/password/change" -H 'content-type: application/json' \
  -d '{"currentPassword":"first-passphrase-9","newPassword":"second-passphrase-9"}')
check "changing without a token → 401" "401" "$R"
R=$(curl -s -X POST "$BASE/api/password/change" -H "authorization: Bearer $T3" -H 'content-type: application/json' \
  -d '{"currentPassword":"first-passphrase-9","newPassword":"second-passphrase-9"}')
T3B=$(printf '%s' "$R" | json "['token']")
[ -n "$T3B" ] && pass "change succeeds and hands back a fresh token" || fail "change succeeds and hands back a fresh token ($R)"
# THE point of the change: the token the old password minted must stop working,
# or "change my password because I lost my laptop" doesn't actually do anything.
R=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/data" -H "authorization: Bearer $T3")
check "the pre-change token is revoked" "401" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/data" -H "authorization: Bearer $T3B")
check "…but the replacement token still works" "200" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U3\",\"password\":\"first-passphrase-9\"}")
check "the old password no longer logs in" "401" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U3\",\"password\":\"second-passphrase-9\"}")
check "the new password does" "200" "$R"

# The email in the change-password body is a HINT, used only for accounts created
# before the uid→email index existed (they get one on their next login). It must
# never redirect the write: the signed token decides whose password changes. Point
# it at someone else's address and their account has to come out untouched.
R=$(curl -s -X POST "$BASE/api/password/change" -H "authorization: Bearer $T3B" -H 'content-type: application/json' \
  -d "{\"currentPassword\":\"second-passphrase-9\",\"newPassword\":\"hijack-passphrase-9\",\"email\":\"$U1\"}")
T3B=$(printf '%s' "$R" | json "['token']")
[ -n "$T3B" ] && pass "a change with someone else's email hint still succeeds for the token owner" \
  || fail "a change with someone else's email hint still succeeds for the token owner ($R)"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U1\",\"password\":\"hijack-passphrase-9\"}")
check "…and the hinted account's password is untouched" "401" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U3\",\"password\":\"hijack-passphrase-9\"}")
check "…while the token owner's password did change" "200" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -H 'content-type: application/json' \
  -d "{\"email\":\"$U1\",\"password\":\"correct-horse-1\"}")
check "…and the hinted account still logs in normally" "200" "$R"

say ""
say "Forgot / reset password"
# The response must be byte-identical for a real account and a made-up one, or
# "forgot password" becomes a free lookup for who has an account here.
F1=$(curl -s -X POST "$BASE/api/password/forgot" -H 'content-type: application/json' -d "{\"email\":\"$U2\"}" | json "['message']")
F2=$(curl -s -X POST "$BASE/api/password/forgot" -H 'content-type: application/json' -d '{"email":"nobody-at-all@test.local"}' | json "['message']")
check "forgot-password doesn't reveal whether an email exists" "$F1" "$F2"
# …and not by the clock either. Mailing is handed to waitUntil so a registered
# address doesn't pay for the outbound HTTP call while an unknown one doesn't.
# Generous bound: this only has to catch "one path awaits a network round trip".
TA=$(curl -s -o /dev/null -w '%{time_total}' -X POST "$BASE/api/password/forgot" -H 'content-type: application/json' -d "{\"email\":\"$U2\"}")
TB=$(curl -s -o /dev/null -w '%{time_total}' -X POST "$BASE/api/password/forgot" -H 'content-type: application/json' -d '{"email":"nobody-at-all@test.local"}')
CLOSE=$(python3 -c "print('yes' if abs($TA-$TB) < 0.5 else 'no ($TA vs $TB)')")
check "…nor by how long it takes to answer" "yes" "$CLOSE"
R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/password/reset" -H 'content-type: application/json' \
  -d '{"token":"totally-made-up-token","newPassword":"third-passphrase-9"}')
check "a junk reset token → 400" "400" "$R"
# RESET_DEBUG hands the link back when no mailer is configured, so the rest of
# the flow is testable locally. Never set in production.
LINK=$(curl -s -X POST "$BASE/api/password/forgot" -H 'content-type: application/json' -d "{\"email\":\"$U3\"}" | json "['devResetLink']")
RTOK="${LINK##*#reset/}"
if [ -n "$RTOK" ] && [ "$RTOK" != "$LINK" ]; then
  pass "a reset link is minted for a real account"
  R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/password/reset" -H 'content-type: application/json' \
    -d "{\"token\":\"$RTOK\",\"newPassword\":\"password123\"}")
  check "a weak new password → 400 (and the link survives)" "400" "$R"
  R=$(curl -s -X POST "$BASE/api/password/reset" -H 'content-type: application/json' \
    -d "{\"token\":\"$RTOK\",\"newPassword\":\"third-passphrase-9\"}")
  T3C=$(printf '%s' "$R" | json "['token']")
  [ -n "$T3C" ] && pass "redeeming the link sets the password and signs you in" || fail "redeeming the link sets the password and signs you in ($R)"
  R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/password/reset" -H 'content-type: application/json' \
    -d "{\"token\":\"$RTOK\",\"newPassword\":\"fourth-passphrase-9\"}")
  check "the link is single-use" "400" "$R"
  # A reset is the "someone else knows my password" escape hatch — it has to
  # evict their sessions too, not just change what the login form accepts.
  check "the pre-reset token is revoked" "401" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/data" -H "authorization: Bearer $T3B")"
  check "the post-reset token works" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/data" -H "authorization: Bearer $T3C")"
  R=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/login" -H 'content-type: application/json' \
    -d "{\"email\":\"$U3\",\"password\":\"third-passphrase-9\"}")
  check "the reset password logs in" "200" "$R"
else
  fail "a reset link is minted for a real account (no devResetLink — is RESET_DEBUG:1 set?)"
fi

say ""
say "Data sync (optimistic concurrency)"
R=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/data" -H "authorization: Bearer $T1" -H 'content-type: application/json' \
  -d '{"blob":{"version":1,"books":[{"id":"b1","title":"First"}],"updatedAt":"2026-01-01T00:00:00Z"},"updatedAt":"2026-01-01T00:00:00Z","force":true}')
check "PUT data (force) succeeds" "200" "$R"
R=$(curl -s "$BASE/api/data" -H "authorization: Bearer $T1")
check "GET data returns the saved blob" "First" "$(printf '%s' "$R" | json "['blob']['books'][0]['title']")"
SRV_AT=$(printf '%s' "$R" | json "['updatedAt']")
R=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/data" -H "authorization: Bearer $T1" -H 'content-type: application/json' \
  -d '{"blob":{"version":1,"books":[]},"updatedAt":"2026-01-02T00:00:00Z","baseUpdatedAt":"1999-01-01T00:00:00Z"}')
check "stale baseUpdatedAt → 409" "409" "$R"
R=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/data" -H "authorization: Bearer $T1" -H 'content-type: application/json' \
  -d "{\"blob\":{\"version\":1,\"books\":[{\"id\":\"b2\",\"title\":\"Second\"}]},\"updatedAt\":\"2026-01-03T00:00:00Z\",\"baseUpdatedAt\":\"$SRV_AT\"}")
check "matching baseUpdatedAt succeeds" "200" "$R"
# Oversized blobs used to throw inside KV.put and surface as an opaque 500.
BIG=$(python3 -c "print('{\"blob\":{\"pad\":\"' + 'x'*9000000 + '\"},\"updatedAt\":\"2026-01-04T00:00:00Z\",\"force\":true}')")
R=$(printf '%s' "$BIG" | curl -s -o /dev/null -w '%{http_code}' -X PUT "$BASE/api/data" -H "authorization: Bearer $T1" -H 'content-type: application/json' --data-binary @-)
check "oversized blob → 413 with a reason (not 500)" "413" "$R"

say ""
say "Per-account isolation"
R=$(curl -s -X POST "$BASE/api/register" -H 'content-type: application/json' \
  -d "{\"email\":\"$U2\",\"fullName\":\"Bob Test\",\"password\":\"correct-horse-2\"}")
T2=$(printf '%s' "$R" | json "['token']")
R=$(curl -s "$BASE/api/data" -H "authorization: Bearer $T2")
BOB_BLOB=$(printf '%s' "$R" | json "['blob']")
check "new user sees no one else's data" "None" "$BOB_BLOB"

if [ "$CLUBS_ON" = "True" ]; then
  say ""
  say "Reading clubs (spoiler gate)"
  R=$(curl -s -X POST "$BASE/api/clubs" -H "authorization: Bearer $T1" -H 'content-type: application/json' \
    -d '{"bookTitle":"Test Book","bookAuthor":"Tester","displayName":"Alice"}')
  CLUB=$(printf '%s' "$R" | json "['clubId']"); CODE=$(printf '%s' "$R" | json "['joinCode']")
  [ -n "$CLUB" ] && pass "create club" || fail "create club ($R)"
  R=$(curl -s -X POST "$BASE/api/clubs/join" -H "authorization: Bearer $T2" -H 'content-type: application/json' \
    -d "{\"joinCode\":\"$CODE\",\"displayName\":\"Bob\"}")
  check "join by code" "$CLUB" "$(printf '%s' "$R" | json "['clubId']")"
  curl -s -X PUT "$BASE/api/clubs/$CLUB/progress" -H "authorization: Bearer $T1" -H 'content-type: application/json' -d '{"progressPct":60}' >/dev/null
  curl -s -X POST "$BASE/api/clubs/$CLUB/comments" -H "authorization: Bearer $T1" -H 'content-type: application/json' \
    -d '{"body":"the twist at 60%!","posPct":60}' >/dev/null
  R=$(curl -s "$BASE/api/clubs/$CLUB/comments" -H "authorization: Bearer $T2")
  check "reader at 0% sees no spoilers" "0" "$(printf '%s' "$R" | json "['comments'].__len__()")"
  check "…but knows one is locked ahead" "1" "$(printf '%s' "$R" | json "['lockedAhead']")"
  curl -s -X PUT "$BASE/api/clubs/$CLUB/progress" -H "authorization: Bearer $T2" -H 'content-type: application/json' -d '{"progressPct":70}' >/dev/null
  R=$(curl -s "$BASE/api/clubs/$CLUB/comments" -H "authorization: Bearer $T2")
  check "past the spoiler point it unlocks" "1" "$(printf '%s' "$R" | json "['comments'].__len__()")"
  curl -s -X PUT "$BASE/api/clubs/$CLUB/progress" -H "authorization: Bearer $T2" -H 'content-type: application/json' -d '{"progressPct":10}' >/dev/null
  R=$(curl -s "$BASE/api/clubs/$CLUB" -H "authorization: Bearer $T2")
  check "progress is forward-only" "70" "$(printf '%s' "$R" | json "['me']['progress_pct']")"
  R=$(curl -s "$BASE/api/clubs" -H "authorization: Bearer $T2")
  check "clubs list carries members" "2" "$(printf '%s' "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);c=[x for x in d['clubs'] if x['id']=='$CLUB'][0];print(len(c['members']))" 2>/dev/null)"

  # Realtime credentials. A WebSocket URL can't carry an Authorization header, so
  # whatever it does carry ends up in proxy and access logs — which is why it's a
  # 60-second club-scoped ticket rather than the 30-day session token.
  TICKET=$(curl -s -X POST "$BASE/api/clubs/$CLUB/ws-ticket" -H "authorization: Bearer $T1" | json "['ticket']")
  [ -n "$TICKET" ] && pass "a member can mint a WebSocket ticket" || fail "a member can mint a WebSocket ticket"
  # The ticket must be useless against the REST API, or handing it over in a URL
  # would be no better than handing over the session token.
  check "a ws ticket can't read /api/data" "401" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/data" -H "authorization: Bearer $TICKET")"
  check "a ws ticket can't list clubs" "401" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/clubs" -H "authorization: Bearer $TICKET")"
  # …and the session token must be useless on the socket, so nobody is tempted
  # to go back to putting it in the URL.
  WSC=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/clubs/$CLUB/ws?ticket=$T1" \
    -H 'connection: Upgrade' -H 'upgrade: websocket' -H 'sec-websocket-version: 13' -H 'sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==')
  check "a session token is refused on the socket" "401" "$WSC"
  # Non-members can't get a ticket for a club they aren't in.
  check "a non-member can't mint a ticket" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/clubs/$CLUB/ws-ticket" -H "authorization: Bearer $T3C")"
  # Leaving a club must not delete your words from everyone else's feed: the
  # comments query inner-joined members, so a departure erased the discussion.
  # Bob comments below Alice's progress, then leaves; Alice must still see it.
  curl -s -X POST "$BASE/api/clubs/$CLUB/comments" -H "authorization: Bearer $T2" -H 'content-type: application/json' \
    -d '{"body":"loving it so far","posPct":20}' >/dev/null
  R=$(curl -s "$BASE/api/clubs/$CLUB/comments" -H "authorization: Bearer $T1")
  check "Alice sees Bob's comment before he leaves" "2" "$(printf '%s' "$R" | json "['comments'].__len__()")"
  curl -s -X POST "$BASE/api/clubs/$CLUB/leave" -H "authorization: Bearer $T2" >/dev/null
  R=$(curl -s "$BASE/api/clubs/$CLUB/comments" -H "authorization: Bearer $T1")
  check "…and still sees it after he leaves" "2" "$(printf '%s' "$R" | json "['comments'].__len__()")"
  check "…attributed to a former member, not blank" "Former member" \
    "$(printf '%s' "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);print([c['display_name'] for c in d['comments'] if c['body']=='loving it so far'][0])" 2>/dev/null)"

  say ""
  say "Community recommendations"
  R=$(curl -s -X POST "$BASE/api/recs" -H "authorization: Bearer $T1" -H 'content-type: application/json' \
    -d '{"bookTitle":"Rec Book","bookAuthor":"Someone","category":"Fantasy","displayName":"Alice"}')
  REC=$(printf '%s' "$R" | json "['id']")
  [ -n "$REC" ] && pass "recommend a book" || fail "recommend a book ($R)"
  R=$(curl -s "$BASE/api/recs")
  # the local board may hold leftovers from dev sessions — assert on OUR rec
  MINE=$(printf '%s' "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);r=[x for x in d['recs'] if x['id']=='$REC'][0];print(r['book_title'],r['up'])" 2>/dev/null)
  check "board is publicly readable" "Rec Book 1" "$MINE"
  R=$(curl -s -X POST "$BASE/api/recs/$REC/vote" -H "authorization: Bearer $T2" -H 'content-type: application/json' -d '{"vote":-1}')
  check "another user can downvote" "-1" "$(printf '%s' "$R" | json "['myVote']")"
  R=$(curl -s -X POST "$BASE/api/recs/$REC/vote" -H "authorization: Bearer $T2" -H 'content-type: application/json' -d '{"vote":-1}')
  check "same vote again toggles off" "0" "$(printf '%s' "$R" | json "['myVote']")"
  # Re-recommending the same book to the same shelf returns the original rather
  # than duplicating it on the shared public board.
  R=$(curl -s -X POST "$BASE/api/recs" -H "authorization: Bearer $T1" -H 'content-type: application/json' \
    -d '{"bookTitle":"Rec Book","bookAuthor":"Someone","category":"Fantasy","displayName":"Alice"}')
  check "re-recommending returns the original id" "$REC" "$(printf '%s' "$R" | json "['id']")"
  check "…and says so" "True" "$(printf '%s' "$R" | json "['duplicate']")"
else
  say ""
  say "▸ clubs/recs skipped (no local CLUBS_DB — seed it with:"
  say "    npx wrangler d1 execute enkelas-clubs --local --config wrangler.toml --file schema-clubs.sql"
  say "  --config is required: without it wrangler seeds the ROOT .wrangler state, not this one.)"
fi

say ""
if [ $FAIL -eq 0 ]; then say "✅ $PASS passed"; else say "❌ $FAIL failed · $PASS passed"; fi
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
