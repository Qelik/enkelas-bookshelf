import BookshelfCore
import Foundation

/// Builds the page shown for one chapter.
///
/// **An ePub is untrusted content.** It arrives as a file from the internet and
/// its chapters are arbitrary HTML, which may carry `<script>` tags, remote
/// image beacons and tracking pixels. Everything the book brought is stripped
/// here, and what remains is served from a local scheme that can only reach
/// inside the archive — so a book cannot phone home, and cannot tell anyone what
/// someone is reading.
///
/// Pagination is CSS multi-column, the approach `src/reader.ts` already uses:
/// lay the chapter out in columns exactly one viewport wide and translate
/// sideways to turn a page. It reflows at any font size and costs no layout code
/// of our own.
enum ReaderDocument {

    static func html(
        for package: EPUBPackage, chapter: Int, settings: ReaderSettings,
        highlights: [EPUBRecord.Highlight] = []
    ) -> String {
        let raw = (try? package.html(forChapter: chapter)) ?? "<p>This chapter couldn't be opened.</p>"
        let body = sanitize(bodyContents(of: raw))
        return template(body: body, settings: settings, highlights: highlights)
    }

    /// Pull out what's inside `<body>`, so the book's own `<head>` — with its
    /// scripts, metadata and remote stylesheet links — is dropped wholesale.
    ///
    /// The same function the text extractor uses, deliberately: what gets
    /// rendered here and what gets counted there have to be the same characters,
    /// or every highlight and search offset is measured against a different
    /// chapter than the one on screen.
    static func bodyContents(of html: String) -> String {
        XMLLite.bodyContents(of: html)
    }

