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
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
json() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null; }

say "▸ starting wrangler dev --local on :$PORT (log: $LOG)"
( cd "$DIR" && npx wrangler dev --local --config wrangler.toml --port "$PORT" --var AUTH_SECRET:test-secret-for-endpoint-tests >"$LOG" 2>&1 ) &
WRANGLER_PID=$!
trap 'kill $WRANGLER_PID 2>/dev/null; wait $WRANGLER_PID 2>/dev/null' EXIT

# Wait (up to 60s) for the worker to answer.
for i in $(seq 1 120); do
  if curl -sf "$BASE/" >/dev/null 2>&1; then break; fi
  if ! kill -0 $WRANGLER_PID 2>/dev/null; then say "wrangler dev died — log tail:"; tail -20 "$LOG"; exit 1; fi
  sleep 0.5
done
if ! curl -sf "$BASE/" >/dev/null 2>&1; then say "worker never came up — log tail:"; tail -20 "$LOG"; exit 1; fi

STAMP=$(date +%s)
U1="alice-$STAMP@test.local"; U2="bob-$STAMP@test.local"

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
else
  say ""
  say "▸ clubs/recs skipped (no local CLUBS_DB — run 'npx wrangler d1 execute enkelas-clubs --local --file schema-clubs.sql' first)"
fi

say ""
if [ $FAIL -eq 0 ]; then say "✅ $PASS passed"; else say "❌ $FAIL failed · $PASS passed"; fi
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
