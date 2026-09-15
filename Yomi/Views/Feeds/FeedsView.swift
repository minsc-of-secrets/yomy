import SwiftUI
import SwiftData

struct FeedsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Feed.createdAt) private var feeds: [Feed]

    @State private var showAddFeed = false

    private var groupedFeeds: [(String, [Feed])] {
        let groups = Dictionary(grouping: feeds, by: \.category)
        return groups.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedFeeds, id: \.0) { category, categoryFeeds in
                    Section(category) {
                        ForEach(categoryFeeds) { feed in
                            NavigationLink {
                                FeedDetailView(feed: feed)
                            } label: {
                                FeedRowView(feed: feed)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    try? FeedService.shared.deleteFeed(feed, context: context)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            // 空の List は grouped の背景を描かず systemBackground(白) になるため、
            // 行の有無によらず色を固定する。
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Feeds")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFeed = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddFeed) {
                AddFeedView()
            }
            .overlay {
                if feeds.isEmpty {
                    ContentUnavailableView(
                        "No Feeds",
                        systemImage: "list.bullet",
                        description: Text("Tap + in the top right to add a feed")
                    )
                }
            }
        }
    }
}
