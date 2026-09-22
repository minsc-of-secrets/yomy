import SwiftUI

struct ArticleFeedSections: View {
    let articles: [Article]
    var showsFeatured: Bool = true
    @Binding var selectedArticle: Article?

    // 派生データ(dedup・重複カウント・日付グルーピング)は articles の並びが変わったときだけ計算する。
    // 記事タップは親の @State(selectedArticle)を書き換えるので body は必ず再評価されるが、
    // そこで記事数ぶんの Calendar / DateFormatter を引き直すと、シートの表示アニメーションが
    // 始まる前にメインスレッドが塞がり「タップしてからブラウザが開くまで遅い」体感になる。
    @State private var cache = ArticleFeedLayoutCache()

    init(articles: [Article], showsFeatured: Bool = true, selectedArticle: Binding<Article?>) {
        self.articles = articles
        self.showsFeatured = showsFeatured
        self._selectedArticle = selectedArticle
    }

    var body: some View {
        let layout = cache.layout(for: articles, showsFeatured: showsFeatured)

        return Group {
            if let featured = layout.featured {
                Section {
                    articleCardRow(article: featured, featured: true, counts: layout.counts)
                }
            }

            ForEach(layout.sections) { section in
                Section(section.id) {
                    ForEach(section.articles) { article in
                        articleCardRow(article: article, featured: false, counts: layout.counts)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func articleCardRow(article: Article, featured: Bool, counts: [String: Int]) -> some View {
        let extraFeedCount = article.url.isEmpty ? 0 : max(0, (counts[article.url] ?? 1) - 1)
        Button {
            selectedArticle = article
        } label: {
            ArticleRowView(
                article: article,
                featured: featured,
                additionalFeedCount: extraFeedCount
            )
        }
        .buttonStyle(.plain)
        .contextMenu { ArticleContextMenu(article: article) }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// 1 回の body 評価に必要な派生データ一式。
struct ArticleFeedLayout {
    struct DateSection: Identifiable {
        /// セクション見出し("Today" / "09/22" など)。記事群の中で一意。
        let id: String
        let articles: [Article]
    }

    let featured: Article?
    /// 同一 URL の記事が何件あるか(「ほか N フィード」バッジ用)。
    let counts: [String: Int]
    let sections: [DateSection]
}

/// `articles` の並びをキーに `ArticleFeedLayout` をメモ化する。
///
/// `@State` で保持するので view struct が作り直されても生き残る。`@Observable` ではないため、
/// body 評価中に書き換えても SwiftUI の再評価を誘発しない。
final class ArticleFeedLayoutCache {
    private var keyArticles: [Article] = []
    private var keyShowsFeatured = true
    private var cached: ArticleFeedLayout?

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd"
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    @MainActor
    func layout(for articles: [Article], showsFeatured: Bool) -> ArticleFeedLayout {
        if let cached,
           keyShowsFeatured == showsFeatured,
           Self.isSameOrder(keyArticles, articles) {
            return cached
        }
        let layout = Self.makeLayout(articles: articles, showsFeatured: showsFeatured)
        keyArticles = articles
        keyShowsFeatured = showsFeatured
        cached = layout
        return layout
    }

    /// 並びが同じなら中身も同じ(Article は同一 context の @Model なので参照比較で足りる)。
    private static func isSameOrder(_ lhs: [Article], _ rhs: [Article]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            if lhs[index] !== rhs[index] { return false }
        }
        return true
    }

    @MainActor
    private static func makeLayout(articles: [Article], showsFeatured: Bool) -> ArticleFeedLayout {
        var counts: [String: Int] = [:]
        for article in articles where !article.url.isEmpty {
            counts[article.url, default: 0] += 1
        }

        let deduped = FeedService.dedupByURL(articles)
        let featured = showsFeatured ? deduped.first : nil
        let rest = featured != nil ? Array(deduped.dropFirst()) : deduped

        return ArticleFeedLayout(featured: featured, counts: counts, sections: group(rest))
    }

    private static func group(_ articles: [Article]) -> [ArticleFeedLayout.DateSection] {
        let cal = Calendar.current
        let currentYear = cal.component(.year, from: Date())
        let groups = Dictionary(grouping: articles) { article -> String in
            if cal.isDateInToday(article.publishedAt) { return "Today" }
            if cal.isDateInYesterday(article.publishedAt) { return "Yesterday" }
            let year = cal.component(.year, from: article.publishedAt)
            return year == currentYear
                ? shortFormatter.string(from: article.publishedAt)
                : fullFormatter.string(from: article.publishedAt)
        }
        let order = ["Today", "Yesterday"]
        return groups
            .sorted { a, b in
                let ia = order.firstIndex(of: a.key) ?? Int.max
                let ib = order.firstIndex(of: b.key) ?? Int.max
                if ia != ib { return ia < ib }
                // 文字列ではなく実際の publishedAt で並べる("2024/12/04" < "12/24" になるため)
                let dateA = a.value.first?.publishedAt ?? .distantPast
                let dateB = b.value.first?.publishedAt ?? .distantPast
                return dateA > dateB
            }
            .map { ArticleFeedLayout.DateSection(id: $0.key, articles: $0.value) }
    }
}
