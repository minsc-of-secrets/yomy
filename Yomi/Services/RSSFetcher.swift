import Foundation
import FeedKit

struct ParsedFeed {
    var title: String
    var siteURL: String
    var articles: [ParsedArticle]
}

struct ParsedArticle {
    var guid: String
    var url: String
    var title: String
    var summary: String
    var imageURL: String?
    var author: String
    var publishedAt: Date
}

actor RSSFetcher {
    static let shared = RSSFetcher()

    func fetch(url: String) async throws -> ParsedFeed {
        guard let feedURL = URL(string: url) else {
            throw URLError(.badURL)
        }

        let parser = FeedParser(URL: feedURL)
        let result = await withCheckedContinuation { continuation in
            parser.parseAsync { result in
                continuation.resume(returning: result)
            }
        }

        switch result {
        case .success(let feed):
            return try parseFeed(feed, sourceURL: url)
        case .failure(let error):
            throw error
        }
    }

    func fetchAll(feeds: [Feed]) async {
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds {
                group.addTask {
                    _ = try? await self.fetch(url: feed.url)
                }
            }
        }
    }

    func parseFeed(_ feed: FeedKit.Feed, sourceURL: String) throws -> ParsedFeed {
        switch feed {
        case .rss(let rss):
            return parseRSS(rss)
        case .atom(let atom):
            return parseAtom(atom)
        case .json(let json):
            return parseJSON(json)
        }
    }

    private func parseRSS(_ feed: RSSFeed) -> ParsedFeed {
        let articles = (feed.items ?? []).compactMap { item -> ParsedArticle? in
            guard let title = item.title, let link = item.link else { return nil }
            let guid = item.guid?.value ?? link
            let imageURL = extractImageURL(from: item)
            var summary = item.description?.strippingHTML() ?? ""
            if summary.isEmpty { summary = item.content?.contentEncoded?.strippingHTML() ?? "" }
            summary = summary.truncated(to: 300)
            return ParsedArticle(
                guid: guid,
                url: link,
                title: title,
                summary: summary,
                imageURL: imageURL,
                author: item.author ?? item.dublinCore?.dcCreator ?? "",
                publishedAt: item.pubDate ?? Date()
            )
        }
        return ParsedFeed(
            title: feed.title ?? "",
            siteURL: feed.link ?? "",
            articles: articles
        )
    }

    private func parseAtom(_ feed: AtomFeed) -> ParsedFeed {
        let articles = (feed.entries ?? []).compactMap { entry -> ParsedArticle? in
            guard let title = entry.title else { return nil }
            let link = preferredAtomLink((entry.links ?? []).map {
                ($0.attributes?.href, $0.attributes?.rel, $0.attributes?.type)
            }) ?? ""
            guard !link.isEmpty else { return nil }
            let guid = entry.id ?? link
            let summary = entry.summary?.value ?? entry.content?.value ?? ""
            return ParsedArticle(
                guid: guid,
                url: link,
                title: title,
                summary: summary.strippingHTML(),
                imageURL: nil,
                author: entry.authors?.first?.name ?? "",
                publishedAt: entry.published ?? entry.updated ?? Date()
            )
        }
        return ParsedFeed(
            title: feed.title ?? "",
            siteURL: preferredAtomLink((feed.links ?? []).map {
                ($0.attributes?.href, $0.attributes?.rel, $0.attributes?.type)
            }) ?? "",
            articles: articles
        )
    }

    /// Atom links are unordered. Missing rel means alternate (RFC 4287 §4.2.7.2).
    /// Prefer browser-readable alternates without ever opening self/enclosure URLs.
    private func preferredAtomLink(_ links: [(href: String?, rel: String?, type: String?)]) -> String? {
        let alternates = links.filter {
            let relation = $0.rel ?? "alternate"
            return (relation == "alternate" || relation == "http://www.iana.org/assignments/relation/alternate")
                && !($0.href?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        let html = alternates.first {
            let type = $0.type?.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return type == "text/html" || type == "application/xhtml+xml"
        }
        return (html ?? alternates.first { $0.type == nil } ?? alternates.first)?.href
    }

    private func parseJSON(_ feed: JSONFeed) -> ParsedFeed {
        let articles = (feed.items ?? []).compactMap { item -> ParsedArticle? in
            guard let title = item.title, let link = item.url else { return nil }
            return ParsedArticle(
                guid: item.id ?? link,
                url: link,
                title: title,
                summary: item.summary ?? item.contentText ?? "",
                imageURL: item.image,
                author: item.author?.name ?? "",
                publishedAt: item.datePublished ?? Date()
            )
        }
        return ParsedFeed(
            title: feed.title ?? "",
            siteURL: feed.homePageURL ?? "",
            articles: articles
        )
    }

    private func extractImageURL(from item: RSSFeedItem) -> String? {
        // 1. media:thumbnail (Zenn, YouTube など)
        if let thumbnail = item.media?.mediaThumbnails?.first?.attributes?.url {
            return thumbnail
        }
        // 2. media:content — type が image/* OR medium が "image"
        if let content = item.media?.mediaContents?.first(where: {
            let attrs = $0.attributes
            return attrs?.medium == "image" || (attrs?.type?.hasPrefix("image/") ?? false)
        })?.attributes?.url {
            return content
        }
        // 3. Enclosure — type が image/* OR URL が画像パターン
        //    (Zenn は type="false" だが URL が Cloudinary 画像のケースに対応)
        if let enc = item.enclosure?.attributes, let url = enc.url {
            let looksLikeImage = (enc.type?.hasPrefix("image/") ?? false)
                || url.contains("/image/")
                || url.hasSuffix(".jpg")
                || url.hasSuffix(".jpeg")
                || url.hasSuffix(".png")
                || url.hasSuffix(".webp")
            if looksLikeImage { return url }
        }
        // 4. content:encoded → description の順で最初の <img> を探す
        for html in [item.content?.contentEncoded, item.description].compactMap({ $0 }) {
            if let url = extractFirstImageFromHTML(html) { return url }
        }
        return nil
    }

    private static let imgSrcRegex = try! NSRegularExpression(
        pattern: #"(?i)<img[^>]+src=["']([^"']+)["']"#
    )

    private func extractFirstImageFromHTML(_ html: String) -> String? {
        let range = NSRange(html.startIndex..., in: html)
        guard let match = Self.imgSrcRegex.firstMatch(in: html, range: range),
              let captureRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[captureRange])
    }
}

private extension String {
    func strippingHTML() -> String {
        var s = self
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    func truncated(to maxLength: Int) -> String {
        let chars = Array(self.unicodeScalars)
        guard chars.count > maxLength else { return self }
        return String(String.UnicodeScalarView(chars.prefix(maxLength))) + "…"
    }
}
