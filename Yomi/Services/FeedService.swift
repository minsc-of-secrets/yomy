import Foundation
import OSLog
import SwiftData
import WidgetKit

private let ogFetchConcurrency = 5
private let widgetLog = Logger(subsystem: "com.shakshi.yomy", category: "Widget")
/// Widget に載せるのは先頭 10 件だけ。dedup で減る分の余裕を見た上限で打ち切る。
private let widgetSnapshotFetchLimit = 100
/// スナップショット更新をまとめるデバウンス幅。
private let widgetSnapshotDebounce = Duration.milliseconds(500)
/// 既読化の永続化を遅らせる幅。シート表示アニメーションが始まってから書き込む。
private let readPersistDelay = Duration.milliseconds(300)

@MainActor
final class FeedService {
    static let shared = FeedService()

    private let fetchFeed: (String) async throws -> ParsedFeed
    private let fetchImage: (String) async -> String?
    private let saveSubscription: (ModelContext) throws -> Void

    init(
        fetchFeed: @escaping (String) async throws -> ParsedFeed = { try await RSSFetcher.shared.fetch(url: $0) },
        fetchImage: @escaping (String) async -> String? = { await OGImageFetcher.shared.fetch(articleURL: $0) },
        saveSubscription: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.fetchFeed = fetchFeed
        self.fetchImage = fetchImage
        self.saveSubscription = saveSubscription
    }

    private var widgetSnapshotTask: Task<Void, Never>?
    private var pendingReadTasks: [ArticleMutationKey: Task<Void, Never>] = [:]
    private var pendingSavedTasks: [ArticleMutationKey: Task<Void, Never>] = [:]
    private var pendingSavedIntents: [ArticleMutationKey: SavedIntent] = [:]

    private struct SavedIntent {
        let article: Article
        let isSaved: Bool
        let savedAt: Date?
    }

    func savedArticleCount(_ articles: [Article], context: ModelContext) -> Int {
        Self.dedupByURL(articles.filter {
            pendingSavedIntents[ArticleMutationKey(article: $0, context: context)]?.isSaved ?? $0.isSaved
        }).count
    }

    private func flushSavedIntents(context: ModelContext) {
        let keys = pendingSavedIntents.keys.filter { $0.context == ObjectIdentifier(context) }
        for key in keys {
            guard let intent = pendingSavedIntents.removeValue(forKey: key) else { continue }
            pendingSavedTasks.removeValue(forKey: key)?.cancel()
            guard intent.article.modelContext === context, !intent.article.isDeleted else { continue }
            applyToSiblings(of: intent.article, context: context) {
                $0.isSaved = intent.isSaved
                $0.savedAt = intent.savedAt
            }
        }
    }

    private struct ArticleMutationKey: Hashable {
        let context: ObjectIdentifier
        let article: String

        init(article: Article, context: ModelContext) {
            self.context = ObjectIdentifier(context)
            self.article = article.url.isEmpty ? "id:\(article.id)" : "url:\(article.url)"
        }
    }

    private func cancelPendingRead(for article: Article, context: ModelContext) {
        let key = ArticleMutationKey(article: article, context: context)
        pendingReadTasks.removeValue(forKey: key)?.cancel()
    }

    func refresh(feed: Feed, context: ModelContext) async throws {
        guard feed.modelContext === context, !feed.isDeleted, feed.isSubscribed else { return }
        let parsed = try await fetchFeed(feed.url)
        // Unsubscribe can run while the network request is suspended.
        guard feed.modelContext === context, !feed.isDeleted, feed.isSubscribed else { return }

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
                    if let url = await self.fetchImage(articleURL) {
                        await MainActor.run {
                            guard article.modelContext === context, !article.isDeleted,
                                  feed.isSubscribed else { return }
                            article.imageURL = url
                        }
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
            for feed in feeds where feed.isSubscribed {
                group.addTask {
                    try? await self.refresh(feed: feed, context: context)
                }
            }
        }
        updateWidgetSnapshot(context: context)
    }

    /// Widget スナップショットの更新をデバウンスして遅延実行する。
    ///
    /// 記事を開いた直後はシートの表示アニメーションと WebView の初回ロードが走っている。
    /// そこで同期的に fetch を走らせるとメインスレッドが塞がり、タップからページが出るまでの
    /// 体感が悪くなるため、更新は必ずこの入口から呼ぶ。
    func scheduleWidgetSnapshotUpdate(context: ModelContext) {
        widgetSnapshotTask?.cancel()
        // ModelContext does not own its container. Keep it alive across the
        // debounce even if the caller's screen/test scope has already ended.
        let container = context.container
        widgetSnapshotTask = Task { [self, container] in
            defer { withExtendedLifetime(container) {} }
            try? await Task.sleep(for: widgetSnapshotDebounce)
            guard !Task.isCancelled else { return }
            updateWidgetSnapshot(context: context)
        }
    }

