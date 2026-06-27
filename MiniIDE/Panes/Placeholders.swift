import SwiftUI

/// Shared "coming soon" scaffold for panes not yet implemented.
struct ComingSoon: View {
    let title: String
    let systemImage: String
    let milestone: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2).bold()
            Text(milestone)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15),
                            in: Capsule())
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct BeadsPanel: View {
    var body: some View {
        ComingSoon(
            title: "Beads",
            systemImage: "point.3.connected.trianglepath.dotted",
            milestone: "M7",
            detail: "Issue list, ready/blocked status, and a dependency graph from "
                + "the mini's bd database — shared with the agents."
        )
    }
}

struct LogViewer: View {
    var body: some View {
        ComingSoon(
            title: "Remote Logs",
            systemImage: "list.bullet.rectangle",
            milestone: "M9",
            detail: "Stream logs from any host (file / journalctl / pm2 / docker) "
                + "with live filtering — handy for prod log analysis."
        )
    }
}

struct GitDeployPanel: View {
    var body: some View {
        ComingSoon(
            title: "Git / Deploy",
            systemImage: "arrow.triangle.branch",
            milestone: "M10",
            detail: "Per-project branch/state and the correct GitHub identity, with "
                + "a mismatch warning before any push."
        )
    }
}
