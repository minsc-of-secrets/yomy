import SwiftUI
import SwiftData

@main
struct YomiApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Feed.self, Article.self, Category.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        seedDefaultCategoryIfNeeded()
        backfillSavedAtIfNeeded()
        try? FeedService.shared.purgeUnsavedArchivedArticles(context: ModelContext(container))
        BackgroundRefreshService.register(container: container)
        BackgroundRefreshService.schedule()
    }

    private func seedDefaultCategoryIfNeeded() {
        let key = "yomy.didSeedDefaultCategory"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let context = ModelContext(container)
        context.insert(Category(name: "General", sortOrder: 0))
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    private func backfillSavedAtIfNeeded() {
        let key = "yomy.didBackfillSavedAt"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Article>(
            predicate: #Predicate { $0.isSaved && $0.savedAt == nil }
        )
        if let articles = try? context.fetch(descriptor) {
            for article in articles {
                article.savedAt = article.createdAt
            }
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(container)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                    BackgroundRefreshService.schedule()
                }
        }
    }
}
