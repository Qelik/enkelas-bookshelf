import Foundation

/// An opened ePub: its metadata, its reading order, and its table of contents.
///
/// Ported from `parseEpub()` in `src/reader.ts`, which walks the same three
/// hops: `META-INF/container.xml` names the OPF, the OPF lists the manifest and
/// the spine, and either the EPUB 3 nav document or the EPUB 2 NCX gives the
/// contents. Both TOC formats are read because plenty of real books are still
/// EPUB 2, and a book without a contents drawer feels broken.
public struct EPUBPackage: Sendable {

    public struct Chapter: Sendable, Hashable {
        /// Path inside the archive, already resolved against the OPF's folder.
        public let path: String
        /// Human label from the TOC, when the book bothers to give one.
        public var title: String?
    }

    public struct TOCEntry: Sendable, Hashable, Identifiable {
        public var id: String { path + "#" + (fragment ?? "") }
        public let title: String
        public let path: String
        public let fragment: String?
        public let depth: Int
    }

    public let title: String
    public let author: String
    public let language: String?
    /// Reading order.
    public private(set) var spine: [Chapter]
    public let toc: [TOCEntry]
    /// Cover image path inside the archive, if the book declares one.
    public let coverPath: String?
    /// Directory the OPF lives in — every href in the book resolves against it.
    public let baseDirectory: String

    private let archive: ZipArchive

    // MARK: - Opening

    public init(archive: ZipArchive) throws {
        self.archive = archive

        // A conforming ePub always has this at a fixed path; if it doesn't, the
        // file is something else wearing the extension.
        guard archive.contains("META-INF/container.xml") else {
            throw ZipArchive.Failure.corrupt("no META-INF/container.xml — is this really an ePub?")
        }
        let container = try XMLLite.parse(archive.read("META-INF/container.xml"))
        guard let opfPath = container.first(tag: "rootfile")?.attributes["full-path"], !opfPath.isEmpty else {
            throw ZipArchive.Failure.corrupt("container.xml doesn't say where the book is")
        }
        guard archive.contains(opfPath) else {
            throw ZipArchive.Failure.entryNotFound(opfPath)
        }

        let base = EPUBPackage.directory(of: opfPath)
        self.baseDirectory = base

        let opf = try XMLLite.parse(archive.read(opfPath))
        self.title = opf.first(tag: "dc:title")?.text ?? opf.first(tag: "title")?.text ?? "Untitled"
        self.author = opf.first(tag: "dc:creator")?.text ?? opf.first(tag: "creator")?.text ?? ""
        self.language = opf.first(tag: "dc:language")?.text ?? opf.first(tag: "language")?.text

        // manifest: id → (href, properties, media-type)
        var hrefByID: [String: String] = [:]
        var propertiesByID: [String: String] = [:]
        var mediaTypeByID: [String: String] = [:]
        for item in opf.all(tag: "item") {
            guard let id = item.attributes["id"], let href = item.attributes["href"] else { continue }
            hrefByID[id] = href
            propertiesByID[id] = item.attributes["properties"] ?? ""
            mediaTypeByID[id] = item.attributes["media-type"] ?? ""
        }

        // spine: itemrefs in reading order. `linear="no"` marks things like
        // adverts and colophons that are reachable but not part of the flow.
        var order: [Chapter] = []
        for ref in opf.all(tag: "itemref") {
            guard let idref = ref.attributes["idref"],
                  let href = hrefByID[idref],
                  ref.attributes["linear"] != "no"
            else { continue }
            order.append(Chapter(path: EPUBPackage.resolve(href, against: base), title: nil))
        }
        guard !order.isEmpty else {
            throw ZipArchive.Failure.corrupt("the book has no readable chapters")
        }
        self.spine = order

        // Cover: EPUB 3 marks it with a manifest property; EPUB 2 uses a <meta>
        // pointing at a manifest id.
        var cover: String?
        if let id = propertiesByID.first(where: { $0.value.contains("cover-image") })?.key, let href = hrefByID[id] {
            cover = EPUBPackage.resolve(href, against: base)
        } else if let name = opf.all(tag: "meta").first(where: { $0.attributes["name"] == "cover" })?.attributes["content"],
                  let href = hrefByID[name] {
            cover = EPUBPackage.resolve(href, against: base)
        }
        self.coverPath = cover

        // Contents: EPUB 3 nav document first, then the EPUB 2 NCX.
        var entries: [TOCEntry] = []
        if let navID = propertiesByID.first(where: { $0.value.contains("nav") })?.key,
           let href = hrefByID[navID] {
            let navPath = EPUBPackage.resolve(href, against: base)
            if let data = try? archive.read(navPath), let doc = try? XMLLite.parse(data) {
                entries = EPUBPackage.parseNav(doc, base: EPUBPackage.directory(of: navPath))
            }
        }
        if entries.isEmpty,
           let ncxID = mediaTypeByID.first(where: { $0.value == "application/x-dtbncx+xml" })?.key,
           let href = hrefByID[ncxID] {
            let ncxPath = EPUBPackage.resolve(href, against: base)
            if let data = try? archive.read(ncxPath), let doc = try? XMLLite.parse(data) {
                entries = EPUBPackage.parseNCX(doc, base: EPUBPackage.directory(of: ncxPath))
            }
        }
        self.toc = entries

        // Label the spine from the contents, so the chapter indicator says
        // "Chapter Four" rather than "12 of 43".
        let titleByPath = Dictionary(entries.map { ($0.path, $0.title) }, uniquingKeysWith: { first, _ in first })
        for i in spine.indices where spine[i].title == nil {
            spine[i].title = titleByPath[spine[i].path]
        }
    }

