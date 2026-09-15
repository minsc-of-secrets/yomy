import SwiftUI
import SwiftData

struct SavedView: View {
    @Query(
        filter: #Predicate<Article> { $0.isSaved },
        sort: \Article.savedAt,
        order: .reverse
    ) private var articles: [Article]

    @Environment(\.modelContext) private var context
    @State private var selectedArticle: Article?

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM"
        return f
    }()

    private func savedDate(for article: Article) -> Date {
        article.savedAt ?? article.createdAt
    }

    private var siblingCountsByURL: [String: Int] {
        var counts: [String: Int] = [:]
        for article in articles where !article.url.isEmpty {
            counts[article.url, default: 0] += 1
        }
        return counts
    }

    private var grouped: [(String, [Article])] {
        let groups = Dictionary(grouping: FeedService.dedupByURL(articles)) { article in
            Self.monthFormatter.string(from: savedDate(for: article))
        }
        return groups
            .map { (key: $0.key, articles: $0.value) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.articles.first.map(savedDate(for:)) ?? .distantPast
                let rhsDate = rhs.articles.first.map(savedDate(for:)) ?? .distantPast
                return lhsDate > rhsDate
            }
            .map { ($0.key, $0.articles) }
    }

    var body: some View {
        // 派生データは body 評価ごとに 1 回だけ計算する。
        // 各行から siblingCountsByURL を呼ぶと行数×記事数の O(n²) となり、
        // ブックマーク直後の再評価・スクロールが固まる原因になっていた。
        let counts = siblingCountsByURL
        let sections = grouped
        return NavigationStack {
            List {
                ForEach(sections, id: \.0) { month, monthArticles in
                    Section(month) {
                        ForEach(monthArticles) { article in
                            let extraFeedCount = article.url.isEmpty ? 0 : max(0, (counts[article.url] ?? 1) - 1)
                            Button {
                                selectedArticle = article
                            } label: {
                                ArticleRowView(
                                    article: article,
                                    additionalFeedCount: extraFeedCount
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu { ArticleContextMenu(article: article) }
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    FeedService.shared.setSaved(article: article, isSaved: false, context: context)
                                } label: {
                                    Label("Unsave", systemImage: "bookmark.slash")
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
            .navigationTitle("Saved")
            .sheet(item: $selectedArticle) { article in
                NavigationStack {
                    ArticleWebView(article: article)
                }
            }
            .overlay {
                if articles.isEmpty {
                    ContentUnavailableView(
                        "No Saved Articles",
                        systemImage: "bookmark",
                        description: Text("Long-press an article and tap Save for Later")
                    )
                }
            }
        }
    }
}
