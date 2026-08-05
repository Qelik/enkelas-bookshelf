#!/usr/bin/env bash
# Regenerate the normalizer golden file from the REAL JavaScript.
#
#   ios/Tools/generate-golden.sh
#
# Serves the repo root, loads ios/Tools/golden-harness.html in headless Chrome
# (which imports app.js and calls window.__test.normalize), and writes the result
# to ios/BookshelfCore/Tests/BookshelfCoreTests/Golden/normalizer-golden.json.
#
# Run this after ANY change to normalize() in src/app.ts, and commit the result.
# The Swift tests diff against it, so a drifting web app fails the iOS build —
# which is the entire point: the two clients share one blob format, and a silent
# divergence loses somebody's books the next time they switch devices.
#
# Same approach as scripts/run-tests.sh: no dependencies beyond python3 and an
# installed Chrome. The committed root JS is already-built compiler output, so
# run `npm run build` first if you have edited src/*.ts.
set -u
DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$DIR/ios/BookshelfCore/Tests/BookshelfCoreTests/Golden/normalizer-golden.json"
PORT="${PORT:-8153}"

CHROME=""
for c in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  google-chrome chromium chromium-browser msedge; do
  if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then CHROME="$c"; break; fi
done
if [ -z "$CHROME" ]; then
  echo "⚠ No Chrome/Chromium found — the golden file can only be regenerated with one."
  echo "  Serve the repo root and open http://localhost:$PORT/ios/Tools/golden-harness.html by hand,"
  echo "  then save the <pre> contents to $OUT"
  exit 2
fi

if curl -sf "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
  echo "✗ something is already listening on :$PORT — stop it, or run with PORT=<free port>"
  exit 1
fi

( cd "$DIR" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null' EXIT
sleep 0.7

DOM=$("$CHROME" --headless=new --disable-gpu --no-first-run --virtual-time-budget=15000 \
  --dump-dom "http://127.0.0.1:$PORT/ios/Tools/golden-harness.html" 2>/dev/null)

mkdir -p "$(dirname "$OUT")"
# The DOM goes via a file, NOT a pipe: `python3 - <<'PY'` already takes the
# program itself from stdin, so anything piped in is discarded (and the writer
# gets EPIPE). Read the dump from a path instead.
DOMFILE="$(mktemp)"
trap 'kill $SERVER_PID 2>/dev/null; wait $SERVER_PID 2>/dev/null; rm -f "$DOMFILE"' EXIT
printf '%s' "$DOM" > "$DOMFILE"

# Pull the <pre> out of the dumped DOM and unescape it. Chrome HTML-escapes the
# JSON on the way out, so `&quot;` has to come back before it will parse.
DOMFILE="$DOMFILE" OUT="$OUT" python3 - <<'PY'
import html, json, os, re, sys
dom = open(os.environ["DOMFILE"], encoding="utf-8").read()
m = re.search(r'<pre id="out">(.*?)</pre>', dom, re.S)
if not m:
    sys.exit("❌ harness produced no <pre id=\"out\"> — check it in a real browser")
text = html.unescape(m.group(1))
if text.startswith("ERROR:") or text.strip() == "running…":
    sys.exit("❌ harness failed:\n" + text[:2000])
try:
    data = json.loads(text)
except json.JSONDecodeError as e:
    sys.exit("❌ harness output is not JSON (%s):\n%s" % (e, text[:2000]))
out = os.environ["OUT"]
with open(out, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("✅ wrote %d cases to %s" % (len(data["cases"]), os.path.relpath(out)))
PY
