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
    @State private var showingCreate = false
    @State private var selectedIssue: BdIssue?
    @State private var viewMode: BeadsViewMode = .list

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { model.start(host: settings.hub, root: settings.agentWorkdir) }
        .sheet(isPresented: $showingCreate) {
            BdCreateSheet { title, type, priority, description in
                model.create(title: title, type: type, priority: priority, description: description)
            }
        }
        .sheet(item: $selectedIssue) { issue in
            BdIssueDetailSheet(
                issue: issue,
                onUpdate: { fields in model.update(id: issue.id, fields: fields) },
                onClose: { model.close(id: issue.id) },
                onReopen: { model.reopen(id: issue.id) },
                onAddNote: { text in model.addNote(id: issue.id, text: text) }
            )
        }
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

            Picker("View", selection: $viewMode) {
                Image(systemName: "list.bullet").tag(BeadsViewMode.list)
                Image(systemName: "point.3.connected.trianglepath.dotted").tag(BeadsViewMode.graph)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            if model.isLoading { ProgressView().controlSize(.small) }
            Button { showingCreate = true } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(model.selectedProjectPath == nil)
                .help("New issue")
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
        } else if viewMode == .graph {
            if let source = MermaidGraph.source(from: model.issues) {
                DependencyGraphView(source: source)
            } else {
                message("No dependencies among these issues — try the All filter.",
                        system: "point.3.connected.trianglepath.dotted")
            }
        } else {
            List(model.issues) { issue in
                Button { selectedIssue = issue } label: { BdIssueRow(issue: issue) }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
            }
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

/// Sheet for creating a new bd issue.
private struct BdCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (_ title: String, _ type: String, _ priority: Int, _ description: String) -> Void

    @State private var title = ""
    @State private var type = "task"
    @State private var priority = 2
    @State private var description = ""

    private let types = ["task", "bug", "feature", "epic", "chore"]

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Issue").font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 16) {
                Picker("Type", selection: $type) {
                    ForEach(types, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Priority", selection: $priority) {
                    ForEach(0..<5) { Text("P\($0)").tag($0) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Description").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $description)
                    .frame(height: 90)
                    .border(Color(nsColor: .separatorColor))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    onCreate(trimmedTitle, type, priority,
                             description.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedTitle.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// Sheet showing an issue with quick status/priority actions.
private struct BdIssueDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let issue: BdIssue
    let onUpdate: (_ fields: [String]) -> Void
    let onClose: () -> Void
    let onReopen: () -> Void
    let onAddNote: (_ text: String) -> Void

    @State private var note = ""

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(issue.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(issue.status).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }

            Text(issue.title).font(.headline)

            HStack(spacing: 8) {
                Text("P\(issue.priority)")
                Text(issue.issueType)
            }
            .font(.caption).foregroundStyle(.secondary)

            if let d = issue.description, !d.isEmpty {
                ScrollView {
                    Text(d).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Add a note…", text: $note)
                    .textFieldStyle(.roundedBorder)
                Button("Add Note") { onAddNote(trimmedNote); dismiss() }
                    .disabled(trimmedNote.isEmpty)
            }

            HStack(spacing: 10) {
                if issue.status == "closed" {
                    Button("Reopen") { onReopen(); dismiss() }
                } else {
                    if issue.status != "in_progress" {
                        Button("Start") { onUpdate(["--status", "in_progress"]); dismiss() }
                    }
                    Button("Close") { onClose(); dismiss() }
                }
                Menu("Priority") {
                    ForEach(0..<5) { p in
                        Button("P\(p)") { onUpdate(["--priority", String(p)]); dismiss() }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
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

    /// Run a bd mutation against the selected project, then refresh on success.
    private func mutate(_ work: @escaping (BeadsController, String) async throws -> Void) {
        guard let host, let path = selectedProjectPath else { return }
        error = nil
        Task {
            do {
                try await work(BeadsController(host: host), path)
                reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func create(title: String, type: String, priority: Int, description: String) {
        mutate { try await $0.create(in: $1, title: title, type: type,
                                     priority: priority, description: description) }
    }

    func update(id: String, fields: [String]) {
        mutate { try await $0.update(in: $1, id: id, fields: fields) }
    }

    func close(id: String) {
        mutate { try await $0.close(in: $1, id: id) }
    }

    func reopen(id: String) {
        mutate { try await $0.reopen(in: $1, id: id) }
    }

    func addNote(id: String, text: String) {
        mutate { try await $0.addNote(in: $1, id: id, text: text) }
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
