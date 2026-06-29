import SwiftUI

/// At-a-glance fleet health: each host's reachability and, for the hub, the tmux
/// sessions that are alive (the shell + per-project agents).
struct HostHealthPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var health = HealthController()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(health.hosts) { host in
                    hostRow(host)
                }
            }
            .listStyle(.inset)
        }
        .onAppear { health.start(hosts: settings.hosts) }
        .onDisappear { health.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Fleet Health").font(.headline)
            Spacer()
            if let updated = health.lastUpdated {
                Text("updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if health.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button { health.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh now")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func hostRow(_ host: HealthController.HostHealth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(dotColor(host.reachable)).frame(width: 10, height: 10)
                Label(host.name, systemImage: host.isHub ? "server.rack" : "cloud")
                    .font(.body.weight(.medium))
                Spacer()
                Text(reachabilityText(host.reachable))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(dotColor(host.reachable))
            }

            if host.isHub, host.reachable == true {
                if host.sessions.isEmpty {
                    Text("No tmux sessions running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                } else {
                    sessionChips(host.sessions)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sessionChips(_ sessions: [String]) -> some View {
        FlowChips(items: sessions) { name in
            Label(name, systemImage: sessionIcon(name))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private func sessionIcon(_ name: String) -> String {
        if name.hasPrefix("agent-") { return "sparkles" }
        if name == "main" { return "terminal" }
        return "rectangle.split.3x1"
    }

    private func dotColor(_ reachable: Bool?) -> Color {
        switch reachable {
        case .some(true):  return .green
        case .some(false): return .red
        case .none:        return .yellow
        }
    }

    private func reachabilityText(_ reachable: Bool?) -> String {
        switch reachable {
        case .some(true):  return "reachable"
        case .some(false): return "unreachable"
        case .none:        return "checking…"
        }
    }
}

/// A simple wrapping row of chips (SwiftUI has no built-in flow layout pre-iOS16
/// `Layout`, and this keeps the chips readable when there are several sessions).
private struct FlowChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { content($0) }
                }
            }
        }
    }

    /// Chunk into rows of up to 4 so a long session list stays tidy.
    private var rows: [[Item]] {
        stride(from: 0, to: items.count, by: 4).map {
            Array(items[$0..<min($0 + 4, items.count)])
        }
    }
}
