import XCTest
@testable import YomiParsing

final class OPMLManagerTests: XCTestCase {
    private func parse(_ body: String) throws -> [OPMLFeed] {
        try OPMLManager.shared.importOPML(data: Data("<opml version=\"2.0\"><body>\(body)</body></opml>".utf8))
    }

    func testRestoresParentThenDefaultCategory() throws {
        let feeds = try parse("""
        <outline text="Tech">
          <outline text="Swift"><outline text="A" xmlUrl="https://example.com/a.xml"/></outline>
          <outline text="B" xmlUrl="https://example.com/b.xml"/>
        </outline>
        <outline text="C" xmlUrl="https://example.com/c.xml"/>
        """)
        XCTAssertEqual(feeds.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(feeds.map(\.category), ["Swift", "Tech", "General"])
    }

    func testEmptyCategoryDoesNotLeakIntoFollowingFeeds() throws {
        let feeds = try parse("""
        <outline text="Unused"/>
        <outline text="Root" xmlUrl="https://example.com/root"/>
        <outline text="News"><outline text="First" xmlUrl="https://example.com/1"/><outline text="Second" xmlUrl="https://example.com/2"/></outline>
        <outline text="Other"><outline text="Third" xmlUrl="https://example.com/3"/></outline>
        """)
        XCTAssertEqual(feeds.map(\.category), ["General", "News", "News", "Other"])
    }

    func testExportImportRoundTripPreservesEscapedValues() throws {
        let original = [
            Feed(url: "https://example.com/rss?a=1&b=2", title: "A & B", siteURL: "https://example.com", category: "Tech <News>"),
            Feed(url: "https://example.com/other", title: "\"Other\"", category: "")
        ]
        let xml = OPMLManager.shared.exportOPML(feeds: original)
        let result = try OPMLManager.shared.importOPML(data: Data(xml.utf8))
        for feed in original {
            let imported = try XCTUnwrap(result.first { $0.xmlURL == feed.url })
            XCTAssertEqual(imported.title, feed.title)
            XCTAssertEqual(imported.htmlURL, feed.siteURL)
            XCTAssertEqual(imported.category, feed.category)
        }
    }

    func testMalformedXMLThrowsInsteadOfReturningPartialImport() {
        XCTAssertThrowsError(try OPMLManager.shared.importOPML(data: Data("<opml><body><outline text=\"Broken\">".utf8)))
    }

    func testSeparateImportsDoNotShareCategoryState() throws {
        _ = try parse("<outline text=\"Old\"><outline xmlUrl=\"https://example.com/old\"/></outline>")
        let result = try parse("<outline xmlUrl=\"https://example.com/new\"/>")
        XCTAssertEqual(result.first?.category, "General")
    }
}
