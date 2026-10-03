import XCTest
import FeedKit
@testable import YomiParsing

final class RSSFetcherTests: XCTestCase {
    private func parseAtom(links: String, entryLinks: String? = nil) async throws -> ParsedFeed {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Example</title><id>urn:example:feed</id><updated>2026-01-01T00:00:00Z</updated>
          \(links)
          <entry><title>Article</title><id>urn:example:article</id><updated>2026-01-01T00:00:00Z</updated>
            \(entryLinks ?? links)
          </entry>
        </feed>
        """
        let feed = try FeedParser(data: Data(xml.utf8)).parse().get()
        return try await RSSFetcher.shared.parseFeed(feed, sourceURL: "https://example.com/feed.atom")
    }

    func testSelectsHTMLInsteadOfLeadingSelfLink() async throws {
        let feed = try await parseAtom(links: """
        <link rel="self" type="application/atom+xml" href="https://example.com/feed.atom"/>
        <link rel="alternate" type="text/html" href="https://example.com/"/>
        """, entryLinks: """
        <link rel="self" type="application/atom+xml" href="https://example.com/article.atom"/>
        <link rel="alternate" type="text/html" href="https://example.com/article"/>
        """)
        XCTAssertEqual(feed.siteURL, "https://example.com/")
        XCTAssertEqual(feed.articles.first?.url, "https://example.com/article")
    }

    func testOmittedRelationIsAlternate() async throws {
        let feed = try await parseAtom(links: """
        <link rel="enclosure" href="https://example.com/audio.mp3"/>
        <link href="https://example.com/article"/>
        """)
        XCTAssertEqual(feed.siteURL, "https://example.com/article")
        XCTAssertEqual(feed.articles.first?.url, "https://example.com/article")
    }

    func testHTMLBeatsEarlierNonHTMLAndUntypedAlternates() async throws {
        let feed = try await parseAtom(links: """
        <link rel="alternate" type="application/pdf" href="https://example.com/article.pdf"/>
        <link rel="alternate" href="https://example.com/untyped"/>
        <link rel="alternate" type="text/html; charset=utf-8" href="https://example.com/article"/>
        """)
        XCTAssertEqual(feed.articles.first?.url, "https://example.com/article")
    }

    func testXHTMLAndRegisteredRelationURI() async throws {
        let feed = try await parseAtom(links: """
        <link rel="self" href="https://example.com/feed.atom"/>
        <link rel="http://www.iana.org/assignments/relation/alternate" type="application/xhtml+xml" href="https://example.com/article"/>
        """)
        XCTAssertEqual(feed.articles.first?.url, "https://example.com/article")
    }

    func testMissingOrBlankHrefDoesNotHideValidAlternate() async throws {
        let feed = try await parseAtom(links: """
        <link rel="alternate" type="text/html"/>
        <link rel="alternate" type="text/html" href=" "/>
        <link rel="alternate" href="https://example.com/article"/>
        """)
        XCTAssertEqual(feed.articles.first?.url, "https://example.com/article")
    }

    func testSelfAndEnclosureAreNeverUsedAsArticleURLs() async throws {
        let feed = try await parseAtom(links: """
        <link rel="self" href="https://example.com/feed.atom"/>
        <link rel="enclosure" href="https://example.com/audio.mp3"/>
        """)
        XCTAssertTrue(feed.articles.isEmpty)
        XCTAssertEqual(feed.siteURL, "")
    }

    func testRSSStillParses() async throws {
        let xml = """
        <rss version="2.0"><channel><title>Example</title><link>https://example.com/</link><description>Example feed</description>
        <item><title>Article</title><link>https://example.com/article</link><guid>article-1</guid></item>
        </channel></rss>
        """
        let source = try FeedParser(data: Data(xml.utf8)).parse().get()
        let feed = try await RSSFetcher.shared.parseFeed(source, sourceURL: "https://example.com/rss.xml")
        XCTAssertEqual(feed.siteURL, "https://example.com/")
        XCTAssertEqual(feed.articles.first?.url, "https://example.com/article")
        XCTAssertEqual(feed.articles.first?.guid, "article-1")
    }
}
