import SwiftUI
import SwiftData

struct FeedsView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Feed> { $0.isSubscribed }, sort: \Feed.createdAt) private var feeds: [Feed]

    @State private var showAddFeed = false
    @State private var feedToUnsubscribe: FeedUnsubscribeRequest?

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
                                Button {
                                    guard feed.modelContext === context, !feed.isDeleted else { return }
                                    feedToUnsubscribe = FeedUnsubscribeRequest(feed: feed)
                                } label: {
                                    Label("Unsubscribe", systemImage: "trash")
                                }
                                .tint(.red)
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
            .sheet(item: $feedToUnsubscribe) { request in
                UnsubscribeFeedView(request: request)
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
