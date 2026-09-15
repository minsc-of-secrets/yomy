import SwiftUI
import SwiftData

struct LatestView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Article.publishedAt, order: .reverse) private var articles: [Article]
    @Query private var feeds: [Feed]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var isRefreshing = false
    @State private var selectedArticle: Article?
    @State private var showSettings = false
    @State private var widgetUpdateTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if !categories.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(categories) { category in
                                    NavigationLink {
                                        CategoryFilteredView(category: category)
                                    } label: {
                                        CategoryChip(category: category)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }

                ArticleFeedSections(
                    articles: articles,
                    selectedArticle: $selectedArticle
                )
            }
            // 空の List は grouped の背景を描かず systemBackground(白) になるため、
            // 記事0件のタブだけ白く浮いて見える。行の有無によらず色を固定する。
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .refreshable {
                await refresh()
            }
            .navigationTitle("Latest")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $selectedArticle) { article in
                NavigationStack {
                    ArticleWebView(article: article)
                }
            }
            .onAppear {
                scheduleWidgetUpdate()
            }
            .onChange(of: articles) {
                scheduleWidgetUpdate()
            }
            .overlay {
                if articles.isEmpty && !isRefreshing {
                    ContentUnavailableView(
                        "No Articles",
                        systemImage: "newspaper",
                        description: Text("Add a feed to get started")
                    )
                }
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        await FeedService.shared.refreshAll(feeds: feeds, context: context)
        isRefreshing = false
    }

    /// 起動直後の初回描画をブロックしないよう Widget スナップショット更新を遅延させ、
    /// リフレッシュ中に連続で発火する onChange を 1 回にデバウンスする。
    private func scheduleWidgetUpdate() {
        guard !articles.isEmpty else { return }
        widgetUpdateTask?.cancel()
        widgetUpdateTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            FeedService.shared.updateWidgetSnapshot(context: context)
        }
    }
}

private struct CategoryChip: View {
    let category: Category

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: category.iconName)
                .font(.caption)
            Text(category.name)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
    }
}
