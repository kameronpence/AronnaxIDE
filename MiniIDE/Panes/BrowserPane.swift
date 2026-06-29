import SwiftUI
import WebKit

/// A minimal web browser: a navigation bar (back / forward / reload / URL field)
/// over a `WKWebView`. Used to view what the agents build — manual URLs now, and
/// the mini's forwarded localhost dev servers once the port-forward manager lands.
struct BrowserPane: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = BrowserModel()
    @ObservedObject private var forwards = PortForwardManager.shared
    @StateObject private var preview = PreviewWatcher()
    @State private var urlField = ""
    @State private var showForwards = false
    @State private var miniPort = ""
    @State private var forwardHostID = AppSettings.hubAlias
    @AppStorage("browser.autoPreview") private var autoPreview = true

    private var forwardHost: Host? {
        settings.hosts.first { $0.id == forwardHostID } ?? settings.hub
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider()
            WebView(webView: model.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.currentURL.isEmpty && !model.isLoading { emptyState }
                }
        }
        .onChange(of: model.currentURL) { _, newValue in
            // Keep the field in sync as navigation (links, redirects) changes the URL.
            urlField = newValue
        }
        .onAppear { preview.start(host: settings.hub, dir: settings.activePath) }
        .onDisappear { preview.stop() }
        .onChange(of: settings.selectedProjectPath) { _, _ in
            preview.start(host: settings.hub, dir: settings.activePath)
        }
        .onChange(of: preview.target) { _, target in
            // The agent pushed something — load it (when auto-preview is on).
            if autoPreview, let target { loadPreview(target) }
        }
    }

    /// Loads a target the agent wrote to `.miniide-preview`: a bare port, a localhost
    /// URL (forwarded through the hub), or a remote URL (loaded directly).
    private func loadPreview(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let port = Int(t), (1...65535).contains(port) {
            forwardAndLoad(port: port, suffix: "")
            return
        }
        guard let url = URL(string: t.contains("://") ? t : "http://\(t)"),
              let urlHost = url.host else { model.load(t); return }
        if ["localhost", "127.0.0.1", "::1"].contains(urlHost.lowercased()) {
            let scheme = url.scheme ?? "http"
            let port = url.port ?? (scheme == "https" ? 443 : 80)
            let suffix = url.path + (url.query.map { "?\($0)" } ?? "")
            forwardAndLoad(port: port, suffix: suffix, scheme: scheme)
        } else {
            model.load(t)   // already reachable — load directly
        }
    }

    /// Forward the hub's localhost:<port> (if not already) and load it, keeping the
    /// original scheme so an https dev server isn't loaded as http.
    private func forwardAndLoad(port: Int, suffix: String, scheme: String = "http") {
        let target = "\(scheme)://127.0.0.1:\(port)\(suffix)"
        if forwards.forwards.contains(where: { $0.localPort == port }) {
            model.load(target)
            return
        }
        guard let host = forwardHost else { return }
        Task {
            if await forwards.open(localPort: port, remotePort: port, on: host) != nil {
                model.load(target)
            }
        }
    }

    /// Shown before anything has loaded: how to view what the agents build.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "globe")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Nothing loaded yet").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label("Type a URL above and press Go", systemImage: "character.cursor.ibeam")
                Label("Or forward a mini dev server (its localhost port) to view what the agents build",
                      systemImage: "network")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Forward a mini dev server") { showForwards = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(maxWidth: 460)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
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

            // Manual "show it" when auto is off but the agent has pushed a preview.
            if !autoPreview, let target = preview.target {
                Button { loadPreview(target) } label: { Image(systemName: "sparkles") }
                    .help("Load the preview the agent pushed")
            }
            Toggle(isOn: $autoPreview) { Image(systemName: "wand.and.rays") }
                .toggleStyle(.button)
                .help("Auto-load previews the agents push to .miniide-preview")

            Button { showForwards.toggle() } label: { Image(systemName: "network") }
                .help("Forward a mini localhost port")
                .popover(isPresented: $showForwards, arrowEdge: .bottom) { forwardPanel }
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    /// Popover to forward a mini localhost port and list/open/close active forwards.
    private var forwardPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dev servers").font(.headline)
            if settings.hosts.count > 1 {
                Picker("Host", selection: $forwardHostID) {
                    ForEach(settings.hosts) { Text($0.displayName).tag($0.id) }
                }
                .labelsHidden()
                .help("Forward via this host (EC2/Lightsail hop through the hub)")
            }
            HStack {
                TextField("Port (e.g. 5173)", text: $miniPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit(openForward)
                Button("Open", action: openForward)
                    .disabled(Int(miniPort) == nil)
            }
            if let error = forwards.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !forwards.forwards.isEmpty {
                Divider()
                ForEach(forwards.forwards) { forward in
                    HStack(spacing: 6) {
                        Button("127.0.0.1:\(forward.localPort)") {
                            model.load("http://127.0.0.1:\(forward.localPort)")
                            showForwards = false
                        }
                        .buttonStyle(.link)
                        Text("→ mini:\(forward.remotePort)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { forwards.close(forward) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    /// Forward the selected host's localhost:<port> to the same local port and load
    /// it. Non-hub hosts hop through the hub via the host's ProxyJump.
    private func openForward() {
        guard let port = Int(miniPort), let host = forwardHost else { return }
        Task {
            if await forwards.open(localPort: port, remotePort: port, on: host) != nil {
                model.load("http://127.0.0.1:\(port)")
                miniPort = ""
                showForwards = false
            }
        }
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
