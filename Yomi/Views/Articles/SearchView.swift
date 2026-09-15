import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.modelContext) private var context
    @State private var query = ""

    var body: some View {
        NavigationStack {
            SearchResultsView(query: query)
                .navigationTitle("Search")
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search articles")
        }
    }
}

private struct SearchResultsView: View {
    let query: String

    @Query private var articles: [Article]
    @State private var selectedArticle: Article?

    init(query: String) {
        self.query = query
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            _articles = Query(sort: \Article.publishedAt, order: .reverse)
        } else {
            _articles = Query(
                filter: #Predicate<Article> { article in
                    article.title.localizedStandardContains(trimmed) ||
                    article.summary.localizedStandardContains(trimmed)
                },
                sort: \Article.publishedAt,
                order: .reverse
            )
        }
    }

    var body: some View {
        List(articles) { article in
            Button {
                selectedArticle = article
            } label: {
                ArticleRowView(article: article)
            }
            .buttonStyle(.plain)
            .contextMenu { ArticleContextMenu(article: article) }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        // 空の List は grouped の背景を描かず systemBackground(白) になるため、
        // 行の有無によらず色を固定する。
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(item: $selectedArticle) { article in
            NavigationStack {
                ArticleWebView(article: article)
            }
        }
        .overlay {
            if articles.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
