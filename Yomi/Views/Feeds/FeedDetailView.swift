import SwiftUI
import SwiftData

struct FeedDetailView: View {
    let feed: Feed
    @Environment(\.modelContext) private var context

    @State private var isRefreshing = false
    @State private var selectedArticle: Article?
    @State private var showEditFeed = false
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    private var sortedArticles: [Article] {
        feed.articles.sorted { $0.publishedAt > $1.publishedAt }
    }

    var body: some View {
        // 記事タップで body が再評価されるため、ソートは 1 回に抑える。
        let sorted = sortedArticles

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
        .navigationTitle(feed.title.isEmpty ? feed.url : feed.title)
        .navigationBarTitleDisplayMode(.inline)
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
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete Feed", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showEditFeed) {
            FeedManageView(feed: feed)
        }
        .alert("Delete Feed?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                try? FeedService.shared.deleteFeed(feed, context: context)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(feed.title.isEmpty ? feed.url : feed.title)\" and all its articles will be removed.")
        }
        .overlay {
            if sorted.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "doc.text")
            }
        }
    }
}
