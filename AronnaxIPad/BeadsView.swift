import SwiftUI

/// A data pane showing the active project's beads (issues), grouped by status. Read-only for
/// v1 — reloads when the project (workdir) changes or on manual refresh. Each beads leaf owns
/// its own service over the shared SSH connection.
struct BeadsView: View {
    let workdir: String
    @StateObject private var service: BeadsService

    init(connection: SSHConnection, workdir: String) {
        self.workdir = workdir
        _service = StateObject(wrappedValue: BeadsService(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(uiColor: .systemBackground))
        // Reload when the project changes, and on first appearance.
        .task(id: workdir) { await service.load(workdir: workdir) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.grid.2x2").foregroundStyle(.secondary)
            Text("Beads").fontWeight(.semibold)
            if case .loaded = service.phase {
                Text("\(service.beads.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await service.load(workdir: workdir) } } label: {
                Image(systemName: "arrow.clockwise").frame(minWidth: 40, minHeight: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    @ViewBuilder private var content: some View {
        switch service.phase {
        case .idle, .loading:
            centered { ProgressView() }
        case .empty:
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No beads in this project").foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(message).foregroundStyle(.secondary)
                    Button("Retry") { Task { await service.load(workdir: workdir) } }
                        .buttonStyle(.bordered)
                }
            }
        case .loaded:
            List {
                ForEach(service.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.beads) { bead in BeadRow(bead: bead) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BeadRow: View {
    let bead: Bead

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(bead.priorityLabel)
                .font(.caption2.monospaced().bold())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(priorityColor.opacity(0.18), in: Capsule())
                .foregroundStyle(priorityColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(bead.title).font(.callout).lineLimit(2)
                HStack(spacing: 6) {
                    Text(bead.id).font(.caption2.monospaced())
                    Text(bead.issueType).font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var priorityColor: Color {
        switch bead.priority {
        case 0: return .red
        case 1: return .orange
        case 2: return .blue
        default: return .secondary
        }
    }
}
