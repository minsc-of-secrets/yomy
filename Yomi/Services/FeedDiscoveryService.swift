import Foundation

enum FeedDiscoveryError: LocalizedError {
    /// The page loaded fine, but no feed could be found for it.
    case notFound
    /// The page itself could not be reached (offline, DNS failure, timeout).
    case pageUnreachable

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No RSS feed found for this domain."
        case .pageUnreachable:
            return "Could not reach this domain."
        }
    }
}

struct DiscoveredFeed {
    let url: String
    let parsed: ParsedFeed
}

// Attempts to discover a feed from a regular web page, either by parsing
// <link rel="alternate" ...> tags in the page's HTML, or by probing well-known
// feed paths (e.g. /feed, /rss.xml) if no such tag is found or it doesn't validate.
actor FeedDiscoveryService {
    static let shared = FeedDiscoveryService()

    private static let candidatePaths = [
        "/feed",
        "/rss",
        "/rss.xml",
        "/atom.xml",
        "/index.xml",
        "/feed.xml"
    ]

    // Matches <link ...> tags with rel="alternate" and type="application/rss+xml" or
    // "application/atom+xml", attributes in any order, case-insensitive.
    private static let alternateLinkRegex = try! NSRegularExpression(
        pattern: #"(?i)<link\b[^>]*>"#
    )
    private static let relAlternateRegex = try! NSRegularExpression(
        pattern: #"(?i)\brel=["']alternate["']"#
    )
    private static let feedTypeRegex = try! NSRegularExpression(
        pattern: #"(?i)\btype=["'](?:application/rss\+xml|application/atom\+xml)["']"#
    )
    private static let hrefRegex = try! NSRegularExpression(
        pattern: #"(?i)\bhref=["']([^"']+)["']"#
    )

    private enum PageFetchResult {
        /// Body was fetched and decoded.
        case html(String)
        /// The host answered, but with an error status or an undecodable body.
        /// Probing well-known paths is still worthwhile — some sites block bots on
        /// the HTML page while serving the feed itself.
        case httpError
        /// No response at all: offline, DNS failure, timeout.
        case unreachable
    }

    /// Returns the discovered feed *along with* its parsed contents, so the caller
    /// doesn't have to download and parse the same feed a second time.
    func discoverFeed(from pageURL: URL) async throws -> DiscoveredFeed {
        let page = await fetchPage(from: pageURL)

        // If the host never answered, probing paths on that same host is futile.
        if case .unreachable = page {
            throw FeedDiscoveryError.pageUnreachable
        }

        if case .html(let html) = page,
           let href = alternateLinkHref(in: html),
           let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL,
           let parsed = try? await RSSFetcher.shared.fetch(url: resolved.absoluteString) {
            return DiscoveredFeed(url: resolved.absoluteString, parsed: parsed)
        }

        for path in Self.candidatePaths {
            guard let candidateURL = URL(string: path, relativeTo: pageURL)?.absoluteURL else { continue }
            if let parsed = try? await RSSFetcher.shared.fetch(url: candidateURL.absoluteString) {
                return DiscoveredFeed(url: candidateURL.absoluteString, parsed: parsed)
            }
        }

        throw FeedDiscoveryError.notFound
    }

    private func fetchPage(from pageURL: URL) async -> PageFetchResult {
        var request = URLRequest(url: pageURL, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (compatible; Yomi/1.0; +https://github.com/minsc-of-secrets/yomy)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            return .httpError
        }

        // <link> tags live in <head>, so the first chunk is enough. Truncating can
        // split a multi-byte character, hence the isoLatin1 fallback — ASCII tag
        // syntax still parses correctly either way.
        let chunk = data.prefix(64 * 1024)
        guard let html = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1) else {
            return .httpError
        }
        return .html(html)
    }

    private func alternateLinkHref(in html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        let linkTags = Self.alternateLinkRegex.matches(in: html, range: range)

        for match in linkTags {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let tagFullRange = NSRange(tag.startIndex..., in: tag)

            guard Self.relAlternateRegex.firstMatch(in: tag, range: tagFullRange) != nil,
                  Self.feedTypeRegex.firstMatch(in: tag, range: tagFullRange) != nil else { continue }

            guard let hrefMatch = Self.hrefRegex.firstMatch(in: tag, range: tagFullRange),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: tag) else { continue }

            return String(tag[hrefRange]).decodingHTMLEntities()
        }

        return nil
    }
}

private extension String {
    /// Attribute values are HTML-escaped in the source markup, so query separators
    /// arrive as `&amp;` (e.g. `?feed=rss2&amp;cat=3`). Leaving them encoded would
    /// persist a permanently broken URL into `Feed.url`.
    func decodingHTMLEntities() -> String {
        var s = self
        for entity in ["&#038;", "&#38;", "&#x26;", "&#X26;", "&amp;"] {
            s = s.replacingOccurrences(of: entity, with: "&", options: .caseInsensitive)
        }
        return s
    }
}
