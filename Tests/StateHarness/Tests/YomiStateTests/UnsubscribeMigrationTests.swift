import XCTest
import SwiftData
import Foundation
@testable import YomiState

// Frozen pre-unsubscribe models: create a real existing SQLite store, then open
// it using the production models without a destructive migration or reset.
private enum LegacySubscriptionSchema {


    @Model
    final class Feed {
        var id: UUID
        var url: String
        var title: String
        var siteURL: String
        var category: String
        var fetchedAt: Date?
        var createdAt: Date

        @Relationship(deleteRule: .cascade, inverse: \Article.feed)
        var articles: [Article]

        init(url: String, title: String, siteURL: String = "", category: String = "General") {
            self.id = UUID()
            self.url = url
            self.title = title
            self.siteURL = siteURL
            self.category = category
            self.createdAt = Date()
            self.articles = []
        }

        var unreadCount: Int {
            articles.filter { !$0.isRead }.count
        }
    }


    @Model
    final class Article {
        var id: UUID
        var guid: String
        var url: String
        var title: String
        var summary: String
        var imageURL: String?
        var author: String
        var publishedAt: Date
        var isRead: Bool
        var isSaved: Bool
        var savedAt: Date?
        var createdAt: Date

        var feed: Feed?

        init(
            guid: String,
            url: String,
            title: String,
            summary: String = "",
            imageURL: String? = nil,
            author: String = "",
            publishedAt: Date,
            feed: Feed? = nil
        ) {
            self.id = UUID()
            self.guid = guid
            self.url = url
            self.title = title
            self.summary = summary
            self.imageURL = imageURL
            self.author = author
            self.publishedAt = publishedAt
            self.isRead = false
            self.isSaved = false
            self.savedAt = nil
            self.createdAt = Date()
            self.feed = feed
        }
    }


    @Model
    final class Category {
        var name: String = ""
        var sortOrder: Int = 0
        var iconName: String = "tag"

        init(name: String, sortOrder: Int = 0, iconName: String = "tag") {
            self.name = name
            self.sortOrder = sortOrder
            self.iconName = iconName
        }
    }

}


final class UnsubscribeMigrationTests: XCTestCase {
    @MainActor
    private func createLegacyStore(at url: URL) throws -> UUID {
        let schema = Schema([LegacySubscriptionSchema.Feed.self, LegacySubscriptionSchema.Article.self, LegacySubscriptionSchema.Category.self])
        let config = ModelConfiguration(schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = container.mainContext
        let feed = LegacySubscriptionSchema.Feed(url: "https://example.com/legacy", title: "Legacy source")
        context.insert(feed)
        let article = LegacySubscriptionSchema.Article(guid: "legacy", url: "https://example.com/legacy-article", title: "Legacy saved", publishedAt: Date(), feed: feed)
        article.isSaved = true
        article.isRead = true
        article.savedAt = Date(timeIntervalSince1970: 123456)
        context.insert(article)
        try context.save()
        return article.id
    }

    @MainActor
    func testExistingStoreMigratesWithSubscriptionEnabledAndSavedStateIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store")
        let savedID = try createLegacyStore(at: url)
        let schema = Schema([Feed.self, Article.self, Category.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let feed = try XCTUnwrap(context.fetch(FetchDescriptor<Feed>()).first)
        XCTAssertTrue(feed.isSubscribed)
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<Article>()).first)
        XCTAssertEqual(saved.id, savedID)
        XCTAssertTrue(saved.isSaved)
        XCTAssertTrue(saved.isRead)
        XCTAssertEqual(saved.savedAt, Date(timeIntervalSince1970: 123456))
        XCTAssertEqual(saved.feed?.title, "Legacy source")
        try FeedService().unsubscribe(feed, keepSavedArticles: true, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Article>()), 1)
        XCTAssertFalse(feed.isSubscribed)
        // The production unsubscribe schedules a widget query after 500ms. Let it
        // finish before this test removes the temporary on-disk store.
        try await Task.sleep(for: .seconds(1))
        withExtendedLifetime(container) {}
    }
}