    public init(data: Data) throws {
        try self.init(archive: ZipArchive(data: data))
    }

    // MARK: - Reading

    public func data(at path: String) throws -> Data {
        try archive.read(path)
    }

    public func html(forChapter index: Int) throws -> String {
        guard spine.indices.contains(index) else {
            throw ZipArchive.Failure.entryNotFound("chapter \(index)")
        }
        return String(decoding: try archive.read(spine[index].path), as: UTF8.self)
    }

    public func contains(_ path: String) -> Bool { archive.contains(path) }

    /// Plain text of a chapter, for search and for the character counts the
    /// reading-speed estimate is built on.
    public func plainText(forChapter index: Int) throws -> String {
        XMLLite.strippingTags(try html(forChapter: index))
    }

    // MARK: - Path helpers

    /// ePub hrefs are relative to the document that names them, and they can be
    /// percent-encoded — a filename with a space is common enough to matter.
    static func resolve(_ href: String, against directory: String) -> String {
        var raw = href
        if let hash = raw.firstIndex(of: "#") { raw = String(raw[raw.startIndex..<hash]) }
        raw = raw.removingPercentEncoding ?? raw
        if raw.hasPrefix("/") { return String(raw.dropFirst()) }
        guard !directory.isEmpty else { return normalise(raw) }
        return normalise(directory + raw)
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex...slash])
    }

    /// Collapses `..` and `.` so `OEBPS/text/../images/a.png` finds the entry
    /// actually stored as `OEBPS/images/a.png`.
    ///
    /// Public because the reader's URL scheme handler has to apply exactly the
    /// same collapsing to an incoming request path — a `..` that resolved
    /// differently there would be a way out of the archive.
    public static func normalise(_ path: String) -> String {
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: false) {
            if part == ".." { if !out.isEmpty { out.removeLast() } }
            else if part == "." || part.isEmpty { continue }
            else { out.append(part) }
        }
        return out.joined(separator: "/")
    }

    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let frag = String(href[href.index(after: hash)...])
        return frag.isEmpty ? nil : frag
    }

    // MARK: - Contents parsing

    private static func parseNav(_ doc: XMLLite.Node, base: String) -> [TOCEntry] {
        // The nav document has several <nav>s (toc, landmarks, page-list); only
        // the one typed "toc" is the table of contents.
        let navs = doc.all(tag: "nav")
        let toc = navs.first { $0.attributes["epub:type"] == "toc" || $0.attributes["type"] == "toc" } ?? navs.first
        guard let toc else { return [] }
        var out: [TOCEntry] = []
        collectNav(toc, base: base, depth: 0, into: &out)
        return out
    }

    private static func collectNav(_ node: XMLLite.Node, base: String, depth: Int, into out: inout [TOCEntry]) {
        for list in node.children where list.tag == "ol" || list.tag == "ul" {
            for item in list.children where item.tag == "li" {
                if let anchor = item.children.first(where: { $0.tag == "a" }),
                   let href = anchor.attributes["href"] {
                    let label = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.append(TOCEntry(
                        title: label.isEmpty ? "Untitled section" : label,
                        path: resolve(href, against: base),
                        fragment: fragment(of: href),
                        depth: depth
                    ))
                }
                collectNav(item, base: base, depth: depth + 1, into: &out)
            }
        }
    }

    private static func parseNCX(_ doc: XMLLite.Node, base: String) -> [TOCEntry] {
        guard let map = doc.first(tag: "navMap") else { return [] }
        var out: [TOCEntry] = []
        collectNCX(map, base: base, depth: 0, into: &out)
        return out
    }

    private static func collectNCX(_ node: XMLLite.Node, base: String, depth: Int, into out: inout [TOCEntry]) {
        for point in node.children where point.tag == "navPoint" {
            if let content = point.children.first(where: { $0.tag == "content" }),
               let src = content.attributes["src"] {
                let label = point.first(tag: "navLabel")?.first(tag: "text")?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                out.append(TOCEntry(
                    title: label.isEmpty ? "Untitled section" : label,
                    path: resolve(src, against: base),
                    fragment: fragment(of: src),
                    depth: depth
                ))
            }
            collectNCX(point, base: base, depth: depth + 1, into: &out)
        }
    }
}
