import SwiftUI
import SwiftData

struct FeedDetailView: View {
    let feed: Feed
    private let originalTitle: String
    @Environment(\.modelContext) private var context

    @State private var isRefreshing = false
    @State private var selectedArticle: Article?
    @State private var showEditFeed = false
    @State private var unsubscribeRequest: FeedUnsubscribeRequest?
    @State private var didUnsubscribe = false
    @Environment(\.dismiss) private var dismiss

    init(feed: Feed) {
        self.feed = feed
        if feed.modelContext != nil && !feed.isDeleted {
            self.originalTitle = feed.title.isEmpty ? feed.url : feed.title
        } else {
            self.originalTitle = "Feed"
        }
    }

    private var isAvailable: Bool {
        !didUnsubscribe && feed.modelContext === context && !feed.isDeleted && feed.isSubscribed
    }

    private var displayTitle: String {
        guard isAvailable else { return originalTitle }
        return feed.title.isEmpty ? feed.url : feed.title
    }

    var body: some View {
        Group {
            if isAvailable {
                articleList
            } else {
                Color.clear
            }
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $unsubscribeRequest, onDismiss: {
            // Pop only after the confirmation sheet has finished dismissing.
            // Cancel and failed saves leave the detail screen in place.
            if didUnsubscribe { dismiss() }
        }) { request in
            UnsubscribeFeedView(request: request) { didUnsubscribe = true }
        }
    }

    private var articleList: some View {
        // 記事タップで body が再評価されるため、ソートは 1 回に抑える。
        let sorted = feed.articles
            .filter { $0.modelContext === context && !$0.isDeleted }
            .sorted { $0.publishedAt > $1.publishedAt }

        return List(sorted) { article in
            Button {
                selectedArticle = article
            } label: {
                ArticleRowView(article: article, showFeedName: false)
            }
            .buttonStyle(.plain)
            .contextMenu { ArticleContextMenu(article: article) }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .refreshable {
            try? await FeedService.shared.refresh(feed: feed, context: context)
        }
        .sheet(item: $selectedArticle) { article in
            NavigationStack {
                ArticleWebView(article: article)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        try? FeedService.shared.markAllRead(feed: feed, context: context)
                    } label: {
                        Label("Mark All Read", systemImage: "checkmark.circle")
                    }
                    Button {
                        Task { try? await FeedService.shared.refresh(feed: feed, context: context) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Button {
                        showEditFeed = true
                    } label: {
                        Label("Edit Feed", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        guard isAvailable else { return }
                        unsubscribeRequest = FeedUnsubscribeRequest(feed: feed)
                    } label: {
                        Label("Unsubscribe", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditFeed) {
            FeedManageView(feed: feed)
        }
        .overlay {
            if sorted.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text")
            }
        }
    }
}
