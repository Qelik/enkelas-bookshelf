import BookshelfCore
import SwiftUI
@preconcurrency import WebKit

/// Serves the inside of an ePub to the web view.
///
/// A chapter's markup refers to its own stylesheets, images and fonts by
/// relative path. Loading it with `loadHTMLString` would leave every one of
/// those pointing at nothing, so illustrated books would render as broken-image
/// icons. A custom scheme lets the archive answer those requests directly, with
/// nothing unpacked to disk.
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "bookshelf-epub"

    private let package: EPUBPackage

    init(package: EPUBPackage) {
        self.package = package
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // bookshelf-epub://book/OEBPS/text/chapter1.xhtml → OEBPS/text/chapter1.xhtml
        let path = EPUBPackage.normalise(url.path.removingPercentEncoding ?? url.path)
        guard !path.isEmpty, package.contains(path), let data = try? package.data(at: path) else {
            // 404 rather than an error: a book missing one decorative image
            // should still be readable.
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(for: path),
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "xhtml", "html", "htm": "application/xhtml+xml"
        case "css": "text/css"
        case "js": "text/javascript"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "otf": "font/otf"
        case "ttf": "font/ttf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        default: "application/octet-stream"
        }
    }
}

/// A web view that puts the reader's own actions into the system selection menu.
///
/// Selecting text in a web view already raises iOS's edit menu — Copy, Look Up,
/// Translate, Share. A second floating bar of ours would appear alongside it,
/// overlap the passage, and offer a duplicate Copy. Contributing to the menu
/// that's already there keeps one menu, in the place people expect it, and gets
/// the system's own placement and dismissal for free.
final class ReaderContentWebView: WKWebView {
    /// The selection as the page last reported it, in chapter character offsets.
    var currentSelection: ReaderWebView.TextSelection?
    /// False when the ePub isn't attached to a shelf book — there is nowhere for
    /// a quote to land, so the item is absent rather than present and inert.
    var canSaveQuote = false
    var onHighlight: ((ReaderWebView.TextSelection) -> Void)?
    var onSaveQuote: ((ReaderWebView.TextSelection) -> Void)?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard let selection = currentSelection else { return }

        var actions = [
            UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                self?.onHighlight?(selection)
            }
        ]
        if canSaveQuote {
            actions.append(
                UIAction(title: "Save quote", image: UIImage(systemName: "quote.opening")) { [weak self] _ in
                    self?.onSaveQuote?(selection)
                }
            )
        }
        // At the start, before Copy: these are the reasons to select text *in a
        // reading app*, and burying them behind the chevron would hide them.
        builder.insertChild(UIMenu(options: .displayInline, children: actions), atStartOfMenu: .root)
    }
}

/// The paginated chapter view.
///
/// Pagination is CSS multi-column, the same approach `src/reader.ts` uses: lay
/// the chapter out in columns exactly one viewport wide and translate sideways
/// to turn a page. It reflows correctly at any font size, and it costs no layout
/// code of our own — the web engine already knows how to break text into columns.
struct ReaderWebView: UIViewRepresentable {

    let package: EPUBPackage
    let chapter: Int
    let settings: ReaderSettings
    let highlights: [EPUBRecord.Highlight]
    /// A character offset to jump to once the chapter has laid out, then cleared.
    @Binding var seekOffset: Int?
    @Binding var page: Int
    @Binding var pageCount: Int
    /// Whether a quote has somewhere to go — see `ReaderContentWebView`.
    let canSaveQuote: Bool
    var onReady: () -> Void
    /// The chapter has laid out and knows how many pages it has.
    ///
    /// Separate from the `pageCount` binding because it fires on *every* layout,
    /// including one that happens to produce the same count as the chapter before
    /// it — which `onChange(of: pageCount)` would miss, and which is exactly when
    /// "take me to the last page" needs answering.
    var onLayout: (Int) -> Void = { _ in }
    var onTapEdge: (Int) -> Void
    var onHighlight: (TextSelection) -> Void
    var onSaveQuote: (TextSelection) -> Void

