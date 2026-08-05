import Foundation
import Testing
@testable import BookshelfCore

/// The ePub engine, tested against archives the system `zip` produced.
///
/// The fixtures are deliberately not built by our own code: an archive written
/// by the thing under test would agree with its own bugs. `ios/Tools/make-epub-fixture.sh`
/// regenerates them.
struct EPUBTests {

    static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/\(name).epub")
        return try Data(contentsOf: url)
    }

    // MARK: - ZIP

    @Test("the archive lists its entries and skips directories")
    func readsEntries() throws {
        let zip = try ZipArchive(data: try Self.fixture("sample-epub3"))
        #expect(zip.contains("META-INF/container.xml"))
        #expect(zip.contains("OEBPS/content.opf"))
        #expect(zip.contains("OEBPS/text/chapter1.xhtml"))
        // Directory records carry no data; keeping them would make callers
        // filter them out everywhere.
        #expect(!zip.entries.keys.contains { $0.hasSuffix("/") })
    }

    @Test("a stored entry and a deflated entry both come back intact")
    func readsBothCompressionMethods() throws {
        let zip = try ZipArchive(data: try Self.fixture("sample-epub3"))
        // `mimetype` must be stored uncompressed and first — the one thing the
        // ePub spec is strict about.
        let mimetype = try #require(zip.entries["mimetype"])
        #expect(mimetype.method == 0)
        #expect(String(decoding: try zip.read(mimetype), as: UTF8.self) == "application/epub+zip")

        let opf = try #require(zip.entries["OEBPS/content.opf"])
        #expect(opf.method == 8, "the OPF should be deflated, or this isn't testing inflate")
        let text = String(decoding: try zip.read(opf), as: UTF8.self)
        #expect(text.contains("<dc:title>A Test Book</dc:title>"))
        #expect(text.utf8.count == opf.uncompressedSize)
    }

    @Test("binary content survives a round trip byte for byte")
    func readsBinary() throws {
        let zip = try ZipArchive(data: try Self.fixture("sample-epub3"))
        let cover = try zip.read("OEBPS/cover.png")
        // Images are the reason this can't go through String anywhere.
        #expect(cover.suffix(3) == Data([0x00, 0x01, 0x02]))
    }

    @Test("a file that isn't a zip is refused with something a person can read")
    func rejectsNonZip() {
        #expect(throws: ZipArchive.Failure.notAZip) {
            _ = try ZipArchive(data: Data("this is a plain text file, not an ePub".utf8))
        }
        #expect(throws: ZipArchive.Failure.self) {
            _ = try ZipArchive(data: Data())
        }
    }

    @Test("a missing entry names itself")
    func missingEntry() throws {
        let zip = try ZipArchive(data: try Self.fixture("sample-epub3"))
        #expect(throws: ZipArchive.Failure.entryNotFound("OEBPS/nope.xhtml")) {
            _ = try zip.read("OEBPS/nope.xhtml")
        }
    }

    @Test("a truncated archive fails instead of returning nonsense")
    func truncatedArchive() throws {
        let full = try Self.fixture("sample-epub3")
        // Chopping the tail removes the end-of-directory record.
        #expect(throws: ZipArchive.Failure.self) {
            _ = try ZipArchive(data: full.prefix(full.count / 2))
        }
    }

    // MARK: - Package

    @Test("an EPUB 3 book opens with its metadata, spine and contents", arguments: ["sample-epub3", "sample-epub2"])
    func opensBook(_ name: String) throws {
        // Both TOC formats have to work: plenty of real books are still EPUB 2,
        // and a book with no contents drawer feels broken.
        let book = try EPUBPackage(data: try Self.fixture(name))

        #expect(book.title == "A Test Book")
        #expect(book.author == "Quill Marlow")
        #expect(book.language == "en")
        #expect(book.baseDirectory == "OEBPS/")
        #expect(book.coverPath == "OEBPS/cover.png")

        // Three linear chapters. The fourth itemref is linear="no" — an advert
        // or colophon, reachable but not part of the reading flow.
        #expect(book.spine.count == 3)
        #expect(book.spine.map(\.path) == [
            "OEBPS/text/chapter1.xhtml",
            "OEBPS/text/chapter2.xhtml",
            "OEBPS/text/chapter3.xhtml",
        ])

        #expect(book.toc.map(\.title) == ["The Beginning", "A Nested Part", "The Middle", "The End"])
        // Nesting is kept so the drawer can indent.
        #expect(book.toc.map(\.depth) == [0, 1, 0, 0])
        // Hrefs resolve against the document that named them, not the archive root.
        #expect(book.toc[0].path == "OEBPS/text/chapter1.xhtml")
        #expect(book.toc[1].fragment == "part2")

        // The spine picks up its labels from the contents, so the reader can say
        // "The Middle" rather than "2 of 3".
        #expect(book.spine[1].title == "The Middle")
    }

    @Test("chapter text comes out readable, with entities decoded")
    func readsChapterText() throws {
        let book = try EPUBPackage(data: try Self.fixture("sample-epub3"))
        let text = try book.plainText(forChapter: 0)

        #expect(text.contains("The quick brown fox"))
        #expect(text.contains("an ampersand"))
        #expect(text.contains("&"), "&amp; should decode")
        #expect(text.contains("—"), "&#8212; should decode")
        #expect(text.contains("\u{201C}like this\u{201D}"), "hex entities should decode")
        // Markup and CSS are not prose, and counting them would skew the
        // reading-speed estimate built on character counts.
        #expect(!text.contains("<p>"))
        #expect(!text.contains("margin"))
    }

    @Test("a file that is a zip but not a book says so")
    func rejectsNonEPUBZip() throws {
        // Someone picks a .zip of holiday photos. That is a wrong-file mistake,
        // not a corrupt book, and the message should reflect it.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "not-a-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appending(path: "photo.txt")
        try Data("hello".utf8).write(to: file)

        let zipURL = scratch.appending(path: "photos.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-j", zipURL.path, file.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        #expect(throws: ZipArchive.Failure.self) {
            _ = try EPUBPackage(data: try Data(contentsOf: zipURL))
        }
    }

    // MARK: - Path resolution

    @Test("hrefs resolve the way ePub says they do", arguments: [
        ("chapter1.xhtml", "OEBPS/", "OEBPS/chapter1.xhtml"),
        ("text/chapter1.xhtml", "OEBPS/", "OEBPS/text/chapter1.xhtml"),
        ("../images/cover.png", "OEBPS/text/", "OEBPS/images/cover.png"),
        ("./chapter1.xhtml", "OEBPS/", "OEBPS/chapter1.xhtml"),
        ("/absolute.xhtml", "OEBPS/", "absolute.xhtml"),
        ("chapter1.xhtml#part2", "OEBPS/", "OEBPS/chapter1.xhtml"),
        // Percent-encoding is common the moment a filename has a space in it.
        ("my%20chapter.xhtml", "OEBPS/", "OEBPS/my chapter.xhtml"),
        ("chapter.xhtml", "", "chapter.xhtml"),
    ])
    func resolvesPaths(_ href: String, _ base: String, _ expected: String) {
        #expect(EPUBPackage.resolve(href, against: base) == expected)
    }

    @Test("fragments are split off the href")
    func fragments() {
        #expect(EPUBPackage.fragment(of: "chapter1.xhtml#part2") == "part2")
        #expect(EPUBPackage.fragment(of: "chapter1.xhtml") == nil)
        #expect(EPUBPackage.fragment(of: "chapter1.xhtml#") == nil)
    }

    // MARK: - XML

    @Test("namespaced tags are findable with or without the prefix")
    func namespaceTolerance() throws {
        // Real ePubs are inconsistent about declaring namespaces, and normalising
        // them would mean guessing which form the book meant.
        let doc = try XMLLite.parse(Data(#"<package><metadata><dc:title>T</dc:title></metadata></package>"#.utf8))
        #expect(doc.first(tag: "dc:title")?.text == "T")
        #expect(doc.first(tag: "title")?.text == "T")
    }

    @Test("text bubbles up through inline markup")
    func nestedText() throws {
        // A TOC label wrapped in a span still has to read as one string.
        let doc = try XMLLite.parse(Data("<a>The <span>Middle</span> Bit</a>".utf8))
        #expect(doc.first(tag: "a")?.text == "The Middle Bit")
    }
}

@MainActor
struct EPUBAnnotationTests {

    static func library() throws -> (EPUBLibrary, EPUBRecord, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "epub-annot-\(UUID().uuidString)")
        let library = EPUBLibrary(directory: dir)
        let record = try library.import(data: try EPUBTests.fixture("sample-epub3"), suggestedName: "b.epub")
        return (library, record, dir)
    }

    // MARK: - Search

    @Test("search finds a phrase across chapters, with context")
    func searchFindsMatches() throws {
        let book = try EPUBPackage(data: try EPUBTests.fixture("sample-epub3"))
        let (results, truncated) = book.search("quick brown fox")

        #expect(results.count == 3, "the phrase is in all three chapters")
        #expect(!truncated)
        #expect(results.map(\.chapter) == [0, 1, 2])
        #expect(results[0].snippet.contains("quick brown fox"))
        #expect(results[0].chapterTitle == "The Beginning")
    }

    @Test("search ignores case and accents but not the markup")
    func searchIsForgivingButNotOfTags() throws {
        let book = try EPUBPackage(data: try EPUBTests.fixture("sample-epub3"))
        #expect(!book.search("QUICK BROWN").results.isEmpty)
        // Searching the stripped text, not the HTML — otherwise every hit for a
        // word like "style" would land inside an attribute.
        #expect(book.search("xhtml").results.isEmpty)
        #expect(book.search("margin").results.isEmpty)
    }

    @Test("a one-character query is refused rather than matching everything")
    func searchNeedsTwoCharacters() throws {
        // It would match thousands of times in a novel; the results are noise
        // and building the list stalls the app.
        let book = try EPUBPackage(data: try EPUBTests.fixture("sample-epub3"))
        #expect(book.search("e").results.isEmpty)
        #expect(book.search(" ").results.isEmpty)
    }

    @Test("an offset points at the match in the same space highlights use")
    func searchOffsetsAreUsable() throws {
        let book = try EPUBPackage(data: try EPUBTests.fixture("sample-epub3"))
        let hit = try #require(book.search("lazy dog").results.first)
        let text = try book.plainText(forChapter: hit.chapter)
        let start = text.index(text.startIndex, offsetBy: hit.offset)
        let end = text.index(start, offsetBy: "lazy dog".count)
        #expect(String(text[start..<end]).lowercased() == "lazy dog")
    }

    // MARK: - Bookmarks

    @Test("bookmarking the same spot twice removes it")
    func bookmarkToggles() throws {
        let (library, record, dir) = try Self.library()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(library.toggleBookmark(recordID: record.id, chapter: 1, progress: 0.5,
                                       label: "The Middle", snippet: "some words"))
        #expect(library.record(id: record.id)?.bookmarks.count == 1)
        #expect(library.isBookmarked(recordID: record.id, chapter: 1, progress: 0.5))

        // Same place — a ribbon toggles rather than stacking.
        #expect(!library.toggleBookmark(recordID: record.id, chapter: 1, progress: 0.505,
                                        label: "The Middle", snippet: ""))
        #expect(library.record(id: record.id)?.bookmarks.isEmpty == true)
    }

    @Test("bookmarks are listed in reading order, not the order you made them")
    func bookmarksSorted() throws {
        let (library, record, dir) = try Self.library()
        defer { try? FileManager.default.removeItem(at: dir) }

        library.toggleBookmark(recordID: record.id, chapter: 2, progress: 0.1, label: "c", snippet: "")
        library.toggleBookmark(recordID: record.id, chapter: 0, progress: 0.8, label: "a", snippet: "")
        library.toggleBookmark(recordID: record.id, chapter: 0, progress: 0.2, label: "b", snippet: "")

        let marks = try #require(library.record(id: record.id)?.bookmarks)
        #expect(marks.map { "\($0.chapter)-\($0.progress)" } == ["0-0.2", "0-0.8", "2-0.1"])
    }

    // MARK: - Highlights

    @Test("a highlight stores offsets, so it survives a font-size change")
    func highlightStoresOffsets() throws {
        // Pixels and DOM paths both move when the text reflows; character
        // offsets into the chapter don't.
        let (library, record, dir) = try Self.library()
        defer { try? FileManager.default.removeItem(at: dir) }

        let made = try #require(library.addHighlight(
            recordID: record.id, chapter: 0, start: 10, end: 25, text: "quick brown fox"
        ))
        #expect(made.start == 10 && made.end == 25)

        let reopened = EPUBLibrary(directory: dir)
        let restored = try #require(reopened.record(id: record.id)?.highlights.first)
        #expect(restored.start == 10)
        #expect(restored.end == 25)
        #expect(restored.text == "quick brown fox")
    }

    @Test("a backwards or empty range is refused")
    func highlightRangeMustBeReal() throws {
        let (library, record, dir) = try Self.library()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(library.addHighlight(recordID: record.id, chapter: 0, start: 40, end: 40, text: "") == nil)
        #expect(library.addHighlight(recordID: record.id, chapter: 0, start: 40, end: 10, text: "x") == nil)
        #expect(library.record(id: record.id)?.highlights.isEmpty == true)
    }

    @Test("highlights come back per chapter, in order")
    func highlightsPerChapter() throws {
        let (library, record, dir) = try Self.library()
        defer { try? FileManager.default.removeItem(at: dir) }

        library.addHighlight(recordID: record.id, chapter: 1, start: 50, end: 60, text: "b")
        library.addHighlight(recordID: record.id, chapter: 0, start: 5, end: 9, text: "a")
        library.addHighlight(recordID: record.id, chapter: 1, start: 10, end: 20, text: "c")

        #expect(library.highlights(recordID: record.id, chapter: 0).count == 1)
        let second = library.highlights(recordID: record.id, chapter: 1)
        #expect(second.map(\.start) == [10, 50])
    }

    @Test("a highlight saved before offsets existed still decodes")
    func oldHighlightsSurvive() throws {
        // The first version of the record had only `text`. Decoding must not
        // throw those away on upgrade.
        let json = #"""
        [{"id":"h1","chapter":0,"text":"an old highlight","addedAt":"2026-01-01T00:00:00.000Z"}]
        """#
        let decoded = try JSONDecoder().decode([EPUBRecord.Highlight].self, from: Data(json.utf8))
        #expect(decoded.first?.text == "an old highlight")
        #expect(decoded.first?.start == 0)
    }
}

/// Chapter text is the coordinate space every stored offset is measured in, so
/// what counts as "the chapter's text" has to match what the reader renders.
struct ChapterTextTests {

    @Test("nothing from <head> reaches the text")
    func headIsNotProse() throws {
        // The fixture's head spans two lines, which is what a `.`-based regex
        // silently fails to match — the <title> then leaks in and shifts every
        // offset in the chapter by its length.
        let book = try EPUBPackage(data: try EPUBTests.fixture("sample-epub3"))
        let text = try book.plainText(forChapter: 2)

        #expect(text.hasPrefix("Chapter 3 The quick brown fox"))
        #expect(!text.contains("Chapter 3 Chapter 3"), "the <title> leaked in")
    }

    @Test("a multi-line style or script block is not counted as prose")
    func multiLineBlocksStripped() {
        let html = """
        <html><head>
        <title>Not prose</title>
        <style>
          p { margin: 1em 0 }
          .drop-cap { float: left }
        </style>
        </head><body>
        <p>Real words.</p>
        <script>
          var tracker = 1;
        </script>
        </body></html>
        """
        #expect(XMLLite.strippingTags(html) == "Real words.")
    }

    @Test("text and rendered markup are measured over the same characters")
    func offsetsAgreeWithWhatIsRendered() throws {
        // A highlight is made from a selection in the rendered body and stored
        // as an offset into this string. If the two disagree by even one
        // character, reopening the book paints the highlight in the wrong place.
        let book = try EPUBPackage(data: try EPUBTests.fixture("sample-epub3"))
        for index in book.spine.indices {
            let rendered = XMLLite.strippingTags(XMLLite.bodyContents(of: try book.html(forChapter: index)))
            #expect(try book.plainText(forChapter: index) == rendered)
        }
    }

    @Test("a fragment with no body tag is still readable")
    func bodylessFragment() {
        // Plenty of books ship chapter fragments without a full document.
        #expect(XMLLite.strippingTags("<p>Just a fragment.</p>") == "Just a fragment.")
        #expect(XMLLite.bodyContents(of: "<p>x</p>") == "<p>x</p>")
    }
}
