import SwiftUI

/// Per-project git status on the hub: branch, ahead/behind, dirty count, the GitHub
/// identity (owner) it pushes under, and recent commits. Read-only for now —
/// commit/push/deploy actions land next.
struct GitDeployPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = GitPanelModel()
    @State private var commitMessage = ""
    @State private var showPushConfirm = false
    @State private var commitSearch = ""
    @State private var pendingWrite: WriteRequest?

    private var hubReadOnly: Bool { settings.isReadOnly(settings.activeHost) }

    /// Run a write now, or stage it for confirmation when "Confirm before every write" is on.
    private func requestWrite(_ title: String, _ perform: @escaping () -> Void) {
        if settings.confirmWrites { pendingWrite = WriteRequest(title: title, perform: perform) }
        else { perform() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            model.start(host: settings.activeHost)
            model.selectedPath = settings.selectedProjectPath
        }
        .onChange(of: settings.selectedProjectPath) { _, new in
            model.selectedPath = new
        }
        .onChange(of: settings.activeHostID) { _, _ in
            model.setHost(settings.activeHost)
        }
        .alert("Push to GitHub?", isPresented: $showPushConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Push") { model.push() }
        } message: {
            Text(pushWarning)
        }
        .writeConfirm($pendingWrite)
    }

    /// A likely wrong-account push: the identity the repo pushes as doesn't match the
    /// repo's owner. The convention is that each repo pushes under its own owner
    /// (personal repos as the personal account, org repos as the org), so a difference
    /// is a strong signal the wrong account is configured.
    private func accountMismatch(_ s: GitStatus) -> (identity: String, owner: String)? {
        guard let identity = GitController.identity(remote: s.remote),
              let owner = s.owner,
              identity.caseInsensitiveCompare(owner) != .orderedSame else { return nil }
        return (identity, owner)
    }

    /// Surfaces the branch + the GitHub account the push goes out as — and a prominent
    /// warning when that account doesn't match the repo owner — so a wrong-account push
    /// is caught at confirm time.
    private var pushWarning: String {
        let branch = model.status?.branch ?? "the branch"
        let account = GitController.identity(remote: model.status?.remote)
            .map { " as \($0)" } ?? ""
        let remote = model.status?.remote.map { " (\(maskedRemote($0)))" } ?? ""
        var prefix = ""
        if let s = model.status, let mismatch = accountMismatch(s) {
            prefix = "⚠️ WRONG ACCOUNT? This repo is owned by \(mismatch.owner) but is set "
                + "to push as \(mismatch.identity).\n\n"
        }
        return prefix + "Pushes \(branch)\(account) to origin\(remote).\n\nThis triggers "
            + "your GitHub Actions deploy if configured — make sure this is the right "
            + "account before pushing."
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let name = settings.selectedProjectName {
                Text(name).font(.callout.weight(.medium))
            }
            TextField("Search commits", text: $commitSearch)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .onSubmit { model.searchCommits(commitSearch) }
                .onChange(of: commitSearch) { _, q in
                    if q.trimmingCharacters(in: .whitespaces).isEmpty { model.searchCommits("") }
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
        if model.selectedPath == nil {
            message("Select a project in the sidebar.", system: "folder")
        } else if let error = model.error {
            message(error, system: "exclamationmark.triangle")
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
                    Image(systemName: "arrow.triangle.branch").font(.title3)
                    if model.branches.count > 1 {
                        Picker("Branch", selection: Binding(
                            get: { s.branch ?? "" },
                            set: { branch in requestWrite("Check out \(branch)?") { model.checkout(branch) } }
                        )) {
                            ForEach(model.branches, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(hubReadOnly || model.actionBusy)
                    } else {
                        Text(s.branch ?? "—").font(.title3.weight(.semibold))
                    }
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

                if let mismatch = accountMismatch(s) {
                    Label("Pushes as \(mismatch.identity), but this repo is owned by \(mismatch.owner) — likely the wrong account.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if let remote = s.remote {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("origin").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(maskedRemote(remote)).font(.callout.monospaced()).textSelection(.enabled)
                        if let identity = GitController.identity(remote: remote) {
                            Text("pushes as \(identity)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let results = model.commitResults {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search results (\(results.count))")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if results.isEmpty {
                            Text("No commits match “\(commitSearch)”")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            ForEach(results, id: \.self) { c in
                                Text(c).font(.callout.monospaced()).lineLimit(1).textSelection(.enabled)
                            }
                        }
                    }
                } else if !s.commits.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent commits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(s.commits, id: \.self) { c in
                            Text(c).font(.callout.monospaced()).lineLimit(1)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if hubReadOnly {
                        Label("\(settings.activeHost?.sshAlias ?? "Host") is read-only — commit/push/checkout are disabled.",
                              systemImage: "lock.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        TextField("Commit message", text: $commitMessage)
                            .textFieldStyle(.roundedBorder)
                        Button("Commit") {
                            let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            requestWrite("Commit “\(msg)”?") {
                                model.commit(message: msg); commitMessage = ""
                            }
                        }
                        .disabled(hubReadOnly || model.actionBusy || s.isClean
                                  || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    HStack(spacing: 10) {
                        Button { showPushConfirm = true } label: { Label("Push", systemImage: "arrow.up.circle") }
                            .disabled(hubReadOnly || model.actionBusy)
                        if model.actionBusy { ProgressView().controlSize(.small) }
                        if let msg = model.actionMessage {
                            Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }

                if !model.runs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GitHub Actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(model.runs) { run in runRow(run) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func runRow(_ run: ActionRun) -> some View {
        HStack(spacing: 8) {
            Image(systemName: runIcon(run)).foregroundStyle(runColor(run))
            VStack(alignment: .leading, spacing: 1) {
                Text(run.workflowName).font(.callout).lineLimit(1)
                Text([run.headBranch, run.conclusion ?? run.status].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func runIcon(_ run: ActionRun) -> String {
        if run.status != "completed" { return "clock" }
        switch run.conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure": return "xmark.octagon.fill"
        default:        return "minus.circle"
        }
    }

    private func runColor(_ run: ActionRun) -> Color {
        if run.status != "completed" { return .blue }
        switch run.conclusion {
        case "success": return .green
        case "failure": return .red
        default:        return .secondary
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
    @Published var selectedPath: String? {
        didSet { if oldValue != selectedPath { status = nil; branches = []; runs = []; commitResults = nil; actionMessage = nil; loadStatus() } }
    }
    @Published var status: GitStatus?
    @Published var branches: [String] = []
    @Published var runs: [ActionRun] = []
    @Published var commitResults: [String]?   // nil = show recent commits; set = search results
    @Published var isLoading = false
    @Published var error: String?
    @Published var actionBusy = false
    @Published var actionMessage: String?

    private var host: Host?
    private var started = false
    private var statusToken = 0
    private var runsToken = 0

    func start(host: Host?) {
        guard !started else { return }
        started = true
        self.host = host
    }

    /// Re-point at a new host and reload — `start()` only runs once.
    func setHost(_ host: Host?) {
        guard host?.id != self.host?.id else { return }
        self.host = host
        loadStatus()
    }

    func refresh() { loadStatus() }

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
                loadRuns()
                loadBranches()
            } catch {
                guard token == statusToken else { return }
                status = nil
                self.error = error.localizedDescription
            }
            guard token == statusToken else { return }
            isLoading = false
        }
    }

    func loadRuns() {
        guard let host, let path = selectedPath else { runs = []; return }
        let slug = GitController.repoSlug(from: status?.remote)
        runsToken += 1
        let token = runsToken
        Task {
            let r = await GitController(host: host).actionRuns(path: path, slug: slug)
            guard token == runsToken, selectedPath == path else { return }   // superseded — drop
            runs = r
        }
    }

    func loadBranches() {
        guard let host, let path = selectedPath else { branches = []; return }
        Task {
            let b = (try? await GitController(host: host).branches(path: path)) ?? []
            guard selectedPath == path else { return }   // switched away — drop
            branches = b
        }
    }

    /// Check out a different branch on the hub (refreshes status, which the rest of
    /// the panel — and the browser preview — reads from).
    func checkout(_ branch: String) {
        guard branch != status?.branch else { return }
        run { _ = try await $0.checkout(path: $1, branch: branch); return "Switched to \(branch)." }
    }

    /// Search commit messages across history. Empty query restores recent commits.
    func searchCommits(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { commitResults = nil; return }
        guard let host, let path = selectedPath else { return }
        Task {
            let r = (try? await GitController(host: host).searchCommits(path: path, query: q)) ?? []
            guard selectedPath == path else { return }   // switched away — drop
            commitResults = r
        }
    }

    func commit(message: String) {
        run { _ = try await $0.commit(path: $1, message: message); return "Committed." }
    }

    func push() {
        run { controller, path in
            let out = try await controller.push(path: path)
            let upToDate = out.range(of: #"up.to.date"#, options: [.regularExpression, .caseInsensitive]) != nil
            return upToDate
                ? "Already up to date — nothing to push."
                : "Pushed — your deploy workflow runs next if configured."
        }
    }

    /// Runs a write action against the selected repo, then refreshes status + runs.
    /// The closure returns the message to show.
    private func run(_ work: @escaping (GitController, String) async throws -> String) {
        guard let host, let path = selectedPath, !actionBusy else { return }
        actionBusy = true
        actionMessage = nil
        Task {
            let result: String
            do { result = try await work(GitController(host: host), path) }
            catch { result = error.localizedDescription }
            actionBusy = false
            guard selectedPath == path else { return }   // switched away — don't surface on another project
            actionMessage = result
            loadStatus()
        }
    }
}
