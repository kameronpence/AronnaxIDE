import SwiftUI

/// A data pane showing kepler's health: running agent (Claude/Codex) tmux sessions mapped to
/// their projects, other sessions, and host load. Host-level and read-only for v1.
struct HealthView: View {
    // Observed so the agent→project reverse-map refreshes once project discovery completes:
    // at cold start `projects` is just "kepler root", so a first load would label sessions
    // "unknown project" until they arrive.
    @ObservedObject var connection: SSHConnection
    @StateObject private var service: HealthService

    init(connection: SSHConnection) {
        _connection = ObservedObject(wrappedValue: connection)
        _service = StateObject(wrappedValue: HealthService(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(uiColor: .systemBackground))
        .task { await service.load() }
        .onChange(of: connection.projects) { _, _ in Task { await service.load() } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg").foregroundStyle(.secondary)
            Text("Health").fontWeight(.semibold)
            Spacer()
            Button { Task { await service.load() } } label: {
                Image(systemName: "arrow.clockwise").frame(minWidth: 40, minHeight: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    @ViewBuilder private var content: some View {
        switch service.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { Task { await service.load() } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            List {
                if !service.uptime.isEmpty {
                    Section("Host") {
                        Label(service.uptime, systemImage: "cpu")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Section("Agents (\(service.agentSessions.count))") {
                    if service.agentSessions.isEmpty {
                        Text("No agent sessions running").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(service.agentSessions) { SessionRow(session: $0) }
                    }
                }
                if !service.otherSessions.isEmpty {
                    Section("Other sessions") {
                        ForEach(service.otherSessions) { SessionRow(session: $0) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

private struct SessionRow: View {
    let session: HealthSession

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.attached ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).lineLimit(1)
                if session.isAgent {
                    Text(session.name).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(session.attached ? "attached" : "detached")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private var title: String {
        if let agent = session.agent {
            return "\(agent) · \(session.project ?? "unknown project")"
        }
        return session.name
    }
}
