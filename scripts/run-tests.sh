#!/usr/bin/env bash
# Run the browser test harness (tests.html) headlessly and report pass/fail.
#
#   ./scripts/run-tests.sh
#
# No dependencies beyond python3 + an installed Chrome/Chromium/Edge. The app
# has no build step, so the "test runner" is simply: serve the folder, load
# tests.html in headless Chrome, read the summary line out of the DOM.
set -u
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-8151}"

# Find a Chrome-family binary.
CHROME=""
for c in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  google-chrome chromium chromium-browser msedge; do
  if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then CHROME="$c"; break; fi
done
if [ -z "$CHROME" ]; then
  echo "⚠ No Chrome/Chromium found — open tests.html in a browser instead:"
  echo "  cd \"$DIR\" && python3 -m http.server $PORT   →  http://localhost:$PORT/tests.html"
  exit 2
fi

( cd "$DIR" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null' EXIT
sleep 0.7

DOM=$("$CHROME" --headless=new --disable-gpu --no-first-run --virtual-time-budget=5000 \
  --dump-dom "http://127.0.0.1:$PORT/tests.html" 2>/dev/null)

SUMMARY=$(printf '%s' "$DOM" | grep -o '[0-9]* passed, [0-9]* failed' | head -1)
if [ -z "$SUMMARY" ]; then
  echo "❌ tests.html produced no summary — the harness may have crashed. Check it in a real browser."
  exit 1
fi
echo "tests.html → $SUMMARY"
# List any failures with their messages.
printf '%s' "$DOM" | python3 - <<'PY'
import re, sys
dom = sys.stdin.read()
for m in re.finditer(r'<div class="t fail"><span class="mark">FAIL</span><span>(.*?)</span><span class="msg">(.*?)</span>', dom):
    print("  ✗ %s — %s" % (m.group(1), m.group(2)))
PY
case "$SUMMARY" in *" 0 failed") echo "✅ all browser tests pass"; exit 0;; *) echo "❌ failures above"; exit 1;; esac
