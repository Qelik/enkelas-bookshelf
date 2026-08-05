import Foundation

/// A small XML tree, built on `XMLParser`.
///
/// `XMLParser` is push-only: it calls you back per element and you assemble the
/// structure yourself. Every consumer here wants the same thing — a tree it can
/// search by tag — so that assembly happens once, in one place.
///
/// Namespace prefixes are deliberately kept (`dc:title` stays `dc:title`) and
/// lookups try both forms, because ePubs in the wild are inconsistent about
/// whether they declare a default namespace, and normalising would mean guessing.
public enum XMLLite {

    public final class Node: @unchecked Sendable {
        public let tag: String
        public internal(set) var attributes: [String: String]
        public internal(set) var children: [Node] = []
        /// Character data directly inside this element, plus its descendants',
        /// which is what a TOC label needs when it wraps text in a `<span>`.
        public internal(set) var text: String = ""

        init(tag: String, attributes: [String: String]) {
            self.tag = tag
            self.attributes = attributes
        }

        /// Depth-first search, matching with or without a namespace prefix.
        public func first(tag wanted: String) -> Node? {
            if matches(wanted) { return self }
            for child in children {
                if let hit = child.first(tag: wanted) { return hit }
            }
            return nil
        }

        public func all(tag wanted: String) -> [Node] {
            var out: [Node] = []
            collect(wanted, into: &out)
            return out
        }

        private func collect(_ wanted: String, into out: inout [Node]) {
            if matches(wanted) { out.append(self) }
            for child in children { child.collect(wanted, into: &out) }
        }

        private func matches(_ wanted: String) -> Bool {
            if tag == wanted { return true }
            // `dc:title` should be found by `title`, and vice versa.
            let ownLocal = tag.split(separator: ":").last.map(String.init) ?? tag
            let wantedLocal = wanted.split(separator: ":").last.map(String.init) ?? wanted
            return ownLocal == wantedLocal
        }
    }

    public static func parse(_ data: Data) throws -> Node {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse(), let root = builder.root else {
            throw ZipArchive.Failure.corrupt(parser.parserError?.localizedDescription ?? "unreadable XML")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String]
        ) {
            let node = Node(tag: elementName, attributes: attributeDict)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let current = stack.last else { return }
            current.text += string
            // Bubble text up so a label wrapped in inline markup still reads as
            // one string at the element that logically owns it.
            for ancestor in stack.dropLast() { ancestor.text += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?
        ) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }

    // MARK: - Text extraction

    /// What's inside `<body>`, or the whole string if there is no body tag —
    /// a chapter fragment without one is still readable content.
    public static func bodyContents(of html: String) -> String {
        guard let open = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) else {
            return html
        }
        let after = html[open.upperBound...]
        guard let close = after.range(of: "</body>", options: [.caseInsensitive, .backwards]) else {
            return String(after)
        }
        return String(after[..<close.lowerBound])
    }

    /// Plain text from an XHTML chapter, for search and character counting.
    ///
    /// Regex rather than a parse: chapter markup in the wild is frequently not
    /// well-formed XML, and a strict parser would refuse whole books over a
    /// stray `&`. Search results and a reading-speed estimate both degrade
    /// gracefully; a book that won't open does not.
    public static func strippingTags(_ html: String) -> String {
        // Body only. The reader renders the body and nothing else, and highlight
        // and search offsets are character positions into *this* string — so any
        // text counted here that the reader never shows would shift every offset
        // in the chapter and land a jump in the wrong place.
        var s = bodyContents(of: html)
        // Script and style content is not prose and must not be counted.
        // `[\s\S]` rather than `.`, which stops at a newline: a style block or a
        // script spanning two lines would survive and its source would be
        // counted as prose.
        for tag in ["script", "style", "head"] {
            s = s.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = decodeEntities(s)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
            "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric forms, decimal and hex.
        for pattern in ["&#([0-9]+);", "&#[xX]([0-9a-fA-F]+);"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let hex = pattern.contains("x")
            // Rebuilt forwards into a new string, so replacing one match can't
            // invalidate the ranges of the ones after it.
            var result = ""
            var last = out.startIndex
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
                guard let whole = Range(match.range, in: out),
                      let digits = Range(match.range(at: 1), in: out),
                      let code = UInt32(out[digits], radix: hex ? 16 : 10),
                      let scalar = Unicode.Scalar(code)
                else { continue }
                result += out[last..<whole.lowerBound]
                result.unicodeScalars.append(scalar)
                last = whole.upperBound
            }
            result += out[last...]
            out = result
        }
        return out
    }
}
