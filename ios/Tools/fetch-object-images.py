#!/usr/bin/env python3
"""Fetch photographs for the shelf objects and cut them out.

    ios/Tools/fetch-object-images.py [kind ...]

Searches Wikimedia Commons, **keeps only public-domain and CC0 images**,
downloads the best candidate, and runs `cutout.swift` to lift the subject onto
transparency. Writes the PNG into `ios/BookshelfApp/Models/` and records what
it took, and under what licence, in `CREDITS.json` beside them.

**Why the licence filter is not optional.** These images ship inside an App
Store binary. CC BY-SA is share-alike — arguably viral over the bundle — and
CC BY needs visible attribution. Public domain and CC0 need neither, so those
are the only two this will take. If a kind has no PD result the script says so
and leaves that object on its drawing rather than quietly shipping something
with strings attached.
"""
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "BookshelfApp" / "Models"
CREDITS = OUT / "CREDITS.json"
CUTOUT = ROOT / "Tools" / "cutout.swift"
CACHE = pathlib.Path("/tmp/shelf-object-sources")

API = "https://commons.wikimedia.org/w/api.php"
UA = "EnkelasBookshelf/1.0 (shelf object art; contact via repo)"

# Searches biased hard towards **museum open-access collections** — the Met,
# LACMA, the Rijksmuseum, Cleveland.
#
# That bias is the whole trick. A generic search returns correctly-licensed but
# useless pictures: a greyscale scan from a 1920s seed catalogue for "potted
# plant", an oil painting for "Socrates". Museums publish CC0 photographs of
# *objects*, professionally lit on a plain background — which is both exactly
# what a shelf ornament is, and the ideal input for a subject lift.
#
# Netsuke especially: hundreds of small carved animals, CC0, beautifully shot.
QUERIES = {
    "plant": ["bonsai tree white background", "potted plant photograph white background",
              "houseplant pot isolated"],
    "stackedBooks": ["books stack MET", "stack of books white background"],
    "candle": ["candle burning white background", "candlestick MET"],
    "bookend": ["bookend MET", "bookend"],
    "photo": ["picture frame MET", "photo frame white background"],
    "clock": ["table clock MET", "clock Rijksmuseum", "mantel clock white background"],
    "cat": ["cat netsuke", "cat figurine MET", "cat sculpture LACMA"],
    "crystal": ["amethyst crystal white background", "quartz crystal isolated"],
    "bust": ["marble bust MET", "portrait bust Rijksmuseum", "marble head LACMA"],
    "dragonPerched": ["dragon netsuke", "dragon figure LACMA", "dragon bronze MET"],
    "dragonCoiled": ["dragon sculpture coiled", "coiled dragon LACMA"],
}

FREE = ("public domain", "cc0", "pd-")


def api(params: dict) -> dict:
    """One search, backing off when Commons says to.

    Firing eleven objects' worth of searches straight through earns a 429 about
    a third of the way down the list, which reads as "no public-domain image
    exists" when it means "slow down".
    """
    url = f"{API}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 4:
                raise
            wait = 5 * (attempt + 1)
            print(f"    rate limited, waiting {wait}s")
            time.sleep(wait)
    return {}


def candidates(query: str) -> list[dict]:
    try:
        data = api({
            "action": "query", "format": "json", "generator": "search",
            "gsrsearch": query, "gsrnamespace": 6, "gsrlimit": 20,
            "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata",
            "iiextmetadatafilter": "LicenseShortName|Artist|ImageDescription",
        })
    except Exception as e:
        print(f"    search failed: {e}")
        return []

    out = []
    for page in (data.get("query") or {}).get("pages", {}).values():
        info = (page.get("imageinfo") or [{}])[0]
        meta = info.get("extmetadata") or {}
        licence = (meta.get("LicenseShortName") or {}).get("value", "")
        if not any(f in licence.lower() for f in FREE):
            continue
        if info.get("mime") not in ("image/jpeg", "image/png"):
            continue
        # Big enough to cut out, small enough to fetch quickly.
        if not (60_000 < info.get("size", 0) < 12_000_000):
            continue
        out.append({
            "title": page["title"],
            "url": info["url"].split("?")[0],
            "licence": licence,
            "size": info.get("size", 0),
            "artist": (meta.get("Artist") or {}).get("value", ""),
        })
    return out


