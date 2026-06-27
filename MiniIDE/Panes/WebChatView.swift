import SwiftUI
import WebKit

/// One of the subscription web chats hosted in the "Chat" pane.
enum WebChat: String, CaseIterable, Identifiable {
    case claude
    case chatgpt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude:  return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }

    var url: URL {
        switch self {
        case .claude:  return URL(string: "https://claude.ai")!
        case .chatgpt: return URL(string: "https://chatgpt.com")!
        }
    }

    /// Stable identifier for this site's persistent, isolated website data store, so
    /// the login survives relaunches and the two sites don't share cookies.
    var storeID: UUID {
        switch self {
        case .claude:  return UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        case .chatgpt: return UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        }
    }
}

/// A `WKWebView` pinned to one chat site, with a **persistent, per-site** data store
/// so the subscription login sticks across launches. A desktop-Safari user agent
/// keeps the sites from treating it as an odd embedded webview. Minimal chrome:
/// back + reload (no URL bar — the site is fixed).
struct WebChatView: View {
    @StateObject private var model: WebChatModel

    init(chat: WebChat) {
        _model = StateObject(wrappedValue: WebChatModel(chat: chat))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                Button { model.reloadOrStop() } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            WebChatContainer(webView: model.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Owns the configured `WKWebView` and publishes the navigation state the bar binds
/// to. Loads the chat site once on creation.
@MainActor
final class WebChatModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    @Published var canGoBack = false
    @Published var isLoading = false

    init(chat: WebChat) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: chat.storeID)
        let webView = WKWebView(frame: .zero, configuration: config)
        // A normal desktop Safari UA so the chat sites render/let you log in as usual.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        self.webView = webView
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.load(URLRequest(url: chat.url))
    }

    /// Sign-in flows often open the OAuth provider via `window.open` / `target="_blank"`.
    /// WebKit drops such new-window requests unless a UI delegate handles them, which
    /// would strand the user mid-login — so load them in this same web view instead.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            // Load the original request as-is so a POST/SSO body and headers survive.
            webView.load(navigationAction.request)
        }
        return nil
    }

    func goBack() { webView.goBack() }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        syncState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        syncState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        syncState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncState()
    }

    private func syncState() {
        canGoBack = webView.canGoBack
    }
}

/// SwiftUI wrapper hosting the model's `WKWebView`.
private struct WebChatContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
