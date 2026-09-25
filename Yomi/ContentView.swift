import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @State private var widgetArticle: Article?

    var body: some View {
        tabs
            .onAppear {
                // WebKit のプロセス起動を「最初の記事タップ」ではなく起動直後に済ませておく。
                // 初回描画とは競合させたくないので少しだけ遅らせる。
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    WebViewWarmer.prewarm()
                }
            }
            .onOpenURL { url in
                guard url.scheme == "yomi",
                      url.host == "open",
                      let urlString = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "url" })?.value else { return }
                let descriptor = FetchDescriptor<Article>(
                    predicate: #Predicate { $0.url == urlString }
                )
                widgetArticle = try? context.fetch(descriptor).first
            }
            .sheet(item: $widgetArticle) { article in
                NavigationStack {
                    ArticleWebView(article: article)
                }
            }
    }

    @ViewBuilder
    private var tabs: some View {
        if #available(iOS 26.0, *) {
            TabView {
                Tab("Latest", systemImage: "newspaper") {
                    LatestView()
                }
                Tab("Feeds", systemImage: "list.bullet") {
                    FeedsView()
                }
                Tab("Saved", systemImage: "bookmark") {
                    SavedView()
                }
                Tab(role: .search) {
                    SearchView()
                }
            }
        } else {
            TabView {
                LatestView()
                    .tabItem {
                        Label("Latest", systemImage: "newspaper")
                    }

                FeedsView()
                    .tabItem {
                        Label("Feeds", systemImage: "list.bullet")
                    }

                SavedView()
                    .tabItem {
                        Label("Saved", systemImage: "bookmark")
                    }

                SearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }
            }
        }
    }
}