def fetch(kind: str) -> dict | None:
    print(f"  {kind}:")
    for query in QUERIES[kind]:
        time.sleep(2)
        for cand in candidates(query):
            CACHE.mkdir(parents=True, exist_ok=True)
            raw = CACHE / f"{kind}{pathlib.Path(cand['url']).suffix}"
            try:
                req = urllib.request.Request(cand["url"], headers={"User-Agent": UA})
                with urllib.request.urlopen(req, timeout=90) as r:
                    raw.write_bytes(r.read())
            except Exception as e:
                print(f"    download failed ({e}), next candidate")
                continue

            png = OUT / f"shelf-{kind}.png"
            result = subprocess.run(
                ["swift", str(CUTOUT), str(raw), str(png), "512"],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                print(f"    no subject in {cand['title'][5:50]} — next candidate")
                continue

            print(f"    ✓ {result.stdout.strip()}  [{cand['licence']}]  {cand['title'][5:60]}")
            return {
                "kind": kind, "file": png.name, "source": cand["url"],
                "title": cand["title"], "licence": cand["licence"], "artist": cand["artist"],
            }
        print(f"    nothing public-domain for “{query}”")
    print(f"    ✗ {kind} keeps its drawing")
    return None


def show(query: str):
    """Print candidates so a human can pick the right subject.

    Text search reliably gets the *licence* right and the *subject* wrong about
    half the time — "cat netsuke" returned an enamelled disc, "Socrates" an oil
    painting. There is no automated fix for that; somebody has to look.
    """
    print(f"— {query}")
    for c in candidates(query):
        print(f"   {c['licence'][:13]:14} {c['size']//1024:5}KB  {c['title'][5:72]}")
        print(f"                          {c['url']}")


def thumb(url: str, width: int = 640) -> str:
    """Wikimedia's thumbnail URL for a full-resolution file.

    Their 429 response asks for this explicitly rather than hammering the
    originals, and it suits us anyway: everything is scaled to 512px tall in
    the end, so fetching a 5 MB master to throw 90% of it away was rude and
    slow in equal measure.
    """
    marker = "/commons/"
    if marker not in url or "/thumb/" in url:
        return url
    head, tail = url.split(marker, 1)
    return f"{head}{marker}thumb/{tail}/{width}px-{tail.rsplit('/', 1)[-1]}"


def fetch_url(kind: str, url: str, licence: str, title: str) -> dict | None:
    """Take a specific image that has already been eyeballed."""
    CACHE.mkdir(parents=True, exist_ok=True)
    raw = CACHE / f"{kind}{pathlib.Path(url).suffix}"
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as r:
        raw.write_bytes(r.read())
    png = OUT / f"shelf-{kind}.png"
    res = subprocess.run(["swift", str(CUTOUT), str(raw), str(png), "512"],
                         capture_output=True, text=True)
    if res.returncode != 0:
        print(f"  ✗ {kind}: {res.stderr.strip()}")
        return None
    print(f"  ✓ {kind}: {res.stdout.strip()}  [{licence}]")
    return {"kind": kind, "file": png.name, "source": url, "title": title,
            "licence": licence, "artist": ""}


if __name__ == "__main__":
    if sys.argv[1:2] == ["--list"]:
        for q in sys.argv[2:]:
            show(q)
        sys.exit()
    if sys.argv[1:2] == ["--pick"]:
        kind, url, licence, title = sys.argv[2:6]
        credits = json.loads(CREDITS.read_text()) if CREDITS.exists() else {}
        if (got := fetch_url(kind, url, licence, title)):
            credits[kind] = got
            CREDITS.write_text(json.dumps(credits, indent=2, sort_keys=True) + "\n")
        sys.exit()
    wanted = sys.argv[1:] or list(QUERIES)
    credits = json.loads(CREDITS.read_text()) if CREDITS.exists() else {}
    print(f"fetching {len(wanted)} object image(s) — public domain and CC0 only\n")
    for kind in wanted:
        if kind not in QUERIES:
            print(f"  unknown kind: {kind}")
            continue
        if (got := fetch(kind)):
            credits[kind] = got
    OUT.mkdir(parents=True, exist_ok=True)
    CREDITS.write_text(json.dumps(credits, indent=2, sort_keys=True) + "\n")
    print(f"\n{len(credits)} of {len(QUERIES)} objects have a photograph; the rest use their drawing.")
