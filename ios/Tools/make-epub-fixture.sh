#!/usr/bin/env bash
# Build the test ePubs used by EPUBTests.
#
#   ios/Tools/make-epub-fixture.sh
#
# Deliberately built with the system `zip`, not by our own code: a fixture
# produced by the thing under test would agree with its own bugs. `zip -X -0`
# for the mimetype entry (stored, first, no extra fields) is what the ePub spec
# requires and what real readers check for.
set -eu
OUT="$(cd "$(dirname "$0")/.." && pwd)/BookshelfCore/Tests/BookshelfCoreTests/Fixtures"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

build() {   # build <name> <toc-style: nav|ncx>
  # Separate statements: within one `local`, a later initialiser does not see an
  # earlier one in this shell, and `set -u` turns that into an error.
  local name="$1"
  local toc="$2"
  local root="$WORK/$name"
  local NAVITEM
  rm -rf "$root"; mkdir -p "$root/META-INF" "$root/OEBPS/text"

  printf 'application/epub+zip' > "$root/mimetype"

  cat > "$root/META-INF/container.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
XML

  for n in 1 2 3; do
    cat > "$root/OEBPS/text/chapter$n.xhtml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $n</title>
<style>p { margin: 1em 0 }</style></head>
<body><h1>Chapter $n</h1>
<p>The quick brown fox jumps over the lazy dog. Chapter $n has words in it &amp; an ampersand.</p>
<p>A second paragraph with an em dash &#8212; and a curly quote &#x201C;like this&#x201D;.</p>
</body></html>
XML
  done

  if [ "$toc" = "nav" ]; then
    cat > "$root/OEBPS/nav.xhtml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<body><nav epub:type="toc"><ol>
  <li><a href="text/chapter1.xhtml">The Beginning</a>
    <ol><li><a href="text/chapter1.xhtml#part2">A Nested Part</a></li></ol></li>
  <li><a href="text/chapter2.xhtml">The Middle</a></li>
  <li><a href="text/chapter3.xhtml">The End</a></li>
</ol></nav></body></html>
XML
    NAVITEM='<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
  else
    cat > "$root/OEBPS/toc.ncx" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><navMap>
  <navPoint id="n1" playOrder="1"><navLabel><text>The Beginning</text></navLabel>
    <content src="text/chapter1.xhtml"/>
    <navPoint id="n1a" playOrder="2"><navLabel><text>A Nested Part</text></navLabel>
      <content src="text/chapter1.xhtml#part2"/></navPoint></navPoint>
  <navPoint id="n2" playOrder="3"><navLabel><text>The Middle</text></navLabel>
    <content src="text/chapter2.xhtml"/></navPoint>
  <navPoint id="n3" playOrder="4"><navLabel><text>The End</text></navLabel>
    <content src="text/chapter3.xhtml"/></navPoint>
</navMap></ncx>
XML
    NAVITEM='<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
  fi

  printf 'not-really-a-png-but-binary-enough\x00\x01\x02' > "$root/OEBPS/cover.png"

  cat > "$root/OEBPS/content.opf" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:test-$name</dc:identifier>
    <dc:title>A Test Book</dc:title>
    <dc:creator>Quill Marlow</dc:creator>
    <dc:language>en</dc:language>
    <meta name="cover" content="cover"/>
  </metadata>
  <manifest>
    $NAVITEM
    <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
    <item id="c1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/chapter2.xhtml" media-type="application/xhtml+xml"/>
    <item id="c3" href="text/chapter3.xhtml" media-type="application/xhtml+xml"/>
    <item id="ad" href="text/chapter3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine $( [ "$toc" = "ncx" ] && printf 'toc="ncx"' )>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="c3"/>
    <itemref idref="ad" linear="no"/>
  </spine>
</package>
XML

  ( cd "$root" && zip -X -0 -q "$OUT/$name.epub" mimetype \
      && zip -X -9 -qr "$OUT/$name.epub" META-INF OEBPS )
  echo "  · $name.epub  ($(wc -c < "$OUT/$name.epub" | tr -d ' ') bytes)"
}

echo "writing fixtures to $(basename "$OUT")/"
build "sample-epub3" nav
build "sample-epub2" ncx
echo "done"
