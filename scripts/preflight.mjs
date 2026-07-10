#!/usr/bin/env node
/* Pre-release checklist for Enkela's Bookshelf.
 *
 *   node scripts/preflight.mjs
 *
 * Static checks that catch the classic "shipped it broken" mistakes:
 *  - shell files changed but sw.js CACHE version wasn't bumped
 *  - app.js changed but APP_VERSION wasn't bumped
 *  - sw.js precache list pointing at files that don't exist
 *  - JS syntax errors in app.js / reader.js / sw.js
 *  - root wrangler.jsonc drifting from sync-worker/wrangler.toml
 *    (Workers Builds deploys from the ROOT config on every push!)
 * Exits non-zero when something needs fixing. Browser data-logic tests still
 * live in tests.html — open it on the served app for the full picture.
 */
import { readFileSync, existsSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const sh = (cmd) => execSync(cmd, { cwd: root, encoding: "utf8" }).trim();

let failures = 0, warnings = 0;
const ok = (msg) => console.log("  ✓ " + msg);
const fail = (msg) => { failures++; console.error("  ✗ " + msg); };
const warn = (msg) => { warnings++; console.warn("  ⚠ " + msg); };

const SHELL_FILES = ["index.html", "styles.css", "app.js", "reader.js", "manifest.json"];

// --- Which files changed since the last commit? -----------------------------
let changed = [];
try {
  changed = sh("git status --porcelain")
    .split("\n").filter(Boolean)
    .map((l) => l.slice(3).replace(/^"|"$/g, ""));
} catch (e) {
  warn("not a git checkout — skipping change-aware checks");
}
const shellChanged = changed.filter((f) => SHELL_FILES.includes(f) || f === "sw.js");

// --- Version strings ---------------------------------------------------------
console.log("\nVersions");
const appVersion = (read("app.js").match(/APP_VERSION\s*=\s*"([^"]+)"/) || [])[1];
const swCache = (read("sw.js").match(/CACHE\s*=\s*"([^"]+)"/) || [])[1];
if (appVersion) ok(`APP_VERSION = ${appVersion}`); else fail("couldn't find APP_VERSION in app.js");
if (swCache) ok(`sw.js CACHE = ${swCache}`); else fail("couldn't find CACHE in sw.js");

if (shellChanged.length && changed.length) {
  let headSw = "", headApp = "";
  try { headSw = (sh("git show HEAD:sw.js").match(/CACHE\s*=\s*"([^"]+)"/) || [])[1] || ""; } catch (e) { /* new file */ }
  try { headApp = (sh("git show HEAD:app.js").match(/APP_VERSION\s*=\s*"([^"]+)"/) || [])[1] || ""; } catch (e) { /* new file */ }
  if (headSw && headSw === swCache) fail(`shell files changed (${shellChanged.join(", ")}) but sw.js CACHE is still "${swCache}" — installed apps will keep the old files. Bump it.`);
  else ok("sw.js CACHE differs from HEAD (or no comparison needed)");
  if (changed.includes("app.js") && headApp && headApp === appVersion) warn(`app.js changed but APP_VERSION is still "${appVersion}" — consider bumping (shown in Settings → App).`);
}

// --- Service worker precache list ---------------------------------------------
console.log("\nService worker precache");
const shellList = [...read("sw.js").matchAll(/"\.\/([^"]*)"/g)].map((m) => m[1]).filter(Boolean);
let missing = 0;
for (const f of shellList) if (!existsSync(join(root, f))) { fail(`sw.js precaches "./${f}" but it doesn't exist — install will fail entirely`); missing++; }
if (!missing) ok(`all ${shellList.length} precached files exist`);
for (const f of ["reader.js", "vendor/jszip.min.js"]) if (!shellList.includes(f)) warn(`"${f}" is not in the sw.js precache list`);

// --- Syntax ---------------------------------------------------------------------
console.log("\nSyntax");
for (const f of ["app.js", "reader.js", "sw.js"]) {
  try { sh(`node --check "${f}"`); ok(`${f} parses`); }
  catch (e) { fail(`${f} has a syntax error:\n${e.stderr || e.message}`); }
}

// --- Worker config drift ---------------------------------------------------------
// Workers Builds runs `npx wrangler deploy` from the repo ROOT on every push,
// so root wrangler.jsonc MUST mirror sync-worker/wrangler.toml.
console.log("\nWorker config (root wrangler.jsonc vs sync-worker/wrangler.toml)");
if (existsSync(join(root, "wrangler.jsonc")) && existsSync(join(root, "sync-worker/wrangler.toml"))) {
  const jsonc = read("wrangler.jsonc");
  const toml = read("sync-worker/wrangler.toml");
  const pick = (src, re) => [...src.matchAll(re)].map((m) => m[1]);
  const pairs = [
    ["KV namespace id", /"?id"?\s*[:=]\s*"([0-9a-f]{32})"/g],
    ["D1 database id", /"?database_id"?\s*[:=]\s*"([0-9a-f-]{36})"/g],
    ["DO class names", /"?class_name"?\s*[:=]\s*"(\w+)"/g],
  ];
  for (const [label, re] of pairs) {
    const a = new Set(pick(jsonc, re)), b = new Set(pick(toml, re));
    const same = a.size === b.size && [...a].every((x) => b.has(x));
    if (same) ok(`${label} match (${[...a].join(", ") || "none"})`);
    else fail(`${label} DIFFER — root: [${[...a]}] vs sync-worker: [${[...b]}]. Fix before pushing or the auto-deployed worker breaks.`);
  }
  const mainOk = /"main"\s*:\s*"sync-worker\/src\/worker\.js"/.test(jsonc);
  if (mainOk) ok("root config points at sync-worker/src/worker.js");
  else fail('root wrangler.jsonc "main" must be "sync-worker/src/worker.js"');
} else warn("wrangler configs not found — skipped");

// --- Reminders --------------------------------------------------------------------
console.log("\nManual steps this script can't cover");
console.log("  • open tests.html on the served app — all browser tests must pass");
console.log("  • if sync-worker/ changed: run its endpoint tests (sync-worker/test-endpoints.sh)");
console.log("  • if schema-clubs.sql changed: run the remote D1 migration BEFORE pushing");
console.log("  • QA.md real-device pass for anything user-facing");

console.log(`\n${failures ? "❌ " + failures + " check(s) failed" : "✅ preflight clean"}${warnings ? " · " + warnings + " warning(s)" : ""}\n`);
process.exit(failures ? 1 : 0);
