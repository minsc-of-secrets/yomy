import XCTest
import SwiftData
@testable import YomiState

final class CategoryMutationTests: XCTestCase {
    private enum TestError: Error { case saveFailed }

    @MainActor
    private func fixture() throws -> (ModelContainer, ModelContext, Category, Feed, Feed, Article) {
        let container = try ModelContainer(for: Feed.self, Article.self, Category.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.autosaveEnabled = false
        let category = Category(name: "Tech")
        let feed = Feed(url: "https://example.com/rss", title: "Tech", category: "Tech")
        let other = Feed(url: "https://example.com/other", title: "Other", category: "Other")
        let article = Article(guid: "1", url: "https://example.com/1", title: "Saved", publishedAt: Date(), feed: feed)
        article.isSaved = true
        context.insert(category)
        context.insert(feed)
        context.insert(other)
        context.insert(article)
        try context.save()
        return (container, context, category, feed, other, article)
    }

    @MainActor
    func testRenamePersistsMembershipAndArticlesTogether() throws {
        let (container, context, category, feed, other, article) = try fixture()
        let second = Feed(url: "https://example.com/second", title: "Second", category: "Tech")
        context.insert(second)
        try context.save()
        try CategoryService().save(category: category, name: " \nTechnology\n ", iconName: "star", context: context)
        XCTAssertEqual(feed.category, "Technology")
        XCTAssertEqual(second.category, "Technology")
        XCTAssertEqual(other.category, "Other")
        XCTAssertTrue(article.isSaved)
        let fresh = ModelContext(container)
        let storedCategories = try fresh.fetch(FetchDescriptor<Category>())
        XCTAssertEqual(storedCategories.first?.name, "Technology")
        XCTAssertEqual(storedCategories.first?.iconName, "star")
        let storedArticles = try fresh.fetch(FetchDescriptor<Article>())
        XCTAssertEqual(storedArticles.filter { $0.feed?.category == storedCategories.first?.name }.count, 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Feed>()).filter { $0.category == "Technology" }.count, 2)
    }

    @MainActor
    func testEmptyAndDuplicateNamesDoNotChangeAnything() throws {
        let (container, context, category, feed, _, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        context.insert(Category(name: "Other"))
        try context.save()
        for name in [" \n\t", " Other "] {
            XCTAssertThrowsError(try CategoryService().save(category: category, name: name, iconName: "star", context: context))
            XCTAssertEqual(category.name, "Tech")
            XCTAssertEqual(category.iconName, "tag")
            XCTAssertEqual(feed.category, "Tech")
        }
        XCTAssertThrowsError(try CategoryService().save(category: nil, name: "Tech", iconName: "tag", context: context))
    }

    @MainActor
    func testSameNameIconEditAndCaseOnlyRename() throws {
        let (container, context, category, feed, _, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        try CategoryService().save(category: category, name: "Tech", iconName: "star", context: context)
        XCTAssertEqual(category.iconName, "star")
        try CategoryService().save(category: category, name: "tech", iconName: "star", context: context)
        XCTAssertEqual(feed.category, "tech")
    }

    @MainActor
    func testFailedRenameRestoresOnlyCategoryChangesAndCanRetry() throws {
        let (container, context, category, feed, _, article) = try fixture()
        article.isRead = true // An unrelated deferred article edit must not be rolled back.
        let failing = CategoryService(persist: { _ in throw TestError.saveFailed })
        XCTAssertThrowsError(try failing.save(category: category, name: "New", iconName: "star", context: context))
        XCTAssertEqual(category.name, "Tech")
        XCTAssertEqual(category.iconName, "tag")
        XCTAssertEqual(feed.category, "Tech")
        XCTAssertTrue(article.isRead)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Category>()).first?.name, "Tech")
        try CategoryService().save(category: category, name: "New", iconName: "star", context: context)
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<Feed>()).first(where: { $0.id == feed.id })?.category, "New")
    }

    @MainActor
    func testFailedCreationDoesNotLeaveCategoryBehind() throws {
        let (container, context, _, _, _, _) = try fixture()
        let failing = CategoryService(persist: { _ in throw TestError.saveFailed })
        XCTAssertThrowsError(try failing.save(category: nil, name: "New", iconName: "tag", context: context))
        try context.save()
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Category>()), 1)
    }

    @MainActor
    func testDeleteMovesFeedsToNoneWithoutDeletingArticles() throws {
        let (container, context, category, feed, other, article) = try fixture()
        try CategoryService().delete([category], context: context)
        XCTAssertEqual(feed.category, "")
        XCTAssertEqual(other.category, "Other")
        XCTAssertTrue(article.isSaved)
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Category>()), 0)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Article>()), 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Feed>()).first(where: { $0.id == feed.id })?.category, "")
    }

    @MainActor
    func testLegacyDuplicateNamesCannotStealMembership() throws {
        let (container, context, category, feed, _, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        let duplicate = Category(name: "Tech")
        context.insert(duplicate)
        try context.save()
        XCTAssertThrowsError(try CategoryService().save(category: category, name: "New", iconName: "tag", context: context))
        try CategoryService().delete([duplicate], context: context)
        XCTAssertEqual(feed.category, "Tech")
        try CategoryService().save(category: category, name: "New", iconName: "tag", context: context)
        XCTAssertEqual(feed.category, "New")
    }

    @MainActor
    func testFailedDeletionRestoresCategoryAndFeeds() throws {
        let (container, context, category, feed, _, article) = try fixture()
        article.isRead = true
        let failing = CategoryService(persist: { _ in throw TestError.saveFailed })
        XCTAssertThrowsError(try failing.delete([category], context: context))
        XCTAssertEqual(feed.category, "Tech")
        XCTAssertTrue(article.isRead)
        // A later save must not accidentally commit the failed delete.
        try context.save()
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<Category>()), 1)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<Feed>()).first(where: { $0.id == feed.id })?.category, "Tech")
    }
    @MainActor
    func testCanonicalUnicodeDuplicateAndStaleEditorAreRejected() throws {
        let (container, context, category, feed, _, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        context.insert(Category(name: "Caf\u{00E9}"))
        try context.save()
        XCTAssertThrowsError(try CategoryService().save(category: category, name: "Cafe\u{0301}", iconName: "star", context: context))
        XCTAssertEqual(feed.category, "Tech")
        context.delete(category)
        XCTAssertThrowsError(try CategoryService().save(category: category, name: "New", iconName: "star", context: context))
        XCTAssertEqual(feed.category, "Tech")
    }

    @MainActor
    func testLegacyEmptyCategoryDoesNotCaptureUncategorizedFeeds() throws {
        let (container, context, category, feed, _, _) = try fixture()
        defer { withExtendedLifetime(container) {} }
        category.name = ""
        feed.category = ""
        try context.save()
        try CategoryService().save(category: category, name: "New", iconName: "tag", context: context)
        XCTAssertEqual(feed.category, "", "Empty membership is reserved for None")
    }

}
