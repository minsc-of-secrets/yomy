import SwiftUI
import SwiftData

/// Shared by list swipe and feed detail. Opening or cancelling never mutates data.
struct UnsubscribeFeedView: View {
    let feed: Feed
    var onUnsubscribed: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var articles: [Article]
    @State private var keepSavedArticles = true
    @State private var errorMessage: String?

    init(feed: Feed, onUnsubscribed: @escaping () -> Void = {}) {
        self.feed = feed
        self.onUnsubscribed = onUnsubscribed
        let feedID = feed.id
        _articles = Query(filter: #Predicate<Article> { $0.feed?.id == feedID })
    }

    private var savedCount: Int {
        FeedService.shared.savedArticleCount(articles, context: context)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(feed.title.isEmpty ? feed.url : feed.title)
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
                            try FeedService.shared.unsubscribe(feed, keepSavedArticles: keepSavedArticles, context: context)
                            dismiss()
                            onUnsubscribed()
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
