import Foundation
import OSLog
import SwiftData
import WidgetKit

private let ogFetchConcurrency = 5
private let widgetLog = Logger(subsystem: "com.shakshi.yomy", category: "Widget")

@MainActor
final class FeedService {
    static let shared = FeedService()

    func refresh(feed: Feed, context: ModelContext) async throws {
        let parsed = try await RSSFetcher.shared.fetch(url: feed.url)

        if feed.title.isEmpty || feed.title == feed.url {
            feed.title = parsed.title
        }
        if feed.siteURL.isEmpty {
            feed.siteURL = parsed.siteURL
        }
        feed.fetchedAt = Date()

        // feed.articles リレーションのキャッシュではなく FetchDescriptor で store を読む。
        // 別 context（旧 BG refresh など）が直前に書いた行も拾えるようにするための保険。
        let feedID = feed.id
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate<Article> { $0.feed?.id == feedID }
        )
        let storedArticles = (try? context.fetch(descriptor)) ?? feed.articles
        // 過去に重複 guid が混入していてもクラッシュさせないため uniquingKeysWith: を使う
        let existingByGUID = Dictionary(
            storedArticles.map { ($0.guid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var insertedGUIDs = Set<String>()
        var needsOGFetch: [(Article, String)] = []

        for parsedArticle in parsed.articles {
            if let existing = existingByGUID[parsedArticle.guid] {
                // 既存記事で imageURL がまだ未取得なら OG フェッチ対象に追加
                if existing.imageURL == nil && !parsedArticle.url.isEmpty {
                    needsOGFetch.append((existing, parsedArticle.url))
                }
                continue
            }
            // 同一フェッチ内で重複 guid が来た場合は最初の 1 件だけを挿入する
            guard insertedGUIDs.insert(parsedArticle.guid).inserted else { continue }
            let article = Article(
                guid: parsedArticle.guid,
                url: parsedArticle.url,
                title: parsedArticle.title,
                summary: parsedArticle.summary,
                imageURL: parsedArticle.imageURL,
                author: parsedArticle.author,
                publishedAt: parsedArticle.publishedAt,
                feed: feed
            )
            context.insert(article)
            feed.articles.append(article)

            if parsedArticle.imageURL == nil && !parsedArticle.url.isEmpty {
                needsOGFetch.append((article, parsedArticle.url))
            }
        }

        try context.save()

        // OG フェッチ — 新規・既存問わず imageURL が nil な記事を並列処理（最大 5 並列）
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (article, articleURL) in needsOGFetch {
                if running >= ogFetchConcurrency {
                    await group.next()
                    running -= 1
                }
                group.addTask {
                    if let url = await OGImageFetcher.shared.fetch(articleURL: articleURL) {
                        await MainActor.run { article.imageURL = url }
                    }
                }
                running += 1
            }
        }

        if !needsOGFetch.isEmpty {
            try context.save()
        }
    }

    func refreshAll(feeds: [Feed], context: ModelContext) async {
        await withTaskGroup(of: Void.self) { group in
            for feed in feeds {
                group.addTask {
                    try? await self.refresh(feed: feed, context: context)
                }
            }
        }
        updateWidgetSnapshot(context: context)
    }

    func updateWidgetSnapshot(context: ModelContext) {
        let descriptor = FetchDescriptor<Article>(
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        guard let allArticles = try? context.fetch(descriptor) else {
            widgetLog.error("updateWidgetSnapshot: fetch failed")
            return
        }
        let unread = allArticles.filter { !$0.isRead }
        let deduped = Self.dedupByURL(unread)
        let top = Array(deduped.prefix(10))
        widgetLog.info("updateWidgetSnapshot: total=\(allArticles.count) unread=\(unread.count) deduped=\(deduped.count) snapshot=\(top.count)")
        let widgetArticles = top.map { article in
            WidgetArticle(
                id: article.id.uuidString,
                title: article.title,
                feedTitle: article.feed?.title ?? "",
                url: article.url,
                imageURL: article.imageURL,
                publishedAt: article.publishedAt
            )
        }

        // JSON 書き込み・画像キャッシュのクリーンアップ・画像ダウンロードは
        // ディスク I/O とネットワークを含むためメインスレッドから切り離す。
        // 起動直後の onAppear でここが同期実行されると初回描画がもたつく。
        Task.detached(priority: .utility) {
            WidgetDataStore.save(widgetArticles)

            let keepIDs = Set(widgetArticles.map(\.id))
            WidgetDataStore.cleanUpImages(keeping: keepIDs)

            WidgetCenter.shared.reloadTimelines(ofKind: "YomiWidget")

            let imageJobs: [(id: String, url: URL)] = widgetArticles.compactMap { article in
                guard let urlString = article.imageURL,
                      let url = URL(string: urlString),
                      WidgetDataStore.loadImage(for: article.id) == nil else { return nil }
                return (article.id, url)
            }

            if imageJobs.isEmpty { return }

            await withTaskGroup(of: Void.self) { group in
                for job in imageJobs {
                    group.addTask {
                        guard let (data, _) = try? await URLSession.shared.data(from: job.url) else { return }
                        WidgetDataStore.cacheImage(data: data, for: job.id)
                    }
                }
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "YomiWidget")
        }
    }

    func addFeed(url: String, category: String, context: ModelContext) async throws -> Feed {
        let normalizedURL = url.hasPrefix("http") ? url : "https://\(url)"

        var feedURL = normalizedURL
        var parsed: ParsedFeed
        do {
            parsed = try await RSSFetcher.shared.fetch(url: normalizedURL)
        } catch {
            // The input may be a plain domain rather than a feed URL — try to
            // discover the feed from the page it points at.
            guard let pageURL = URL(string: normalizedURL) else { throw error }
            do {
                let discovered = try await FeedDiscoveryService.shared.discoverFeed(from: pageURL)
                feedURL = discovered.url
                parsed = discovered.parsed
            } catch FeedDiscoveryError.pageUnreachable {
                // The host never answered, so the original failure — usually a
                // network error — describes the problem better than "no feed found".
                throw error
            }
        }

        let feed = Feed(
            url: feedURL,
            title: parsed.title.isEmpty ? normalizedURL : parsed.title,
            siteURL: parsed.siteURL,
            category: category
        )
        context.insert(feed)

        var needsOGFetch: [(Article, String)] = []

        for parsedArticle in parsed.articles {
            let article = Article(
                guid: parsedArticle.guid,
                url: parsedArticle.url,
                title: parsedArticle.title,
                summary: parsedArticle.summary,
                imageURL: parsedArticle.imageURL,
                author: parsedArticle.author,
                publishedAt: parsedArticle.publishedAt,
                feed: feed
            )
            context.insert(article)
            feed.articles.append(article)

            if parsedArticle.imageURL == nil && !parsedArticle.url.isEmpty {
                needsOGFetch.append((article, parsedArticle.url))
            }
        }

        try context.save()

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (article, articleURL) in needsOGFetch {
                if running >= ogFetchConcurrency {
                    await group.next()
                    running -= 1
                }
                group.addTask {
                    if let url = await OGImageFetcher.shared.fetch(articleURL: articleURL) {
                        await MainActor.run { article.imageURL = url }
                    }
                }
                running += 1
            }
        }

        if !needsOGFetch.isEmpty {
            try context.save()
        }

        return feed
    }

    func deleteFeed(_ feed: Feed, context: ModelContext) throws {
        context.delete(feed)
        try context.save()
    }

    func markAllRead(feed: Feed, context: ModelContext) throws {
        for article in feed.articles where !article.isRead {
            article.isRead = true
        }
        try context.save()
        updateWidgetSnapshot(context: context)
    }

    static func dedupByURL(_ articles: [Article]) -> [Article] {
        var seen = Set<String>()
        var result: [Article] = []
        result.reserveCapacity(articles.count)
        for article in articles {
            if article.url.isEmpty {
                result.append(article)
                continue
            }
            if seen.insert(article.url).inserted {
                result.append(article)
            }
        }
        return result
    }

    func setRead(article: Article, isRead: Bool, context: ModelContext) {
        applyToSiblings(of: article, context: context) { $0.isRead = isRead }
        try? context.save()
        updateWidgetSnapshot(context: context)
    }

    func setSaved(article: Article, isSaved: Bool, context: ModelContext) {
        let now = Date()

        // 1) タップされた記事だけを即時に反映し、bookmark.fill やメニュー閉じを即応させる。
        article.isSaved = isSaved
        article.savedAt = isSaved ? now : nil

        // 2) 同一 URL の重複記事への波及と永続化(fetch + save)は次の main-actor ターンへ回す。
        //    ここを同期実行するとディスクフラッシュ完了までタップ直後の再描画がブロックされ、
        //    「保存/解除が若干重い」体感につながっていた。
        Task {
            applyToSiblings(of: article, context: context) {
                $0.isSaved = isSaved
                $0.savedAt = isSaved ? now : nil
            }
            try? context.save()
        }
    }

    private func applyToSiblings(
        of article: Article,
        context: ModelContext,
        _ body: (Article) -> Void
    ) {
        let url = article.url
        guard !url.isEmpty else {
            body(article)
            return
        }
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.url == url })
        let siblings = (try? context.fetch(descriptor)) ?? [article]
        for sibling in siblings {
            body(sibling)
        }
    }
}
