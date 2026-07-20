import Foundation

enum FeedDiscoveryError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "No RSS feed found for this domain."
        }
    }
}

// Attempts to discover a feed URL from a regular web page, either by parsing
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

    func discoverFeedURL(from pageURL: URL) async throws -> String {
        if let linkHref = await fetchAlternateLinkHref(from: pageURL),
           let resolved = URL(string: linkHref, relativeTo: pageURL)?.absoluteURL {
            if let validated = try? await RSSFetcher.shared.fetch(url: resolved.absoluteString) {
                _ = validated
                return resolved.absoluteString
            }
        }

        for path in Self.candidatePaths {
            guard let candidateURL = URL(string: path, relativeTo: pageURL)?.absoluteURL else { continue }
            if (try? await RSSFetcher.shared.fetch(url: candidateURL.absoluteString)) != nil {
                return candidateURL.absoluteString
            }
        }

        throw FeedDiscoveryError.notFound
    }

    private func fetchAlternateLinkHref(from pageURL: URL) async -> String? {
        var request = URLRequest(url: pageURL, timeoutInterval: 10)
        request.setValue(
            "Mozilla/5.0 (compatible; Yomi/1.0; +https://github.com/minsc-of-secrets/Yomi)",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode < 400 else { return nil }

        let chunk = data.prefix(64 * 1024)
        guard let html = String(data: chunk, encoding: .utf8) ?? String(data: chunk, encoding: .isoLatin1) else {
            return nil
        }

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

            return String(tag[hrefRange])
        }

        return nil
    }
}
