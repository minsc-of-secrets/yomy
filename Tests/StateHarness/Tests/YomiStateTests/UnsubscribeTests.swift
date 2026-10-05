import XCTest
import SwiftData
@testable import YomiState

final class UnsubscribeTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (ModelContainer, ModelContext, Feed, Article, Article) {
        let container = try ModelContainer(for: Feed.self, Article.self, Category.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let feed = Feed(url: "https://example.com/rss", title: "Original source", siteURL: "https://example.com", category: "Tech")
        context.insert(feed)
        let saved = Article(guid: "saved", url: "https://example.com/saved", title: "Saved", summary: "Full summary", publishedAt: Date(), feed: feed)
        saved.isSaved = true
        saved.savedAt = Date(timeIntervalSince1970: 123456)
        saved.isRead = true
        context.insert(saved)
        let other = Article(guid: "other", url: "https://example.com/other", title: "Other", publishedAt: Date(), feed: feed)
        context.insert(other)
        try context.save()
        return (container, context, feed, saved, other)
    }

    @MainActor
    func testKeepSavedPreservesIdentityMetadataAndStateInFreshContext() throws {
        let (container, context, feed, saved, _) = try fixture()
        let savedID = saved.id
        let sourceID = feed.id
        try FeedService().unsubscribe(feed, keepSavedArticles: true, context: context)
        let reopened = ModelContext(container)
        let articles = try reopened.fetch(FetchDescriptor<Article>())
        XCTAssertEqual(articles.count, 1)
        let retained = try XCTUnwrap(articles.first)
        XCTAssertEqual(retained.id, savedID)
        XCTAssertEqual(retained.summary, "Full summary")
        XCTAssertTrue(retained.isSaved)
        XCTAssertTrue(retained.isRead)
        XCTAssertEqual(retained.savedAt, Date(timeIntervalSince1970: 123456))
        XCTAssertEqual(retained.feed?.id, sourceID)
        XCTAssertEqual(retained.feed?.title, "Original source")
        XCTAssertEqual(retained.feed?.siteURL, "https://example.com")
        XCTAssertEqual(retained.feed?.isSubscribed, false)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Feed>(predicate: #Predicate { $0.isSubscribed })), 0)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Article>(predicate: #Predicate { $0.feed?.isSubscribed == true })), 0)
        XCTAssertFalse(OPMLManager.shared.exportOPML(feeds: [feed]).contains("https://example.com/rss"))
    }

    @MainActor
    func testDeleteAllAndZeroSavedRemoveSourceAndArticles() throws {
        for keep in [false, true] {
            let (container, context, feed, saved, _) = try fixture()
            if keep { saved.isSaved = false; saved.savedAt = nil }
            try FeedService().unsubscribe(feed, keepSavedArticles: keep, context: context)
            let reopened = ModelContext(container)
            XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Feed>()), 0)
            XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Article>()), 0)
        }
    }

    @MainActor
    func testOpeningThenCancellingOnlyReadsData() throws {
        let (container, context, feed, _, _) = try fixture()
        // This is the query used by the shared sheet. Cancel only dismisses it.
        let feedID = feed.id
        let articles = try context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.feed?.id == feedID }))
        XCTAssertEqual(FeedService.dedupByURL(articles.filter(\.isSaved)).count, 1)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Article>()), 2)
        XCTAssertTrue(feed.isSubscribed)
    }

    @MainActor
    func testImmediateSaveThenUnsubscribeRetainsArticleAfterDeferredTasks() async throws {
        let (container, context, feed, _, other) = try fixture()
        let service = FeedService()
        service.setSaved(article: other, isSaved: true, context: context)
        service.setRead(article: other, isRead: true, context: context)
        try service.unsubscribe(feed, keepSavedArticles: true, context: context)
        try await Task.sleep(for: .seconds(1))
        let rows = try ModelContext(container).fetch(FetchDescriptor<Article>())
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.isSaved))
        XCTAssertTrue(rows.allSatisfy(\.isRead))
    }

    @MainActor
    func testUnsubscribeDuringRefreshCannotInsertLateArticles() async throws {
        let (container, context, feed, _, _) = try fixture()
        var resume: CheckedContinuation<ParsedFeed, Never>?
        let service = FeedService(fetchFeed: { _ in
            await withCheckedContinuation { resume = $0 }
        })
        let refresh = Task { try await service.refresh(feed: feed, context: context) }
        while resume == nil { await Task.yield() }
        try service.unsubscribe(feed, keepSavedArticles: true, context: context)
        resume?.resume(returning: parsedFeed())
        try await refresh.value
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Article>()), 1)
        XCTAssertNil(feed.fetchedAt)
        var calls = 0
        let archivedRefresh = FeedService(fetchFeed: { _ in calls += 1; return self.parsedFeed() })
        try await archivedRefresh.refresh(feed: feed, context: context)
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testResubscribeReusesArchivedSourceAndSavedArticle() async throws {
        let (container, context, feed, saved, _) = try fixture()
        let savedID = saved.id
        let savedDate = saved.savedAt
        let service = FeedService(fetchFeed: { _ in self.parsedFeed() })
        try service.unsubscribe(feed, keepSavedArticles: true, context: context)
        let restored = try await service.addFeed(url: feed.url, category: "New category", context: context)
        XCTAssertEqual(restored.id, feed.id)
        XCTAssertTrue(restored.isSubscribed)
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Feed>()), 1)
        let rows = try reopened.fetch(FetchDescriptor<Article>())
        XCTAssertEqual(rows.count, 2)
        let retained = try XCTUnwrap(rows.first { $0.guid == "saved" })
        XCTAssertEqual(retained.id, savedID)
        XCTAssertTrue(retained.isSaved)
        XCTAssertTrue(retained.isRead)
        XCTAssertEqual(retained.savedAt, savedDate)
    }

    @MainActor
    func testCrossFeedPendingSaveAndUnsaveAreAppliedBeforeClassification() async throws {
        for isSaved in [true, false] {
            let (container, context, feed, saved, _) = try fixture()
            let otherFeed = Feed(url: "https://other.example/rss", title: "Other source")
            context.insert(otherFeed)
            let sibling = Article(guid: "sibling", url: saved.url, title: "Sibling", publishedAt: Date(), feed: otherFeed)
            context.insert(sibling)
            saved.isSaved = !isSaved
            sibling.isSaved = !isSaved
            try context.save()
            let service = FeedService()
            service.setSaved(article: sibling, isSaved: isSaved, context: context)
            XCTAssertEqual(service.savedArticleCount([saved], context: context), isSaved ? 1 : 0)
            try service.unsubscribe(feed, keepSavedArticles: true, context: context)
            try await Task.sleep(for: .seconds(1))
            let rows = try ModelContext(container).fetch(FetchDescriptor<Article>())
            XCTAssertEqual(rows.count, isSaved ? 2 : 1)
            XCTAssertTrue(rows.allSatisfy { $0.isSaved == isSaved })
        }
    }

    @MainActor
    func testDestructiveUnsubscribeDuringRefreshAndStaleActionsCannotResurrectData() async throws {
        let (container, context, feed, saved, _) = try fixture()
        var resume: CheckedContinuation<ParsedFeed, Never>?
        let service = FeedService(fetchFeed: { _ in
            await withCheckedContinuation { resume = $0 }
        })
        let refresh = Task { try await service.refresh(feed: feed, context: context) }
        while resume == nil { await Task.yield() }
        try service.unsubscribe(feed, keepSavedArticles: false, context: context)
        service.setRead(article: saved, isRead: false, context: context)
        service.setSaved(article: saved, isSaved: true, context: context)
        try service.markAllRead(feed: feed, context: context)
        resume?.resume(returning: parsedFeed())
        try await refresh.value
        try await Task.sleep(for: .seconds(1))
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Feed>()), 0)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Article>()), 0)
    }

    @MainActor
    func testSaveFailureRollsBackUnsubscribeButPreservesEarlierArticleChanges() throws {
        for keepSaved in [true, false] {
            let (container, context, feed, saved, other) = try fixture()
            saved.isRead = false
            var saves = 0
            let service = FeedService(saveSubscription: { context in
                saves += 1
                if saves == 2 { throw CocoaError(.fileWriteUnknown) }
                try context.save()
            })
            XCTAssertThrowsError(try service.unsubscribe(feed, keepSavedArticles: keepSaved, context: context))
            XCTAssertTrue(feed.isSubscribed)
            XCTAssertFalse(saved.isRead)
            XCTAssertFalse(other.isDeleted)
            XCTAssertFalse(saved.isDeleted)
            XCTAssertTrue(feed.modelContext === context)
            XCTAssertTrue(saved.modelContext === context)
            XCTAssertTrue(other.modelContext === context)
            XCTAssertEqual(saved.feed?.id, feed.id)
            XCTAssertEqual(other.feed?.id, feed.id)
            XCTAssertEqual(feed.articles.count, 2)
            let reopened = ModelContext(container)
            XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Article>()), 2)
            XCTAssertTrue(try XCTUnwrap(reopened.fetch(FetchDescriptor<Feed>()).first).isSubscribed)
        }
    }

    @MainActor
    func testLateImageResultCannotMutateDeletedArticle() async throws {
        let (container, context, feed, _, _) = try fixture()
        var resume: CheckedContinuation<String?, Never>?
        var response = parsedFeed()
        response.articles = [response.articles[1]]
        response.articles[0].imageURL = nil
        let service = FeedService(fetchFeed: { _ in response }, fetchImage: { _ in
            await withCheckedContinuation { resume = $0 }
        })
        let refresh = Task { try await service.refresh(feed: feed, context: context) }
        while resume == nil { await Task.yield() }
        try service.unsubscribe(feed, keepSavedArticles: false, context: context)
        resume?.resume(returning: "https://example.com/late-image.png")
        try await refresh.value
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Article>()), 0)
    }

    @MainActor
    func testActiveDuplicateDoesNotChangeCategoryOrSavedStateAndIsNotAdded() async throws {
        let (container, context, feed, saved, _) = try fixture()
        let feedID = feed.id
        let savedID = saved.id
        let savedDate = saved.savedAt
        let service = FeedService(fetchFeed: { _ in self.parsedFeed() })
        do {
            _ = try await service.addFeed(url: feed.url, category: "Imported category", context: context)
            XCTFail("An active subscription must report already subscribed")
        } catch FeedService.AdditionError.alreadySubscribed {
            // Expected: Add Feed displays this error and OPML's try? does not count it.
        }
        let imported = try? await service.addFeed(url: feed.url, category: "Imported category", context: context)
        XCTAssertNil(imported)
        XCTAssertFalse(context.hasChanges)
        let reopened = ModelContext(container)
        let feeds = try reopened.fetch(FetchDescriptor<Feed>())
        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds.first?.id, feedID)
        XCTAssertEqual(feeds.first?.category, "Tech")
        let articles = try reopened.fetch(FetchDescriptor<Article>())
        XCTAssertEqual(articles.count, 2)
        let retained = try XCTUnwrap(articles.first { $0.id == savedID })
        XCTAssertTrue(retained.isSaved)
        XCTAssertTrue(retained.isRead)
        XCTAssertEqual(retained.savedAt, savedDate)
    }

    @MainActor
    func testAnyActiveDuplicateTakesPrecedenceOverAnArchivedMatch() async throws {
        let (container, context, archived, saved, _) = try fixture()
        let service = FeedService(fetchFeed: { _ in self.parsedFeed() })
        try service.unsubscribe(archived, keepSavedArticles: true, context: context)
        let active = Feed(url: archived.url, title: "Active duplicate", category: "Active category")
        context.insert(active)
        try context.save()
        let result = try? await service.addFeed(url: archived.url, category: "Imported category", context: context)
        XCTAssertNil(result)
        XCTAssertTrue(active.isSubscribed)
        XCTAssertEqual(active.category, "Active category")
        XCTAssertFalse(archived.isSubscribed)
        XCTAssertEqual(archived.category, "Tech")
        XCTAssertTrue(saved.isSaved)
        let reopened = ModelContext(container)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Feed>()), 2)
        XCTAssertEqual(try reopened.fetchCount(FetchDescriptor<Article>()), 1)
    }

    private func parsedFeed() -> ParsedFeed {
        ParsedFeed(title: "Network source", siteURL: "https://example.com", articles: ["saved", "late"].map {
            ParsedArticle(guid: $0, url: "https://example.com/\($0)", title: $0, summary: "", imageURL: "https://example.com/image.png", author: "", publishedAt: Date())
        })
    }
}