    /// Remove what a book has no business running or fetching.
    static func sanitize(_ html: String) -> String {
        var s = html
        // Scripts: JavaScript stays enabled in the web view because pagination
        // needs it, so the book's own scripts have to go rather than relying on
        // the engine to refuse them.
        s = s.replacingOccurrences(
            of: "<script[^>]*>[\\s\\S]*?</script>", with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: "<script[^>]*/?>", with: "", options: [.regularExpression, .caseInsensitive])
        // Inline handlers — onload, onclick and friends.
        s = s.replacingOccurrences(
            of: "\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Anything that would reach the network: a remote image in a book is a
        // tracking pixel telling someone that this person is reading this page.
        s = s.replacingOccurrences(
            of: "(src|href)\\s*=\\s*[\"']\\s*(https?:|//)[^\"']*[\"']", with: "$1=\"\"",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(
            of: "<(iframe|object|embed|video|audio|form)[^>]*>[\\s\\S]*?</\\1>", with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return s
    }

    private static func template(
        body: String, settings: ReaderSettings, highlights: [EPUBRecord.Highlight]
    ) -> String {
        let (bg, ink) = colors(for: settings.theme)
        // Ranges as plain JSON, applied after layout — see applyHighlights below.
        let ranges = highlights
            .map { "{id:\"\($0.id)\",start:\($0.start),end:\($0.end)}" }
            .joined(separator: ",")
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <!-- Belt and braces alongside the stripping above: even if some markup
             slips through, this forbids every remote fetch and inline script. -->
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; img-src \(EPUBSchemeHandler.scheme):; style-src \(EPUBSchemeHandler.scheme): 'unsafe-inline'; font-src \(EPUBSchemeHandler.scheme):; script-src 'unsafe-inline';">
        <style>
          :root { color-scheme: \(settings.theme == .night ? "dark" : "light"); }
          html, body { margin: 0; padding: 0; background: \(bg); color: \(ink); }
          body {
            font: \(settings.fontSize)px/1.6 -apple-system, "Iowan Old Style", Georgia, serif;
            -webkit-text-size-adjust: none;
            hyphens: auto; -webkit-hyphens: auto;
            text-rendering: optimizeLegibility;
          }
          #viewport { overflow: hidden; position: fixed; inset: 0; padding: 24px 22px 34px; }
          #content {
            height: 100%;
            column-gap: 44px;
            column-fill: auto;
            transition: transform .18s ease-out;
            will-change: transform;
          }
          /* The book's own colours are usually written for a white page, so a
             night theme has to override them or half the text disappears. */
          #content, #content * { color: \(ink) !important; background: transparent !important; }
          img, svg { max-width: 100%; max-height: 80vh; height: auto; object-fit: contain; }
          a { color: inherit; text-decoration: underline; }
          h1, h2, h3 { line-height: 1.25; break-after: avoid; }
          p { orphans: 2; widows: 2; }
          pre, table { max-width: 100%; overflow-x: auto; }
          /* Written as #content mark so it outranks the transparent-background
             override above — that rule is !important and matches every
             descendant, so a plain `mark.hl` rule loses and the highlight
             renders with no colour at all. */
          #content mark.hl {
            background: rgba(255, 214, 0, .42) !important;
            color: inherit !important;
            border-radius: 2px;
            padding: 0 1px;
            -webkit-box-decoration-break: clone;
          }
          #content mark.found { background: rgba(0, 122, 255, .38) !important; }
        </style>
        </head>
        <body>
        <div id="viewport"><div id="content">\(body)</div></div>
        <script>
        (function () {
          var content = document.getElementById('content');
          var viewport = document.getElementById('viewport');
          var page = 0, pages = 1, step = 0;

          function layout() {
            var width = viewport.clientWidth - 44;   // padding is inside clientWidth
            content.style.columnWidth = width + 'px';
            step = width + 44;
            // scrollWidth grows by one column per page; the gap on the last
            // column is why this rounds rather than divides exactly.
            pages = Math.max(1, Math.round(content.scrollWidth / step));
            post({ type: 'layout', pages: pages });
          }

          function show(n) {
            page = Math.max(0, Math.min(pages - 1, n));
            content.style.transform = 'translateX(' + (-page * step) + 'px)';
          }

          function post(msg) {
            try { window.webkit.messageHandlers.reader.postMessage(msg); } catch (e) {}
          }

          // Tapping the outer third of either side turns a page — the gesture
          // every reading app uses, and the one that works one-handed.
          document.addEventListener('click', function (e) {
            var third = window.innerWidth / 3;
            if (e.clientX < third) post({ type: 'tap', side: -1 });
            else if (e.clientX > window.innerWidth - third) post({ type: 'tap', side: 1 });
            else post({ type: 'tap', side: 0 });
          });

          // --- Character offsets ------------------------------------------
          // Everything persistent is addressed by offset into the chapter's
          // text, never by pixel or DOM path: those change with font size,
          // theme and screen, and the text does not.
          function textNodes() {
            var walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT, null);
            var out = [], n;
            while ((n = walker.nextNode())) out.push(n);
            return out;
          }

          function offsetOf(node, nodeOffset) {
            var nodes = textNodes(), total = 0;
            for (var i = 0; i < nodes.length; i++) {
              if (nodes[i] === node) return total + nodeOffset;
              total += nodes[i].nodeValue.length;
            }
            return -1;
          }

          function wrapRange(start, end, cls, id) {
            var nodes = textNodes(), off = 0, segs = [];
            for (var i = 0; i < nodes.length; i++) {
              var len = nodes[i].nodeValue.length;
              var a = Math.max(start, off), b = Math.min(end, off + len);
              if (a < b) segs.push({ node: nodes[i], from: a - off, to: b - off });
              off += len;
              if (off >= end) break;
            }
            // Backwards: wrapping a segment splits its text node, which would
            // invalidate the offsets of every segment after it.
            segs.reverse();
            for (var j = 0; j < segs.length; j++) {
              try {
                var r = document.createRange();
                r.setStart(segs[j].node, segs[j].from);
                r.setEnd(segs[j].node, segs[j].to);
                var m = document.createElement('mark');
                m.className = cls;
                if (id) m.dataset.hl = id;
                r.surroundContents(m);
              } catch (e) { /* a range crossing an element boundary — skip it */ }
            }
            return segs.length > 0;
          }

          function applyHighlights(list) {
            // Remove ours only, and put the text back so offsets stay honest.
            var old = content.querySelectorAll('mark.hl, mark.found');
            for (var i = 0; i < old.length; i++) {
              var m = old[i];
              m.replaceWith(document.createTextNode(m.textContent));
            }
            content.normalize();
            for (var j = 0; j < list.length; j++) {
              wrapRange(list[j].start, list[j].end, 'hl', list[j].id);
            }
          }

          function pageOfOffset(n) {
            // Wrap a zero-width marker at the offset, read which column it
            // landed in, then take it out again.
            if (!wrapRange(n, n + 1, 'found', 'seek')) return 0;
            var marker = content.querySelector('[data-hl="seek"]');
            if (!marker) return 0;
            var page = Math.max(0, Math.round((marker.offsetLeft - content.offsetLeft) / step));
            marker.replaceWith(document.createTextNode(marker.textContent));
            content.normalize();
            return page;
          }

          document.addEventListener('selectionchange', function () {
            var sel = document.getSelection();
            if (!sel || sel.isCollapsed || !sel.rangeCount) { post({ type: 'selection' }); return; }
            var r = sel.getRangeAt(0);
            var start = offsetOf(r.startContainer, r.startOffset);
            var end = offsetOf(r.endContainer, r.endOffset);
            if (start < 0 || end <= start) { post({ type: 'selection' }); return; }
            post({ type: 'selection', start: start, end: end, text: sel.toString() });
          });

          window.__reader = {
            show: function (n) { layout(); show(n); },
            pages: function () { return pages; },
            highlights: function (list) { applyHighlights(list); layout(); show(page); },
            seek: function (n) { layout(); show(pageOfOffset(n)); },
            clearSelection: function () { document.getSelection().removeAllRanges(); }
          };

          // Re-apply on load, once the text is laid out.
          window.addEventListener('load', function () { applyHighlights([\(ranges)]); layout(); });

          window.addEventListener('resize', function () { layout(); show(page); });
          applyHighlights([\(ranges)]);
          layout();
        })();
        </script>
        </body></html>
        """
    }

    private static func colors(for theme: ReaderSettings.Theme) -> (String, String) {
        switch theme {
        case .paper: ("#faf8f0", "#2a2420")
        case .sepia: ("#f5e9d1", "#3b2f22")
        case .night: ("#17171a", "#d9d4cb")
        }
    }
}