    struct TextSelection: Equatable {
        let start: Int
        let end: Int
        let text: String
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReaderContentWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EPUBSchemeHandler(package: package), forURLScheme: EPUBSchemeHandler.scheme)
        config.suppressesIncrementalRendering = true
        // JavaScript stays on because pagination needs it. What the *book*
        // brought is removed instead — see ReaderDocument.sanitize, plus a CSP
        // that forbids every remote fetch. Turning JS off here would disable our
        // paginator too, not just theirs.
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "reader")
        config.userContentController = controller

        let webView = ReaderContentWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false      // pages are turned, not scrolled
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.onHighlight = { [weak webView] selection in
            context.coordinator.parent.onHighlight(selection)
            webView?.currentSelection = nil
            context.coordinator.clearSelection()
        }
        webView.onSaveQuote = { [weak webView] selection in
            context.coordinator.parent.onSaveQuote(selection)
            webView?.currentSelection = nil
            context.coordinator.clearSelection()
        }
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: ReaderContentWebView, context: Context) {
        context.coordinator.parent = self
        webView.canSaveQuote = canSaveQuote
        context.coordinator.sync(chapter: chapter, settings: settings, page: page)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ReaderWebView
        weak var webView: ReaderContentWebView?
        private var loadedChapter: Int?
        private var loadedSettings: ReaderSettings?
        private var loadedHighlights: [EPUBRecord.Highlight] = []
        private var pendingPage: Int?

        init(_ parent: ReaderWebView) {
            self.parent = parent
        }

        func sync(chapter: Int, settings: ReaderSettings, page: Int) {
            guard let webView else { return }
            if loadedChapter != chapter || loadedSettings != settings {
                loadedChapter = chapter
                loadedSettings = settings
                pendingPage = page
                loadedHighlights = parent.highlights
                let html = ReaderDocument.html(
                    for: parent.package, chapter: chapter, settings: settings,
                    highlights: parent.highlights
                )
                // A base URL under our scheme is what makes the chapter's own
                // relative hrefs resolve back into the archive.
                let base = URL(string: "\(EPUBSchemeHandler.scheme)://book/\(parent.package.baseDirectory)")
                webView.loadHTMLString(html, baseURL: base)
            } else {
                // Re-apply only when they actually changed: re-wrapping the DOM
                // on every pass would fight the reader's own scroll position.
                if loadedHighlights != parent.highlights {
                    loadedHighlights = parent.highlights
                    webView.evaluateJavaScript("window.__reader && __reader.highlights(\(Self.json(parent.highlights)))")
                }
                if let offset = parent.seekOffset {
                    webView.evaluateJavaScript("window.__reader && __reader.seek(\(offset))")
                    parent.seekOffset = nil
                } else {
                    webView.evaluateJavaScript("window.__reader && __reader.show(\(page))")
                }
            }
        }

        static func json(_ highlights: [EPUBRecord.Highlight]) -> String {
            "[" + highlights.map { "{\"id\":\"\($0.id)\",\"start\":\($0.start),\"end\":\($0.end)}" }
                .joined(separator: ",") + "]"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let page = pendingPage ?? 0
            pendingPage = nil
            if let offset = parent.seekOffset {
                webView.evaluateJavaScript("window.__reader && __reader.seek(\(offset))")
                parent.seekOffset = nil
            } else {
                webView.evaluateJavaScript("window.__reader && __reader.show(\(page))")
            }
            parent.onReady()
        }

        func clearSelection() {
            webView?.evaluateJavaScript("window.__reader && __reader.clearSelection()")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["type"] as? String {
            case "layout":
                if let count = body["pages"] as? Int {
                    parent.pageCount = max(1, count)
                    parent.onLayout(max(1, count))
                }
            case "tap":
                if let side = body["side"] as? Int { parent.onTapEdge(side) }
            case "selection":
                // Held for the edit menu, which is built later and off our
                // control flow — see ReaderContentWebView.buildMenu.
                if let start = body["start"] as? Int,
                   let end = body["end"] as? Int,
                   let text = body["text"] as? String, !text.isEmpty {
                    webView?.currentSelection = TextSelection(start: start, end: end, text: text)
                } else {
                    webView?.currentSelection = nil
                }
            default:
                break
            }
        }
    }
}

/// Reader appearance. Equatable so a re-layout only happens when something that
/// actually affects layout changed.
struct ReaderSettings: Equatable, Codable {
    enum Theme: String, Codable, CaseIterable, Identifiable {
        case paper, sepia, night
        var id: String { rawValue }
        var label: String {
            switch self {
            case .paper: "Paper"
            case .sepia: "Sepia"
            case .night: "Night"
            }
        }
    }

    var fontSize: Double = 19
    var theme: Theme = .paper

    var background: Color {
        switch theme {
        case .paper: Color(red: 0.98, green: 0.97, blue: 0.94)
        case .sepia: Color(red: 0.96, green: 0.91, blue: 0.82)
        case .night: Color(red: 0.09, green: 0.09, blue: 0.10)
        }
    }

    var ink: Color {
        switch theme {
        case .paper, .sepia: Color(red: 0.16, green: 0.14, blue: 0.12)
        case .night: Color(red: 0.85, green: 0.83, blue: 0.79)
        }
    }
}
