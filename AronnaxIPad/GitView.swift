import SwiftUI

/// A data pane showing the active project's git state — branch, ahead/behind, working-tree
/// changes, and recent commits. Read-only for v1. Reloads on project switch or manual refresh.
struct GitView: View {
    let workdir: String
    @StateObject private var service: GitService

    init(connection: SSHConnection, workdir: String) {
        self.workdir = workdir
        _service = StateObject(wrappedValue: GitService(connection: connection))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: workdir) { await service.load(workdir: workdir) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            if case .loaded = service.phase, !service.info.branch.isEmpty {
                Text(service.info.branch).fontWeight(.semibold).lineLimit(1)
                if service.info.hasUpstream {
                    aheadBehind
                }
            } else {
                Text("Git").fontWeight(.semibold)
            }
            Spacer()
            Button { Task { await service.load(workdir: workdir) } } label: {
                Image(systemName: "arrow.clockwise").frame(minWidth: 40, minHeight: 40)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    @ViewBuilder private var aheadBehind: some View {
        HStack(spacing: 6) {
            if service.info.ahead > 0 {
                Label("\(service.info.ahead)", systemImage: "arrow.up")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.green)
            }
            if service.info.behind > 0 {
                Label("\(service.info.behind)", systemImage: "arrow.down")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
            }
            if service.info.ahead == 0 && service.info.behind == 0 {
                Text("up to date").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private var content: some View {
        switch service.phase {
        case .idle, .loading:
            centered { ProgressView() }
        case .empty:
            centered {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Not a git repository").foregroundStyle(.secondary)
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
                Section("Changes (\(service.info.changes.count))") {
                    if service.info.changes.isEmpty {
                        Text("Working tree clean").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(service.info.changes) { change in ChangeRow(change: change) }
                    }
                }
                Section("Recent commits") {
                    ForEach(service.info.commits) { commit in CommitRow(commit: commit) }
                }
            }
            .listStyle(.plain)
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChangeRow: View {
    let change: GitChange
    var body: some View {
        HStack(spacing: 8) {
            Text(change.code.replacingOccurrences(of: " ", with: "·"))
                .font(.caption2.monospaced().bold())
                .foregroundStyle(.blue)
            Text(change.path).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(change.label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

private struct CommitRow: View {
    let commit: GitCommit
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(commit.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Text(commit.subject).font(.callout).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }
}