    func updateWidgetSnapshot(context: ModelContext) {
        // 全記事を materialize すると記事数に比例してメインスレッドが止まる。
        // 実際に必要なのは未読の新しい順の先頭だけなので、述語と件数上限で store 側に絞らせる。
        var descriptor = FetchDescriptor<Article>(
            predicate: #Predicate<Article> { $0.isRead == false && $0.feed?.isSubscribed == true },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        descriptor.fetchLimit = widgetSnapshotFetchLimit
        guard let unread = try? context.fetch(descriptor) else {
            widgetLog.error("updateWidgetSnapshot: fetch failed")
            return
        }
        let deduped = Self.dedupByURL(unread)
        let top = Array(deduped.prefix(10))
        widgetLog.info("updateWidgetSnapshot: unread=\(unread.count) deduped=\(deduped.count) snapshot=\(top.count)")
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
            parsed = try await fetchFeed(normalizedURL)
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

        let resolvedURL = feedURL
        let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.url == resolvedURL })
        let existingFeed = try context.fetch(descriptor).first
        let feed = existingFeed ?? Feed(
            url: feedURL,
            title: parsed.title.isEmpty ? normalizedURL : parsed.title,
            siteURL: parsed.siteURL,
            category: category
        )
        if existingFeed == nil { context.insert(feed) }
        feed.isSubscribed = true
        feed.category = category
        // Reuse an archived source so re-subscribing preserves saved/read state.
        let feedID = feed.id
        let stored = try context.fetch(FetchDescriptor<Article>(
            predicate: #Predicate { $0.feed?.id == feedID }
        ))
        var existingGUIDs = Set(stored.map(\.guid))
        var needsOGFetch: [(Article, String)] = []

        for parsedArticle in parsed.articles {
            guard existingGUIDs.insert(parsedArticle.guid).inserted else { continue }
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
                    if let url = await self.fetchImage(articleURL) {
                        await MainActor.run {
                            guard article.modelContext === context, !article.isDeleted,
                                  feed.isSubscribed else { return }
                            article.imageURL = url
                        }
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

    func unsubscribe(_ feed: Feed, keepSavedArticles: Bool, context: ModelContext) throws {
        guard feed.modelContext === context, !feed.isDeleted, feed.isSubscribed else { return }
        // Classify all copies using the newest save/unsave intent, including an
        // action on another feed's copy that has not propagated yet.
        flushSavedIntents(context: context)
        let feedID = feed.id
        let articles = try context.fetch(FetchDescriptor<Article>(
            predicate: #Predicate { $0.feed?.id == feedID }
        ))
        // Persist the user's existing state first. A failed unsubscribe can then roll
        // back only this operation rather than unrelated pending read/save changes.
        try saveSubscription(context)
        do {
            feed.isSubscribed = false
            if keepSavedArticles && articles.contains(where: \.isSaved) {
                for article in articles where !article.isSaved { context.delete(article) }
            } else {
                context.delete(feed)
            }
            try saveSubscription(context)
        } catch {
            context.rollback()
            // SwiftData restores the store but can leave this live model's
            // scalar cache stale after rollback. Keep the visible subscription.
            feed.isSubscribed = true
            throw error
        }
        scheduleWidgetSnapshotUpdate(context: context)
    }

    // Explicit destructive API retained for callers that intend to remove all data.
    func deleteFeed(_ feed: Feed, context: ModelContext) throws {
        try unsubscribe(feed, keepSavedArticles: false, context: context)
    }

    func markAllRead(feed: Feed, context: ModelContext) throws {
        guard feed.modelContext === context, !feed.isDeleted else { return }
        for article in feed.articles {
            // A newer bulk action must supersede earlier delayed single-article writes,
            // even when the article already appears read in memory.
            cancelPendingRead(for: article, context: context)
            if !article.isRead {
                article.isRead = true
            }
        }
        try context.save()
        scheduleWidgetSnapshotUpdate(context: context)
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
        guard article.modelContext === context, !article.isDeleted else { return }
        let key = ArticleMutationKey(article: article, context: context)
        cancelPendingRead(for: article, context: context)
        // 1) タップされた記事だけ即時に反映し、既読スタイルの切り替えを即応させる。
        article.isRead = isRead

        // 2) 同一 URL の重複記事への波及・永続化・Widget 更新は後回しにする。
        //    記事を開いた直後はシートの表示アニメーションと WebView の初回ロードが走っており、
        //    ここで fetch(全件述語)+ save(ディスクフラッシュ)+ スナップショット生成を
        //    同期実行するとメインスレッドが数百 ms 止まる。これが
        //    「タップしてからブラウザが開くまでが遅い」体感の主因だった。
        pendingReadTasks[key] = Task {
            do {
                try await Task.sleep(for: readPersistDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            defer { pendingReadTasks[key] = nil }
            // Do not touch an article removed or moved while this task was suspended.
            guard article.modelContext === context, !article.isDeleted else { return }
            applyToSiblings(of: article, context: context) { $0.isRead = isRead }
            try? context.save()
            scheduleWidgetSnapshotUpdate(context: context)
        }
    }

    func setSaved(article: Article, isSaved: Bool, context: ModelContext) {
        guard article.modelContext === context, !article.isDeleted else { return }
        let key = ArticleMutationKey(article: article, context: context)
        pendingSavedTasks.removeValue(forKey: key)?.cancel()
        let now = Date()
        pendingSavedIntents[key] = SavedIntent(article: article, isSaved: isSaved, savedAt: isSaved ? now : nil)

        // 1) タップされた記事だけを即時に反映し、bookmark.fill やメニュー閉じを即応させる。
        article.isSaved = isSaved
        article.savedAt = isSaved ? now : nil

        // 2) 同一 URL の重複記事への波及と永続化(fetch + save)は次の main-actor ターンへ回す。
        //    ここを同期実行するとディスクフラッシュ完了までタップ直後の再描画がブロックされ、
        //    「保存/解除が若干重い」体感につながっていた。
        pendingSavedTasks[key] = Task {
            guard !Task.isCancelled else { return }
            defer {
                pendingSavedTasks[key] = nil
                pendingSavedIntents[key] = nil
            }
            guard article.modelContext === context, !article.isDeleted else { return }
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
