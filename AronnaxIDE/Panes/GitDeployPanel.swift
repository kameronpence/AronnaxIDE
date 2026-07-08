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
    ///
    /// This is a best-effort *secondary* check: it only fires when the account is nameable
    /// from the remote — a `github-<x>`/`github.com-<x>` SSH alias suffix, or HTTPS userinfo
    /// (see `GitController.identity`). Bare `github.com` and arbitrarily-named aliases (e.g.
    /// `Host gatsa`) return no identity and never warn — deliberately, since an alias name
    /// isn't reliably the owner's name and warning on it would cry wolf on correct pushes.
    /// The primary safeguard is the explicit account picker + the push-confirmation dialog,
    /// which name the exact account regardless of alias naming.
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
        // Only name the account for SSH remotes, where the host alias truly picks the key.
        // HTTPS remotes authenticate via gh/credentials, so the URL doesn't reveal the account.
        let ref = GitController.parseRemote(model.status?.remote)
        let account = (ref?.isSSH == true) ? " as \(accountLabel(ref!.host))" : ""
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("origin").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(maskedRemote(remote)).font(.callout.monospaced()).textSelection(.enabled)
                        accountPicker(s)
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

    /// Sentinel selection for an HTTPS origin: its account is ambient (gh/credentials), not
    /// an SSH alias. Picking a real alias converts the remote to SSH. Empty string can't
    /// collide with a host alias.
    private static let httpsAccount = ""

    /// The GitHub-account selector for this repo: a picker over the SSH accounts (host
    /// aliases) available on the host. Changing it rewrites `origin` to push as that account
    /// (converting HTTPS origins to SSH). Shown for any GitHub origin, SSH or HTTPS; a plain
    /// label when there's nothing to switch to. Hidden entirely for non-GitHub remotes.
    @ViewBuilder private func accountPicker(_ s: GitStatus) -> some View {
        if let ref = GitController.parseRemote(s.remote),
           GitController.isGitHubHost(ref.host, in: model.accounts) {
            // SSH → the current alias (guaranteed in `accounts`). HTTPS → the sentinel, plus
            // the sentinel prepended to the options so the Picker has a valid current tag.
            let current = ref.isSSH ? ref.host : Self.httpsAccount
            let usable = selectableAccounts(current: current, currentSlug: ref.slug)
            let options = ref.isSSH ? usable : [Self.httpsAccount] + usable
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key").font(.caption).foregroundStyle(.secondary)
                if options.count > 1 {
                    Picker("GitHub account", selection: Binding(
                        get: { current },
                        set: { alias in
                            guard alias != current, alias != Self.httpsAccount else { return }
                            requestWrite("Switch this repo's GitHub account to \(accountLabel(alias))?") {
                                model.setAccount(alias)
                            }
                        }
                    )) {
                        ForEach(options, id: \.self) { Text(accountLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(hubReadOnly || model.actionBusy)
                    Text("account").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("pushes as \(accountLabel(current))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The aliases worth offering as push accounts. Drops deploy-key aliases — those whose
    /// `ssh -T` identity is an `owner/repo` (contains `/`), not a user — but ONLY when they're
    /// for a *different* repo, since a deploy key can be write-enabled for its own repo and is
    /// then a valid credential. Unresolved aliases are kept (we can't tell yet), and the
    /// current selection is always kept so the Picker has a valid tag.
    private func selectableAccounts(current: String, currentSlug: String?) -> [String] {
        model.accounts.filter { alias in
            if alias == current { return true }
            guard let name = model.accountNames[alias] else { return true }
            guard name.contains("/") else { return true }   // real user account
            // Deploy key: keep only if it belongs to this repo.
            return currentSlug.map { name.caseInsensitiveCompare($0) == .orderedSame } ?? false
        }
    }

    /// Label for a GitHub account: the real account it authenticates as when resolved
    /// (`github.com` → "kameronpence", `github-gatsa` → "GATSA"), else the raw alias until
    /// `ssh -T` resolves it. The HTTPS sentinel → "HTTPS (via gh)". Display only.
    private func accountLabel(_ alias: String) -> String {
        if alias == Self.httpsAccount { return "HTTPS (via gh)" }
        guard let name = model.accountNames[alias], !name.isEmpty else { return alias }
        // If two aliases authenticate as the same user, the name alone is ambiguous about
        // which alias gets written to origin — append the alias to disambiguate.
        let collides = model.accountNames.values.filter { $0 == name }.count > 1
        return collides ? "\(name) (\(alias))" : name
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
        didSet { if oldValue != selectedPath { status = nil; branches = []; accounts = []; runs = []; commitResults = nil; actionMessage = nil; loadStatus() } }
    }
    @Published var status: GitStatus?
    @Published var branches: [String] = []
    @Published var accounts: [String] = []    // github ssh host aliases available on the host
    @Published var accountNames: [String: String] = [:]   // alias -> real account (ssh -T "Hi <x>!")
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
    private var resolvedAccountsHostID: String?   // host whose account names are already resolved

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
                let controller = GitController(host: host)
                let s = try await controller.status(path: path)
                guard token == statusToken else { return }
                status = s
                // Resolve the GitHub accounts before runs, so the Actions slug gate and the
                // account picker both see the enumerated alias set for this repo/host.
                let accts = await controller.githubAccounts()
                guard token == statusToken else { return }
                accounts = accts
                resolveAccountNames(host: host, aliases: accts)
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
        let slug = GitController.repoSlug(from: status?.remote, accounts: accounts)
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

    /// Repoint origin at a different GitHub account (ssh host alias) for this project.
    func setAccount(_ alias: String) {
        // No-op only when the origin is ALREADY an SSH remote on this exact alias. An HTTPS
        // origin shares the host name `github.com` with the SSH alias but isn't using it, so
        // it must still convert — comparing host alone wrongly blocked switching HTTPS repos.
        let ref = GitController.parseRemote(status?.remote)
        if let ref, ref.isSSH, ref.host == alias { return }
        let remote = status?.remote
        run { try await $0.setAccount(path: $1, remote: remote, alias: alias) }
    }

    /// Resolve each alias to the real GitHub account it authenticates as (`ssh -T` → "Hi <x>!"),
    /// so the picker shows `kameronpence`/`GATSA` instead of the alias. Cached per host — the
    /// mapping is host-wide, so it survives project switches and only re-runs on a host change.
    func resolveAccountNames(host: Host, aliases: [String]) {
        guard resolvedAccountsHostID != host.id else { return }
        resolvedAccountsHostID = host.id
        accountNames = [:]
        Task {
            var names: [String: String] = [:]
            for a in aliases {
                if let n = await GitController(host: host).githubIdentity(alias: a) { names[a] = n }
            }
            guard self.host?.id == host.id else { return }   // host changed mid-resolve — drop
            accountNames = names
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
