import Foundation

struct OPMLFeed {
    var title: String
    var xmlURL: String
    var htmlURL: String
    var category: String
}

final class OPMLManager: NSObject {
    static let shared = OPMLManager()

    func exportOPML(feeds: [Feed]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="1.0">
          <head>
            <title>Yomi RSS Feeds</title>
          </head>
          <body>

        """

        let grouped = Dictionary(grouping: feeds.filter(\.isSubscribed), by: \.category)
        for (category, categoryFeeds) in grouped.sorted(by: { $0.key < $1.key }) {
            xml += "    <outline text=\"\(category.xmlEscaped)\" title=\"\(category.xmlEscaped)\">\n"
            for feed in categoryFeeds {
                xml += "      <outline type=\"rss\" text=\"\(feed.title.xmlEscaped)\" title=\"\(feed.title.xmlEscaped)\" xmlUrl=\"\(feed.url.xmlEscaped)\" htmlUrl=\"\(feed.siteURL.xmlEscaped)\"/>\n"
            }
            xml += "    </outline>\n"
        }

        xml += """
          </body>
        </opml>
        """
        return xml
    }

    func importOPML(data: Data) throws -> [OPMLFeed] {
        let parser = OPMLParser(data: data)
        return try parser.parse()
    }
}

private final class OPMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var feeds: [OPMLFeed] = []
    private var currentCategory = "General"
    private var categoryStack: [String] = []
    private var error: Error?

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> [OPMLFeed] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let error { throw error }
        return feeds
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard elementName == "outline" else { return }

        // Every outline (including a feed) owns one stack frame.
        categoryStack.append(currentCategory)
        let xmlURL = attributes["xmlUrl"] ?? attributes["xmlurl"] ?? ""
        if xmlURL.isEmpty {
            currentCategory = attributes["title"] ?? attributes["text"] ?? "General"
        } else {
            feeds.append(OPMLFeed(
                title: attributes["title"] ?? attributes["text"] ?? xmlURL,
                xmlURL: xmlURL,
                htmlURL: attributes["htmlUrl"] ?? attributes["htmlurl"] ?? "",
                category: currentCategory
            ))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == "outline", let parentCategory = categoryStack.popLast() {
            currentCategory = parentCategory
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}

private extension String {
    var xmlEscaped: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
