import SwiftUI

/// Per-project git status on the hub: branch, ahead/behind, dirty count, the GitHub
/// identity (owner) it pushes under, and recent commits. Read-only for now —
/// commit/push/deploy actions land next.
struct GitDeployPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = GitPanelModel()

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
            if !model.projects.isEmpty {
                Picker("Project", selection: $model.selectedPath) {
                    ForEach(model.projects) { p in Text(p.name).tag(p.path as String?) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.isLoading)
                .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if let error = model.error {
            message(error, system: "exclamationmark.triangle")
        } else if model.projects.isEmpty && !model.isLoading {
            message("No git projects found.", system: "folder")
        } else if let status = model.status {
            statusView(status)
        } else {
            message(model.isLoading ? "Loading…" : "Select a project.", system: "arrow.triangle.branch")
        }
    }

    private func statusView(_ s: GitStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Label(s.branch ?? "—", systemImage: "arrow.triangle.branch")
                        .font(.title3.weight(.semibold))
                    if let owner = s.owner {
                        Text(owner)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }

                HStack(spacing: 10) {
                    if !s.dirtyKnown {
                        stateChip("status unavailable", system: "questionmark.circle", tint: .secondary)
                    } else {
                        stateChip(s.isClean ? "clean" : "\(s.dirty) changed",
                                  system: s.isClean ? "checkmark.circle" : "pencil.circle",
                                  tint: s.isClean ? .green : .orange)
                    }
                    if s.ahead > 0 { stateChip("\(s.ahead) ahead", system: "arrow.up.circle", tint: .blue) }
                    if s.behind > 0 { stateChip("\(s.behind) behind", system: "arrow.down.circle", tint: .blue) }
                }

                if let remote = s.remote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("origin").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(maskedRemote(remote)).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }

                if !s.commits.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent commits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(s.commits, id: \.self) { c in
                            Text(c).font(.callout.monospaced()).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func stateChip(_ text: String, system: String, tint: Color) -> some View {
        Label(text, systemImage: system)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    /// Strip any `user[:password/token]@` userinfo from an HTTPS remote so embedded
    /// credentials are never shown. SSH remotes (`git@github.com:…`) are unaffected.
    private func maskedRemote(_ remote: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "://[^@/]+@") else { return remote }
        return re.stringByReplacingMatches(
            in: remote, range: NSRange(remote.startIndex..., in: remote), withTemplate: "://")
    }

    private func message(_ text: String, system: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: system).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

@MainActor
final class GitPanelModel: ObservableObject {
    @Published var projects: [DiscoveredProject] = []
    @Published var selectedPath: String? {
        didSet { if oldValue != selectedPath { status = nil; loadStatus() } }
    }
    @Published var status: GitStatus?
    @Published var isLoading = false
    @Published var error: String?

    private var host: Host?
    private var root = ""
    private var started = false
    private var statusToken = 0

    func start(host: Host?, root: String) {
        guard !started else { return }
        started = true
        self.host = host
        self.root = root
        Task { await loadProjects() }
    }

    func refresh() {
        Task {
            await loadProjects()
            loadStatus()   // reload status for the current selection (no-op if none)
        }
    }

    private func loadProjects() async {
        guard let host else { return }
        isLoading = true
        error = nil
        guard let found = await ProjectService.discover(host: host, root: root) else {
            error = "Couldn't list projects on the host."
            isLoading = false
            return
        }
        projects = found
        if let sel = selectedPath, found.contains(where: { $0.path == sel }) {
            isLoading = false   // selection still valid; caller reloads its status
        } else if let first = found.first?.path {
            selectedPath = first   // didSet → loadStatus, which keeps isLoading until it finishes
        } else {
            selectedPath = nil
            status = nil
            isLoading = false
        }
    }

    func loadStatus() {
        guard let host, let path = selectedPath else { return }
        statusToken += 1
        let token = statusToken
        isLoading = true
        error = nil
        Task {
            do {
                let s = try await GitController(host: host).status(path: path)
                guard token == statusToken else { return }
                status = s
            } catch {
                guard token == statusToken else { return }
                status = nil
                self.error = error.localizedDescription
            }
            guard token == statusToken else { return }
            isLoading = false
        }
    }
}
