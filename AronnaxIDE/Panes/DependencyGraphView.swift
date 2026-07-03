import SwiftUI
import WebKit

/// List vs. dependency-graph display of the Beads panel.
enum BeadsViewMode: Hashable {
    case list
    case graph
}

/// Builds a Mermaid `graph` definition from the dependency edges among a set of
/// issues. Only edges whose both endpoints are in the set are drawn (no dangling
/// edges to filtered-out issues).
enum MermaidGraph {
    /// The mermaid source, or nil when there are no edges among `issues`.
    static func source(from issues: [BdIssue]) -> String? {
        let ids = Set(issues.map(\.id))
        var edges: [(from: String, to: String)] = []
        var seen = Set<String>()
        for issue in issues {
            for dep in issue.dependencies ?? [] {
                guard ids.contains(dep.dependsOnId), ids.contains(dep.issueId) else { continue }
                let key = "\(dep.dependsOnId)->\(dep.issueId)"
                if seen.insert(key).inserted {
                    edges.append((dep.dependsOnId, dep.issueId))   // dependsOn blocks issue
                }
            }
        }
        guard !edges.isEmpty else { return nil }

        let byId = Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var nodeIds = Set<String>()
        for edge in edges { nodeIds.insert(edge.from); nodeIds.insert(edge.to) }

        var lines = ["graph LR"]
        for id in nodeIds.sorted() {
            let title = byId[id]?.title ?? ""
            let label = title.isEmpty ? id : "\(id): \(title)"
            lines.append("  \(nodeName(id))[\"\(sanitize(label))\"]")
        }
        for edge in edges {
            lines.append("  \(nodeName(edge.from)) --> \(nodeName(edge.to))")
        }
        return lines.joined(separator: "\n")
    }

    /// A mermaid-safe node identifier (only letters/digits/underscore).
    private static func nodeName(_ id: String) -> String {
        "n_" + id.map { ($0.isLetter || $0.isNumber) ? String($0) : "_" }.joined()
    }

    /// Makes a label safe for both mermaid and the surrounding HTML (no quotes,
    /// brackets, or HTML metacharacters), truncated so nodes stay compact.
    private static func sanitize(_ s: String) -> String {
        String(s.prefix(44))
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "<", with: "(")
            .replacingOccurrences(of: ">", with: ")")
            .replacingOccurrences(of: "&", with: "+")
    }
}

/// Renders a Mermaid dependency graph in a WebView (mermaid.js from a CDN).
struct DependencyGraphView: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.loadHTMLString(Self.html(source),
                           baseURL: URL(string: "https://cdn.jsdelivr.net/"))
    }

    private static func html(_ source: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
        <style>
          body { margin: 0; font-family: -apple-system, system-ui, sans-serif; }
          .mermaid { padding: 16px; }
        </style>
        </head><body>
        <pre class="mermaid">
        \(source)
        </pre>
        <script>mermaid.initialize({ startOnLoad: true, theme: 'neutral', securityLevel: 'loose' });</script>
        </body></html>
        """
    }
}
