import XCTest
import SwiftData
@testable import YomiState

final class ArticleStateTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (ModelContainer, ModelContext, Feed, Article) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Feed.self, Article.self, Category.self, configurations: config)
        let context = container.mainContext
        let feed = Feed(url: "https://example.com/rss", title: "Example")
        context.insert(feed)
        let article = Article(guid: "1", url: "https://example.com/article", title: "Article", publishedAt: Date(), feed: feed)
        context.insert(article)
        try context.save()
        return (container, context, feed, article)
    }

    // The two competing actions have no suspension between them. The earlier
    // Task cannot persist before the newer operation. This wait lets its fixed
    // 300ms production delay expire; assertions concern state, not timing/performance.
    private func settle() async throws {
        try await Task.sleep(for: .seconds(1))
    }

    @MainActor
    func testMarkAllReadSupersedesPendingUnread() async throws {
        let (container, context, feed, article) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let service = FeedService()
        article.isRead = true
        service.setRead(article: article, isRead: false, context: context)
        try service.markAllRead(feed: feed, context: context)
        try await settle()
        XCTAssertTrue(article.isRead, "An older delayed unread action must not undo Mark All Read")
        let persisted = try ModelContext(container).fetch(FetchDescriptor<Article>())
        XCTAssertTrue(try XCTUnwrap(persisted.first).isRead)
    }

    @MainActor
    func testRapidToggleKeepsLatestIntentAcrossSiblings() async throws {
        let (container, context, _, article) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let sibling = Article(guid: "2", url: article.url, title: "Sibling", publishedAt: Date())
        context.insert(sibling)
        try context.save()
        let service = FeedService()
        service.setRead(article: article, isRead: true, context: context)
        service.setRead(article: sibling, isRead: false, context: context)
        try await settle()
        XCTAssertFalse(article.isRead)
        XCTAssertFalse(sibling.isRead)
    }

    @MainActor
    func testDeletingFeedBeforeDeferredWritesDoesNotResurrectArticles() async throws {
        let (container, context, feed, article) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let service = FeedService()
        service.setSaved(article: article, isSaved: true, context: context)
        service.setRead(article: article, isRead: true, context: context)
        try service.deleteFeed(feed, context: context)
        try await settle()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Article>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Feed>()), 0)
    }

    @MainActor
    func testEmptyURLsHaveIndependentPendingWrites() async throws {
        let (container, context, _, first) = try fixture()
        defer { withExtendedLifetime(container) {} }
        first.url = ""
        let second = Article(guid: "2", url: "", title: "Second", publishedAt: Date())
        context.insert(second)
        try context.save()
        let service = FeedService()
        service.setRead(article: first, isRead: true, context: context)
        service.setRead(article: second, isRead: false, context: context)
        try await settle()
        XCTAssertTrue(first.isRead)
        XCTAssertFalse(second.isRead)
    }

    @MainActor
    func testSaveThenUnsaveKeepsLatestState() async throws {
        let (container, context, _, article) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let service = FeedService()
        service.setSaved(article: article, isSaved: true, context: context)
        service.setSaved(article: article, isSaved: false, context: context)
        try await settle()
        XCTAssertFalse(article.isSaved)
        XCTAssertNil(article.savedAt)
    }

    @MainActor
    func testDeletingSiblingFeedDoesNotCancelSurvivingReadIntent() async throws {
        let (container, context, _, article) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let deletedFeed = Feed(url: "https://example.com/other-rss", title: "Other")
        context.insert(deletedFeed)
        let deletedSibling = Article(guid: "2", url: article.url, title: "Deleted", publishedAt: Date(), feed: deletedFeed)
        let survivingSibling = Article(guid: "3", url: article.url, title: "Survivor", publishedAt: Date())
        context.insert(deletedSibling)
        context.insert(survivingSibling)
        try context.save()
        let service = FeedService()
        service.setRead(article: article, isRead: true, context: context)
        try service.deleteFeed(deletedFeed, context: context)
        try await settle()
        XCTAssertTrue(article.isRead)
        XCTAssertTrue(survivingSibling.isRead)
    }

    @MainActor
    func testLatestSaveIntentWinsAcrossSiblings() async throws {
        let (container, context, _, article) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let sibling = Article(guid: "2", url: article.url, title: "Sibling", publishedAt: Date())
        context.insert(sibling)
        try context.save()
        let service = FeedService()
        service.setSaved(article: article, isSaved: true, context: context)
        service.setSaved(article: sibling, isSaved: false, context: context)
        try await settle()
        XCTAssertFalse(article.isSaved)
        XCTAssertFalse(sibling.isSaved)
        XCTAssertNil(article.savedAt)
        XCTAssertNil(sibling.savedAt)
    }


    @MainActor
    func testMarkAllReadCancelsPendingWriteEvenWhenArticleAlreadyAppearsRead() async throws {
        let (container, context, feed, article) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let otherFeed = Feed(url: "https://example.com/other-rss", title: "Other")
        context.insert(otherFeed)
        let sibling = Article(guid: "2", url: article.url, title: "Sibling", publishedAt: Date(), feed: otherFeed)
        context.insert(sibling)
        try context.save()
        let service = FeedService()
        service.setRead(article: article, isRead: true, context: context)
        XCTAssertTrue(article.isRead)
        try service.markAllRead(feed: feed, context: context)
        try await settle()
        XCTAssertTrue(article.isRead)
        // Mark All Read only targets its own feed. If the older task were not
        // cancelled, it would later propagate to this other-feed sibling.
        XCTAssertFalse(sibling.isRead)
    }

}
