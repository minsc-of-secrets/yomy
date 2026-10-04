import Foundation
import BackgroundTasks
import SwiftData

final class BackgroundRefreshService {
    static let taskIdentifier = "com.shakshi.yomy.refresh"
    private static var sharedContainer: ModelContainer?

    static func register(container: ModelContainer) {
        sharedContainer = container
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundRefresh] schedule failed: \(error)")
        }
    }

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        schedule()

        // メインアプリと同じ ModelContainer を共有する。
        // 別 Container を新規作成すると、同じ SQLite を別キャッシュで開くことになり、
        // メイン側との同時 refresh で同一 guid の Article が二重 insert されて、
        // 次回 refresh の Dictionary(uniqueKeysWithValues:) がトラップする原因になる。
        guard let container = sharedContainer else {
            task.setTaskCompleted(success: false)
            return
        }

        let work = Task { @MainActor in
            // Share the UI identity map so an unsubscribe during a suspended
            // refresh is immediately visible to FeedService's post-await guards.
            let context = container.mainContext
            let feeds = (try? context.fetch(FetchDescriptor<Feed>(predicate: #Predicate { $0.isSubscribed }))) ?? []
            await FeedService.shared.refreshAll(feeds: feeds, context: context)
            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
