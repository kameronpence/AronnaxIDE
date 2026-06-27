import SwiftUI
import WebKit

/// A minimal web browser: a navigation bar (back / forward / reload / URL field)
/// over a `WKWebView`. Used to view what the agents build — manual URLs now, and
/// the mini's forwarded localhost dev servers once the port-forward manager lands.
struct BrowserPane: View {
    @StateObject private var model = BrowserModel()
    @State private var urlField = ""

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            WebView(webView: model.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.currentURL) { _, newValue in
            // Keep the field in sync as navigation (links, redirects) changes the URL.
            urlField = newValue
        }
    }

    private var navBar: some View {
        HStack(spacing: 6) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            Button { model.reloadOrStop() } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }

            TextField("Enter a URL", text: $urlField)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.load(urlField) }

            Button("Go") { model.load(urlField) }
                .disabled(urlField.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }
}

/// Owns the `WKWebView` and publishes the navigation state the bar binds to.
@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var currentURL = ""

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    /// Load `text` as a URL, prefixing `http://` when no scheme is given so a bare
    /// `localhost:5173` or `example.com` works.
    func load(_ text: String) {
        guard let url = Self.normalizedURL(text) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    /// Turns user input into a URL. Anything with a scheme passes through. For a
    /// bare host, localhost / LAN dev servers get `http://` (ATS permits local
    /// http, and dev servers usually serve http); public hosts default to
    /// `https://` so ATS doesn't block the load before the site can redirect.
    /// Returns nil for empty/garbage input.
    static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return URL(string: trimmed) }
        let host = hostComponent(of: trimmed)
        let scheme = isLocalHost(host) ? "http" : "https"
        // A bare (unbracketed) IPv6 literal must be bracketed to form a valid URL.
        if host.contains(":") && !trimmed.hasPrefix("[") {
            let bracketed = trimmed.replacingOccurrences(of: host, with: "[\(host)]")
            return URL(string: "\(scheme)://\(bracketed)")
        }
        return URL(string: "\(scheme)://\(trimmed)")
    }

    /// The host of a bare `host[:port][/path]` authority, handling bracketed
    /// (`[::1]:5173`) and bare (`::1`) IPv6 literals as well as `host:port`.
    private static func hostComponent(of input: String) -> String {
        let authority = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            return String(authority[authority.index(after: authority.startIndex)..<close])
        }
        // A bare IPv6 literal has multiple colons and carries no port; use it whole.
        if authority.filter({ $0 == ":" }).count > 1 {
            return authority
        }
        return authority.split(separator: ":").first.map(String.init) ?? authority
    }

    /// Hosts that should default to http: localhost, IPv6 loopback, `*.local`, and
    /// loopback / private / link-local IPv4 ranges (LAN & forwarded dev servers).
    /// Public IPv4 literals fall through to https so ATS doesn't block them.
    private static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()   // DNS is case-insensitive
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254), (172, 16...31):
            return true
        default:
            return false   // public IPv4 -> https
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
        canGoForward = webView.canGoForward
        if let url = webView.url?.absoluteString {
            currentURL = url
        }
    }
}

/// SwiftUI wrapper that hosts the model's `WKWebView`.
private struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
