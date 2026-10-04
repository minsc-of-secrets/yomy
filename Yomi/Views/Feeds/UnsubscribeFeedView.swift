import SwiftUI
import SwiftData

/// Value-only presentation identity stays valid after the source model is deleted.
struct FeedUnsubscribeRequest: Identifiable {
    let id: UUID
    let title: String

    init(feed: Feed) {
        id = feed.id
        title = feed.title.isEmpty ? feed.url : feed.title
    }
}

/// Shared by list swipe and feed detail. Opening or cancelling never mutates data.
struct UnsubscribeFeedView: View {
    let request: FeedUnsubscribeRequest
    var onUnsubscribed: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var articles: [Article]
    @State private var keepSavedArticles = true
    @State private var errorMessage: String?
    @State private var didUnsubscribe = false

    init(request: FeedUnsubscribeRequest, onUnsubscribed: @escaping () -> Void = {}) {
        self.request = request
        self.onUnsubscribed = onUnsubscribed
        let feedID = request.id
        _articles = Query(filter: #Predicate<Article> { $0.feed?.id == feedID })
    }

    private var savedCount: Int {
        guard !didUnsubscribe else { return 0 }
        let liveArticles = articles.filter { $0.modelContext === context && !$0.isDeleted }
        return FeedService.shared.savedArticleCount(liveArticles, context: context)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.title)
                    Text("\(savedCount) saved articles")
                    if savedCount > 0 {
                        Toggle("Keep saved articles", isOn: $keepSavedArticles)
                    }
                } footer: {
                    if keepSavedArticles && savedCount > 0 {
                        Text("This feed will stop updating. Saved articles and their source will remain in Saved. Other articles will be removed.")
                    } else {
                        Text("This feed and all its articles will be removed. This cannot be undone.")
                    }
                }
                Section {
                    Button("Unsubscribe", role: .destructive) {
                        do {
                            let feedID = request.id
                            let descriptor = FetchDescriptor<Feed>(predicate: #Predicate { $0.id == feedID })
                            if let feed = try context.fetch(descriptor).first {
                                try FeedService.shared.unsubscribe(feed, keepSavedArticles: keepSavedArticles, context: context)
                            }
                            didUnsubscribe = true
                            onUnsubscribed()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .navigationTitle("Unsubscribe?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
            .alert("Could Not Unsubscribe", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Please try again.")
            }
        }
    }
}
