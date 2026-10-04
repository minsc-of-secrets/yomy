import XCTest
import SwiftUI
import SwiftData
import UIKit
@testable import YomiState

/// Hosted production-view rendering exercises stale references after a real
/// SwiftData mutation. It does not claim to automate on-device dismiss gestures.
final class UnsubscribeViewLifetimeTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (ModelContainer, Feed, Article) {
        let container = try ModelContainer(for: Feed.self, Article.self, YomiState.Category.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let feed = Feed(url: "https://example.com/feed", title: "Source title")
        context.insert(feed)
        // Empty URL prevents network work from a hosted article row.
        let article = Article(guid: "saved", url: "", title: "Saved title", publishedAt: Date(), feed: feed)
        article.isSaved = true
        article.savedAt = Date(timeIntervalSince1970: 123456)
        context.insert(article)
        try context.save()
        return (container, feed, article)
    }

    @MainActor
    private func host<V: View>(_ view: V, container: ModelContainer) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: AnyView(view.modelContainer(container)))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.layoutIfNeeded()
        return host
    }

    @MainActor
    private func redraw<V: View>(_ view: V, on host: UIHostingController<AnyView>, container: ModelContainer) {
        host.rootView = AnyView(view.id(UUID()).modelContainer(container))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.width, 0)
    }

    @MainActor
    func testProductionViewsCanRedrawAfterKeepOrDeleteUnsubscribe() async throws {
        for keepSaved in [true, false] {
            let (container, feed, article) = try fixture()
            let context = container.mainContext
            let request = FeedUnsubscribeRequest(feed: feed)
            let detail = host(FeedDetailView(feed: feed), container: container)
            let confirmation = host(UnsubscribeFeedView(request: request), container: container)
            let row = host(ArticleRowView(article: article), container: container)
            let featured = host(ArticleRowView(article: article, featured: true), container: container)
            try FeedService().unsubscribe(feed, keepSavedArticles: keepSaved, context: context)
            // Keep all hosted views alive, as they can be during a dismissal animation.
            // Rebuild the detail even with its now-detached source model.
            redraw(FeedDetailView(feed: feed), on: detail, container: container)
            redraw(UnsubscribeFeedView(request: request), on: confirmation, container: container)
            redraw(ArticleRowView(article: article), on: row, container: container)
            redraw(ArticleRowView(article: article, featured: true), on: featured, container: container)
            try await Task.sleep(for: .milliseconds(100))
            detail.view.layoutIfNeeded()
            confirmation.view.layoutIfNeeded()
            row.view.layoutIfNeeded()
            featured.view.layoutIfNeeded()
            XCTAssertEqual(request.title, "Source title")
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<Article>()), keepSaved ? 1 : 0)
            withExtendedLifetime((container, detail, confirmation, row, featured)) {}
        }
    }

    @MainActor
    func testHostedViewsRemainUsableAfterFailedUnsubscribe() async throws {
        let (container, feed, article) = try fixture()
        let context = container.mainContext
        let request = FeedUnsubscribeRequest(feed: feed)
        let detail = host(FeedDetailView(feed: feed), container: container)
        let confirmation = host(UnsubscribeFeedView(request: request), container: container)
        var saves = 0
        let service = FeedService(saveSubscription: { context in
            saves += 1
            if saves == 2 { throw CocoaError(.fileWriteUnknown) }
            try context.save()
        })
        XCTAssertThrowsError(try service.unsubscribe(feed, keepSavedArticles: false, context: context))
        redraw(FeedDetailView(feed: feed), on: detail, container: container)
        redraw(UnsubscribeFeedView(request: request), on: confirmation, container: container)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(feed.isSubscribed)
        XCTAssertEqual(feed.title, "Source title")
        XCTAssertTrue(article.isSaved)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Article>()), 1)
        withExtendedLifetime((container, detail, confirmation)) {}
    }
}
