import SwiftUI

/// Issue filters mapped to bd queries / statuses.
enum BeadsFilter: String, CaseIterable, Identifiable {
    case all, ready, open, active, blocked, closed
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:     return "All"
        case .ready:   return "Ready"
        case .open:    return "Open"
        case .active:  return "Active"
        case .blocked: return "Blocked"
        case .closed:  return "Closed"
        }
    }

    /// The bd query (subcommand + flags) this filter maps to. bd does the filtering;
    /// note `blocked` uses `bd blocked` (dependency-blocked), distinct from a stored
    /// "blocked" status, and `all` uses `--all` so closed issues are included.
    var bdArguments: [String] {
        // `--limit 0` = unlimited (bd's list/ready default to 50/100 and would
        // silently truncate). `bd blocked` has no --limit flag.
        // `--flat` keeps the JSON a flat array of every issue (not a nested tree);
        // `--limit 0` = unlimited. `bd ready`/`bd blocked` take neither/only some.
        switch self {
        case .all:     return ["list", "--all", "--flat", "--limit", "0"]
        case .ready:   return ["ready", "--limit", "0"]
        case .open:    return ["list", "--status", "open", "--flat", "--limit", "0"]
        case .active:  return ["list", "--status", "in_progress", "--flat", "--limit", "0"]
        case .blocked: return ["blocked"]
        case .closed:  return ["list", "--status", "closed", "--flat", "--limit", "0"]
        }
    }
}

/// The Beads panel: per-project bd issues on the hub, shared with the agents.
struct BeadsPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = BeadsModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { model.start(host: settings.hub, root: settings.agentWorkdir) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.projects.count > 1 {
                Picker("Project", selection: $model.selectedProjectPath) {
                    ForEach(model.projects) { p in Text(p.name).tag(p.path as String?) }
                }
                .labelsHidden()
                .fixedSize()
            } else if let only = model.projects.first {
                Text(only.name).font(.callout.weight(.medium))
            }

            Picker("Filter", selection: $model.filter) {
                ForEach(BeadsFilter.allCases) { f in Text(f.label).tag(f) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            if model.isLoading { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isLoading)
                .help("Refresh")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var content: some View {
        if let error = model.error {
            message(error, system: "exclamationmark.triangle")
        } else if model.projects.isEmpty && !model.isLoading {
            message("No bd projects found under \(settings.agentWorkdir).",
                    system: "point.3.connected.trianglepath.dotted")
        } else if model.issues.isEmpty && !model.isLoading {
            message("No issues for this filter.", system: "checklist")
        } else {
            List(model.issues) { issue in BdIssueRow(issue: issue) }
                .listStyle(.inset)
        }
    }

    private func message(_ text: String, system: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: system)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct BdIssueRow: View {
    let issue: BdIssue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).lineLimit(1)
                HStack(spacing: 6) {
                    Text(issue.id)
                    Text("P\(issue.priority)")
                    Text(issue.issueType)
                    if let b = issue.blockedByCount, b > 0 {
                        Label("\(b)", systemImage: "lock.fill")
                    } else if let d = issue.dependencyCount, d > 0 {
                        Label("\(d)", systemImage: "arrow.up.forward")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: String {
        switch issue.status {
        case "closed":      return "checkmark.circle.fill"
        case "in_progress": return "clock.fill"
        case "blocked":     return "exclamationmark.octagon.fill"
        default:            return "circle"
        }
    }

    private var statusColor: Color {
        switch issue.status {
        case "closed":      return .green
        case "in_progress": return .blue
        case "blocked":     return .orange
        default:            return .secondary
        }
    }
}

@MainActor
final class BeadsModel: ObservableObject {
    @Published var projects: [BdProject] = []
    @Published var selectedProjectPath: String? {
        didSet { if oldValue != selectedProjectPath { reload() } }
    }
    @Published var filter: BeadsFilter = .all {
        didSet { if oldValue != filter { reload() } }
    }
    @Published var issues: [BdIssue] = []
    @Published var isLoading = false
    @Published var error: String?

    private var host: Host?
    private var root = ""
    private var started = false
    private var reloadToken = 0

    func start(host: Host?, root: String) {
        guard !started else { return }
        started = true
        self.host = host
        self.root = root
        Task { await discover() }
    }

    /// The refresh button: re-run project discovery when there are none yet (e.g.
    /// the hub was unreachable on first load), otherwise reload the current project.
    func refresh() {
        if projects.isEmpty {
            Task { await discover() }
        } else {
            reload()
        }
    }

    func reload() {
        guard let host, let path = selectedProjectPath else { return }
        let args = filter.bdArguments
        reloadToken += 1
        let token = reloadToken
        isLoading = true
        error = nil
        Task {
            do {
                let items = try await BeadsController(host: host).issues(in: path, arguments: args)
                guard token == reloadToken else { return }   // a newer reload superseded this
                self.issues = items.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
            } catch {
                guard token == reloadToken else { return }
                self.issues = []
                self.error = error.localizedDescription
            }
            guard token == reloadToken else { return }
            self.isLoading = false
        }
    }

    private func discover() async {
        guard let host else {
            error = "No hub host configured."
            return
        }
        isLoading = true
        error = nil
        do {
            let found = try await BeadsController(host: host).discoverProjects(under: root)
            self.projects = found
            // Setting this triggers reload() via didSet when non-nil.
            self.selectedProjectPath = found.first?.path
            if found.isEmpty { self.isLoading = false }
        } catch {
            self.error = error.localizedDescription
            self.isLoading = false
        }
    }
}
