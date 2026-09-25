import SwiftUI
import WebKit

struct ArticleWebView: View {
    let article: Article
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var navigator = WebViewNavigator()

    /// The page currently on screen, not always the original article — the user
    /// may have followed links inside the WebView. Shared by Share and
    /// Open-in-browser so the two can never point at different URLs.
    private var currentPageURL: URL? {
        navigator.currentURL ?? URL(string: article.url)
    }

    var body: some View {
        WebViewRepresentable(
            url: URL(string: article.url),
            navigator: navigator
        )
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    FeedService.shared.setSaved(article: article, isSaved: !article.isSaved, context: context)
                } label: {
                    Image(systemName: article.isSaved ? "bookmark.fill" : "bookmark")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                // Safari-style bottom bar: back / forward grouped on the leading
                // side, share + reload + open-in-browser on the trailing side.
                Button {
                    navigator.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!navigator.canGoBack)

                Button {
                    navigator.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!navigator.canGoForward)

                Spacer()

                if let url = currentPageURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }

                Button {
                    navigator.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload")

                // Open in the user's default browser. `openURL` routes http/https
                // through whichever browser the user has set as default (iOS 14+),
                // so this respects Safari/Chrome/etc. rather than forcing Safari.
                // The label stays browser-neutral even though the glyph doesn't.
                if let url = currentPageURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "safari")
                    }
                    .accessibilityLabel("Open in Browser")
                }
            }
        }
        .overlay(alignment: .top) {
            // ロード時間そのものは縮められないが、進捗が見えるだけで待ち時間の体感は変わる。
            // Safari と同じく上端に細いバーを出し、読み終わったらフェードアウトさせる。
            // if で出し入れせず opacity で消すのは、アニメーションを
            // このバーだけに閉じ込めて WebView やツールバーを巻き込まないため。
            ProgressView(value: navigator.isLoading ? navigator.estimatedProgress : 1)
                .progressViewStyle(.linear)
                .opacity(navigator.isLoading ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: navigator.estimatedProgress)
                .animation(.easeOut(duration: 0.2), value: navigator.isLoading)
        }
        .onAppear {
            if !article.isRead {
                FeedService.shared.setRead(article: article, isRead: true, context: context)
            }
        }
    }
}

/// WKWebView の生成コストを記事タップの外に追い出すための温め処理。
///
/// アプリ内で最初に WKWebView を作るときは WebContent / Networking プロセスの起動が走り、
/// 実機でも数百 ms かかる。そのコストを「記事をタップした瞬間」ではなく起動直後に払っておく。
/// 一度起きたプロセスは WebKit 側でキャッシュされるため、次に作る web view が再利用する。
@MainActor
enum WebViewWarmer {
    private static var warmupWebView: WKWebView?
    private static var didPrewarm = false

    /// 起動直後に一度だけ呼ぶ。捨て web view を 1 つ作って WebKit のプロセスを起こす。
    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        let webView = WKWebView()
        webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        warmupWebView = webView
    }

    /// 記事用の web view ができれば温め役は役目を終える。常駐メモリを抱えないよう解放する。
    /// 起動 1 秒以内に記事が開かれた場合(Widget からの起動など)は、この後に prewarm が
    /// 来ても不要なので作らせない。
    static func releaseWarmup() {
        didPrewarm = true
        warmupWebView = nil
    }
}

/// Single source of truth for the WebView's navigation state. Holds a reference
/// to the live `WKWebView` so the toolbar can drive its history (`goBack` /
/// `goForward`), and exposes `canGoBack` / `canGoForward` as observable state so
/// the toolbar buttons enable/disable in step with the web view.
@Observable
final class WebViewNavigator {
    @ObservationIgnored fileprivate weak var webView: WKWebView?
    var canGoBack = false
    var canGoForward = false
    /// URL of the page currently displayed (tracks in-page link navigation).
    var currentURL: URL?
    /// Drives the Safari-style progress bar at the top of the sheet.
    var isLoading = false
    var estimatedProgress: Double = 0

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

struct WebViewRepresentable: UIViewRepresentable {
    let url: URL?
    let navigator: WebViewNavigator

    func makeCoordinator() -> Coordinator {
        Coordinator(navigator: navigator)
    }

    func makeUIView(context: Context) -> WKWebView {
        let navigator = self.navigator
        let webView = WKWebView()
        WebViewWarmer.releaseWarmup()

        // updateUIView ではなくここでロードを始める。updateUIView は SwiftUI が
        // シートのレイアウトを終えてから呼ばれるため、その分だけ最初のバイトが遅れていた。
        //
        // KVO の登録より前にロードするのは、load() が isLoading / url を同期的に変えるため。
        // SwiftUI の更新フェーズ中に observable state を書くと
        // "Modifying state during view update" になる。
        if let url {
            webView.load(URLRequest(url: url))
        }

        navigator.webView = webView
        context.coordinator.observe(webView)

        // 登録前に起きた変化を取りこぼさないよう、初期値だけ次の main-actor ターンで反映する。
        let isLoading = webView.isLoading
        let progress = webView.estimatedProgress
        let currentURL = webView.url
        Task { @MainActor in
            navigator.isLoading = isLoading
            navigator.estimatedProgress = progress
            if let currentURL {
                navigator.currentURL = currentURL
            }
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // ロードは makeUIView で一度だけ開始する。ここで url を見て読み直すと、
        // ページ内リンクをたどった後の canGoBack/canGoForward 更新(= updateUIView 再実行)で
        // 元の記事に引き戻され、戻る/進むが機能しなくなる。
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator {
        private let navigator: WebViewNavigator
        private var backObservation: NSKeyValueObservation?
        private var forwardObservation: NSKeyValueObservation?
        private var urlObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?
        private var progressObservation: NSKeyValueObservation?

        init(navigator: WebViewNavigator) {
            self.navigator = navigator
        }

        func observe(_ webView: WKWebView) {
            // No `.initial`: it fires synchronously during makeUIView (inside the
            // SwiftUI update phase) and mutating observable state there triggers a
            // "Modifying state during view update" warning. The navigator defaults
            // to false, which already matches a fresh web view's history.
            backObservation = webView.observe(\.canGoBack, options: [.new]) { [navigator] webView, _ in
                navigator.canGoBack = webView.canGoBack
            }
            forwardObservation = webView.observe(\.canGoForward, options: [.new]) { [navigator] webView, _ in
                navigator.canGoForward = webView.canGoForward
            }
            urlObservation = webView.observe(\.url, options: [.new]) { [navigator] webView, _ in
                navigator.currentURL = webView.url
            }
            loadingObservation = webView.observe(\.isLoading, options: [.new]) { [navigator] webView, _ in
                navigator.isLoading = webView.isLoading
            }
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [navigator] webView, _ in
                navigator.estimatedProgress = webView.estimatedProgress
            }
        }

        func stopObserving() {
            backObservation?.invalidate()
            forwardObservation?.invalidate()
            urlObservation?.invalidate()
            loadingObservation?.invalidate()
            progressObservation?.invalidate()
            backObservation = nil
            forwardObservation = nil
            urlObservation = nil
            loadingObservation = nil
            progressObservation = nil
        }
    }
}
