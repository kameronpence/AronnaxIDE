import Foundation
import Combine

/// Drives the "Add Server" wizard: the app does every step it can over SSH and
/// pauses with instructions at the steps only Kameron can do (paste a key onto a
/// fresh box, add a deploy key to GitHub). Mirrors the manual staging/pbisario setup.
@MainActor
final class ServerOnboarding: ObservableObject {

    /// Who performs a step.
    enum Role { case app, you }

    /// Where a step is in its lifecycle.
    enum Phase: Equatable { case idle, running, waitingOnYou, done, failed }

    struct Step: Identifiable {
        let id: Int
        let title: String
        let role: Role
        var phase: Phase = .idle
        var detail: String = ""
    }

    // MARK: Form (step 0)
    @Published var name = ""
    @Published var address = ""        // IP or hostname the app/kepler will ssh to
    @Published var user = "root"
    @Published var viaHub = false      // reached via kepler (ProxyJump) vs. directly
    @Published var projectDir = ""     // the project's repo dir on the box (e.g. /var/www/html/gatsa_rewrite)

    // MARK: Flow
    @Published var current = 0
    @Published var bootstrapKey = ""   // pubkey to paste onto the box in step 1
    @Published var deployKey = ""      // vault deploy pubkey to add to GitHub in step 4
    @Published var deployKeyFingerprint = ""  // SHA256 fp — to match against GitHub's deploy-key list
    @Published var finished = false

    @Published var steps: [Step] = [
        Step(id: 0, title: "Server details",                 role: .you),
        Step(id: 1, title: "Give the app a foothold",        role: .you),
        Step(id: 2, title: "Confirm the app can connect",    role: .app),
        Step(id: 3, title: "Generate the vault deploy key",  role: .app),
        Step(id: 4, title: "Add the deploy key to GitHub",   role: .you),
        Step(id: 5, title: "Clone the vault + memory rules", role: .app),
        Step(id: 6, title: "Install dev tools",              role: .app),
        Step(id: 7, title: "Verify + finish",                role: .app),
    ]

    private let settings: AppSettings
    init(settings: AppSettings) { self.settings = settings }

    /// The host the wizard targets, built from the form (not yet in settings.hosts).
    var host: Host {
        let addr = address.trimmingCharacters(in: .whitespaces)
        return Host(
            id: addr,
            displayName: name.trimmingCharacters(in: .whitespaces).isEmpty ? addr : name,
            sshAlias: addr,
            user: user.trimmingCharacters(in: .whitespaces).isEmpty ? nil : user,
            reach: viaHub ? .proxyJump(via: AppSettings.hubAlias) : .direct,
            isHub: false
        )
    }

    var formValid: Bool {
        !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func set(_ id: Int, _ phase: Phase, _ detail: String = "") {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].phase = phase
        if !detail.isEmpty { steps[i].detail = detail }
    }

    // MARK: - Task lifecycle
    // Provisioning runs in a tracked Task so closing the wizard cancels it — otherwise
    // remote work (and addHost) could keep running after dismissal.
    private var work: Task<Void, Never>?
    func startConnect() { work = Task { await testConnection() } }
    func startVerify()  { work = Task { await verifyDeployKey() } }
    func startRetry()   { work = Task { await retryCurrent() } }
    func cancel() { work?.cancel(); work = nil }

    /// Non-interactive git for every remote git call: never prompt (so a missing key or
    /// unknown host fails fast instead of blocking on a prompt no TTY can answer), and give
    /// the git→GitHub SSH connection a connect timeout + keepalives so a *stalled* transfer
    /// aborts in ~30s rather than spinning forever — the root of the "clone hangs" bug (the
    /// handshake/ls-remote succeeds, then the bulk transfer stalls with nothing to time it out).
    private static let gitEnv =
        "GIT_TERMINAL_PROMPT=0 "
        + #"GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3' "#

    /// Runs a remote command but never lets a step hang the wizard forever: if it doesn't
    /// finish within `seconds`, the ssh process is cancelled (SSHManager terminates it) and
    /// this returns nil, so the caller surfaces a failure + Retry instead of an endless spinner.
    private func runStep(_ command: String, input: String? = nil, seconds: UInt64 = 120) async -> CommandResult? {
        await withTaskGroup(of: CommandResult?.self) { group in
            group.addTask { try? await SSHManager.shared.runShell(command, input: input, on: self.host) }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil   // timeout sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()   // cancel the loser — if the timeout won, this terminates the ssh
            return first
        }
    }

    // MARK: - Step 1: foothold key to paste onto the box
    /// Loads the public key Kameron must add to the fresh box's authorized_keys.
    /// This is always THIS Mac's key: the app connects from here, and even when the
    /// box is reached `-J kepler`, OpenSSH authenticates the final hop (the box) with
    /// the local client's key — kepler only forwards the TCP. So the box needs this
    /// Mac's key whether the path is direct or via the hub.
    func prepareFoothold() async {
        set(1, .running, "Reading this Mac's public key…")
        let sshDir = ("~/.ssh" as NSString).expandingTildeInPath as NSString
        bootstrapKey = ""
        // Prefer ed25519, then the other common key types — don't assume one exact file.
        for name in ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"] {
            let path = sshDir.appendingPathComponent(name)
            if let k = try? String(contentsOfFile: path, encoding: .utf8),
               !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bootstrapKey = k.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        if bootstrapKey.isEmpty {
            set(1, .failed, "No SSH public key in ~/.ssh (id_ed25519 / id_ecdsa / id_rsa) — run `ssh-keygen` first.")
        } else {
            set(1, .waitingOnYou, "Add this Mac's key below to the box (via AWS's initial access).")
        }
    }

    // MARK: - Step 2: confirm the app can reach the box
    func testConnection() async {
        current = 2
        set(2, .running, "Trying to connect…")
        let reachable = await SSHManager.shared.isReachable(host)
        if reachable {
            set(2, .done, "Connected to \(host.displayName).")
            await generateDeployKey()          // hand off to the app-driven steps
        } else {
            set(2, .failed, viaHub
                ? "Still can't reach it through kepler — confirm the key is in the box's authorized_keys."
                : "Still can't reach it — confirm the key is in the box's authorized_keys.")
        }
    }

    // The shared memory vault (private, personal account) + where it lands on a box.
    // Servers log in as root, so paths are under /root (see [fleet-and-projects]).
    private let vaultRepoSSH = "git@github-vault:kameronpence/ai-os-vault.git"
    private var resolvedHome = "/root"   // resolved from the box at provision time (handles non-root users)
    private var vaultDir: String { "\(resolvedHome)/AI_OS" }
    private var claudeDir: String { "\(resolvedHome)/.claude" }
    private var globalClaudeMd: String { "\(claudeDir)/CLAUDE.md" }

    // MARK: - Step 3 (app): generate the vault deploy key + ssh alias on the box
    func generateDeployKey() async {
        guard !Task.isCancelled else { return }
        current = 3
        set(3, .running, "Generating the vault deploy key on the box…")
        let setup = """
        [ -f ~/.ssh/id_vault ] || ssh-keygen -t ed25519 -f ~/.ssh/id_vault -C \(SSHManager.shellEscaped(host.id + "-vault")) -N "" -q
        grep -q github-vault ~/.ssh/config 2>/dev/null || printf '\\nHost github-vault\\n    HostName github.com\\n    User git\\n    IdentityFile ~/.ssh/id_vault\\n    IdentitiesOnly yes\\n    StrictHostKeyChecking accept-new\\n' >> ~/.ssh/config
        cat ~/.ssh/id_vault.pub
        ssh-keygen -lf ~/.ssh/id_vault.pub 2>/dev/null | awk '{print "FP:" $2}'
        """
        guard let r = try? await SSHManager.shared.runShell(setup, on: host), r.ok else {
            set(3, .failed, "Couldn't generate the deploy key on the box."); return
        }
        let lines = r.stdout.split(separator: "\n").map(String.init)
        let key = lines.last { $0.hasPrefix("ssh-") } ?? ""
        guard !key.isEmpty else { set(3, .failed, "Made the key but couldn't read it back."); return }
        deployKey = key
        deployKeyFingerprint = lines.last { $0.hasPrefix("FP:") }?.replacingOccurrences(of: "FP:", with: "") ?? ""
        set(3, .done, "Deploy key ready.")
        current = 4
        set(4, .waitingOnYou, "Add the deploy key below to the ai-os-vault repo, with write access.")
    }

    // MARK: - Step 4 (you confirm): verify the deploy key reaches the vault
    func verifyDeployKey() async {
        set(4, .running, "Checking the deploy key…")
        let r = await runStep(
            "\(Self.gitEnv)git ls-remote \(vaultRepoSSH) >/dev/null 2>&1 && echo OK", seconds: 40)
        if r?.stdout.contains("OK") == true {
            set(4, .done, "Deploy key works.")
            await cloneVault()
        } else {
            set(4, .failed, "Can't reach the vault yet — confirm the deploy key is added with write access.")
        }
    }

    // MARK: - Step 5 (app): clone the vault + append the memory rules to the global CLAUDE.md
    func cloneVault() async {
        guard !Task.isCancelled else { return }
        current = 5
        set(5, .running, "Cloning the vault + writing memory rules…")
        // Resolve the box user's home so the paths work for non-root users too.
        if let h = await runStep("echo $HOME", seconds: 30), h.ok {
            let home = h.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !home.isEmpty { resolvedHome = home }
        }
        // Shell-quote the home-derived paths (a home dir could contain spaces).
        let vd = SSHManager.shellEscaped(vaultDir)
        let cd = SSHManager.shellEscaped(claudeDir)
        let cm = SSHManager.shellEscaped(globalClaudeMd)
        // `gitEnv` makes the clone non-interactive + keepalive-bounded so it fails fast
        // instead of hanging; `runStep` is a hard client-side backstop against a stall.
        let prep = "set -e; export \(Self.gitEnv); [ -d \(vd)/.git ] || git clone -q \(vaultRepoSSH) \(vd); "
            + "mkdir -p \(cd); "
            + "grep -q 'Shared Memory — AI_OS Vault' \(cm) 2>/dev/null && echo ALREADY || echo NEEDWRITE"
        guard let r = await runStep(prep, seconds: 120), r.ok else {
            set(5, .failed, "Couldn't clone the vault onto the box — it timed out or the box "
                + "can't reach github.com (a stalled transfer). Confirm the box has outbound "
                + "access to github.com, then Retry."); return
        }
        if r.stdout.contains("NEEDWRITE") {
            // Append via stdin — avoids a fragile remote heredoc. Point the rules at the
            // resolved vault dir (matters when home isn't /root).
            let rules = Self.memoryRules.replacingOccurrences(of: "/root/AI_OS", with: vaultDir)
            let w = await runStep("cat >> \(cm)", input: "\n" + rules + "\n", seconds: 30)
            guard w?.ok == true else { set(5, .failed, "Cloned, but couldn't write the memory rules."); return }
        }
        // Install the real slash commands / skills so /resumeproject + /save actually
        // exist on the box (the memory rules only *describe* them; /resume is a built-in).
        guard await installAgentCommands() else {
            set(5, .failed, "Cloned, but couldn't install the /resumeproject + /saveproject commands."); return
        }
        await setClaudeRetention()   // stop Claude's 30-day auto-prune of /resume history
        set(5, .done, "Vault cloned + memory rules + slash commands in place.")
        await checkTools()
    }

    // MARK: - Step 6 (app): check dev tools — and install whatever's missing.
    // zsh + tmux are what the app's Terminal/Coding panes launch through
    // (`exec zsh -lc 'tmux …'`); claude/bd/cr/codex are the agent toolchain.
    func checkTools() async {
        guard !Task.isCancelled else { return }
        current = 6
        set(6, .running, "Checking dev tools…")
        guard let missing = await toolStatus() else {
            set(6, .failed, "Couldn't check the box's tools (connection issue?) — Retry.")
            return
        }
        if missing.isEmpty {
            set(6, .done, "zsh, tmux, claude, bd, cr, codex all present.")
            await finish()
        } else {
            await installTools(missing)   // install, then re-check
        }
    }

    /// The tools missing on the box, or nil if the check itself couldn't run.
    private func toolStatus() async -> [String]? {
        guard let r = await runStep(
                "bash -lc 'for t in zsh tmux claude bd cr codex; do command -v $t >/dev/null 2>&1 && echo $t:ok || echo $t:missing; done'",
                seconds: 30),
              r.ok, !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return r.stdout.split(separator: "\n")
            .filter { $0.hasSuffix(":missing") }
            .map { $0.replacingOccurrences(of: ":missing", with: "") }
    }

    /// Each agent CLI's official installer, run on the box.
    private static let cliInstaller: [String: String] = [
        "claude": "curl -fsSL https://claude.ai/install.sh | bash",
        "codex":  "curl -fsSL https://chatgpt.com/codex/install.sh | sh",
        "bd":     "curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash",
        "cr":     "curl -fsSL https://cli.coderabbit.ai/install.sh | sh",
    ]

    /// Install the missing tools on the box — system tools (zsh/tmux) via its package
    /// manager, agent CLIs via their official installers — then re-check.
    private func installTools(_ missing: [String]) async {
        guard !Task.isCancelled else { return }
        let sys = missing.filter { $0 == "zsh" || $0 == "tmux" }
        if !sys.isEmpty {
            set(6, .running, "Installing \(sys.joined(separator: " + "))…")
            let pkgs = sys.joined(separator: " ")
            let sysInstall = await runStep("""
            SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo "
            if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive ${SUDO}apt-get -o Dpkg::Use-Pty=0 update -qq --allow-releaseinfo-change && DEBIAN_FRONTEND=noninteractive ${SUDO}apt-get -o Dpkg::Use-Pty=0 install -y \(pkgs)
            elif command -v dnf >/dev/null 2>&1; then ${SUDO}dnf install -y \(pkgs)
            elif command -v yum >/dev/null 2>&1; then ${SUDO}yum install -y \(pkgs)
            elif command -v apk >/dev/null 2>&1; then ${SUDO}apk add \(pkgs)
            else echo NO_PKG_MGR; exit 1; fi
            """, seconds: 240)
            guard sysInstall?.ok == true else {
                set(6, .failed, "Couldn't install \(sys.joined(separator: " + ")) — the package manager timed out or failed. Install it manually, then Retry.")
                return
            }
        }
        for tool in missing {
            guard !Task.isCancelled else { return }
            guard let installer = Self.cliInstaller[tool] else { continue }
            set(6, .running, "Installing \(tool)…")
            guard let install = await runStep(installer, seconds: 180), install.ok else {
                set(6, .failed, "Couldn't install \(tool) — the installer timed out or failed. Install it manually, then Retry.")
                return
            }
        }
        guard !Task.isCancelled else { return }
        set(6, .running, "Verifying the installs…")
        let nowMissing = await toolStatus() ?? missing
        let sysStill = nowMissing.filter { $0 == "zsh" || $0 == "tmux" }
        if !sysStill.isEmpty {
            set(6, .failed, "Couldn't install \(sysStill.joined(separator: " + ")) — the box's "
                + "package manager may need different access. Install it manually, then Retry.")
            return
        }
        let installed = missing.filter { !nowMissing.contains($0) }
        let stillMissing = nowMissing.filter { $0 != "zsh" && $0 != "tmux" }
        let needAuth = installed.filter { ["claude", "codex", "cr"].contains($0) }
        var detail = "zsh + tmux ready."
        if !installed.isEmpty { detail += " Installed: \(installed.joined(separator: ", "))." }
        if !stillMissing.isEmpty { detail += " Couldn't auto-install: \(stillMissing.joined(separator: ", "))." }
        if !needAuth.isEmpty {
            detail += " Sign in on the box: " + needAuth.map { authHint($0) }.joined(separator: ", ") + "."
        }
        set(6, .done, detail)
        await finish()
    }

    private func authHint(_ tool: String) -> String {
        switch tool {
        case "claude": return "run `claude` then `/login`"
        case "codex":  return "`codex login`"
        case "cr":     return "`cr auth login`"
        default:       return tool
        }
    }

    // MARK: - Step 7 (app): verify the round-trip + commit the host to the app
    func finish() async {
        guard !Task.isCancelled else { return }
        current = 7
        set(7, .running, "Verifying read + write access…")
        // Read check (pull), then a non-destructive WRITE check: push --dry-run of the
        // current HEAD to a throwaway ref exercises receive-pack (which a read-only
        // deploy key can't) without creating a commit, touching the working tree, or
        // modifying the remote — so an existing vault with local work is never disturbed.
        let verify = "export \(Self.gitEnv); cd \(SSHManager.shellEscaped(vaultDir)) || exit 1; "
            + "git pull --ff-only >/dev/null 2>&1 || exit 2; "
            + "git push --dry-run origin HEAD:refs/heads/onboard-write-check >/dev/null 2>&1"
        let r = await runStep(verify, seconds: 60)
        guard !Task.isCancelled else { return }
        if r?.ok == true {
            settings.addHost(host)            // now the app knows about it
            // Wire up the panes for this server so the user never sets paths by hand:
            // its vault clone (the app made it) + its one project dir.
            settings.hostVaultPaths[host.id] = vaultDir
            let proj = projectDir.trimmingCharacters(in: .whitespaces)
            if !proj.isEmpty { settings.hostProjectPaths[host.id] = proj }
            set(7, .done, "\(host.displayName) is set up and added to the app.")
            finished = true
        } else {
            set(7, .failed, "Verify failed — the deploy key likely needs WRITE access "
                + "(re-add it with “Allow write access”), then Retry.")
        }
    }

    /// Re-run whichever step failed.
    func retryCurrent() async {
        switch current {
        case 2: await testConnection()
        case 3: await generateDeployKey()
        case 4: await verifyDeployKey()
        case 5: await cloneVault()
        case 6: await checkTools()
        case 7: await finish()
        default: break
        }
    }

    /// The memory-system block appended to a server's global CLAUDE.md — same rules as
    /// the mini, adapted for a box with no Obsidian (plain file reads).
    static let memoryRules = """
    # Shared Memory — AI_OS Vault

    Your long-term memory is the AI_OS vault at /root/AI_OS — a git repo synced through
    GitHub, shared with the agents on the mini and the other servers.

    ## This box is a server (no Obsidian)
    Read CTX files and notes as plain files (cat / grep / rg). The vault's search/read/reindex
    tools are Obsidian-only and not available here.

    ## Session start
    1. git -C /root/AI_OS pull --rebase --autostash 2>/dev/null || true
    2. Read orientation in order: /root/AI_OS/CTX-aboutme.md -> CTX-work.md ->
       CTX-project-index.md -> CTX-systems.md -> CTX-now.md.
    3. Pull deeper context from /root/AI_OS/permanent/ by grepping/reading what's relevant.

    ## Session Commands (installed slash commands, in ~/.claude/commands/)
    Use `/resumeproject` to load project state and `/saveproject` to wrap up — both are installed
    command files here. (`/resume` is Claude's built-in session picker — leave it for that.)

    ### /resumeproject
    1. Detect project root (walk up from `pwd` for CLAUDE.md/.git)
    2. Read the project's DECISIONS.md + ROADMAP.md + the 3 most recent logs/ summaries
    3. `bd prime` then `bd ready` -> live ready/in-progress tasks
    4. Summarize current state + next tasks (from beads, not guessed)

    ### /saveproject  (you-triggered — this IS permission to push)
    1. Update beads: `bd close` finished, `bd update` progress, `bd create` new pending items
    2. Write a session log at <project>/logs/YYYY-MM-DD-description.md (frontmatter, type: session)
    3. Record what was done + decisions; link bead IDs; update DECISIONS.md/ROADMAP.md if changed
    4. Write durable knowledge to /root/AI_OS/permanent/ (kebab-case, frontmatter, [[wikilinks]])
    5. Run CodeRabbit (`cr`) on the changes — address findings; never commit unreviewed code
    6. git add + commit + push on the current feature branch
    7. Sync the vault: git -C /root/AI_OS add -A && git -C /root/AI_OS commit -m "<what>" && git -C /root/AI_OS push

    ## Rules (how to work)
    - Call him Kam every reply.
    - ADHD: one thing at a time, short replies, never make him repeat himself, don't talk down.
      If he's cursing in frustration, stop and do a breathing exercise — see CTX-aboutme.
    - Never push to git on your own. ONLY triggers: Kameron runs /save, or says "push."
      Mid-work commits / "looks done" / finishing a feature are NOT permission.
    - Every new task = its own branch. Commit locally as you go; push only per the rule above.
    - Run CodeRabbit (`cr`) on every commit. Shared bd beads per project.
    - Never undo an approved fix — ask first. Fix it right the first time. Root cause, not symptoms.
    - Only change what was explicitly asked — no surprise refactors/features.
    - Database safety: never migrate:fresh / migrate:reset; migrate only. Ask before destructive DB commands.
    - Secrets stay in gitignored .env — never commit them.
    """

    // MARK: - Agent slash commands / skills installed on every server
    // /resume is Claude's BUILT-IN session picker and can't be overridden by CLAUDE.md,
    // so the real protocol must be an installed command file. These are the canonical
    // copies (mirror the mini); installAgentCommands writes them onto the box.

    static let claudeResumeProject = """
    ---
    description: Load project state — decisions, roadmap, recent logs, and ready beads
    allowed-tools: Read, Glob, Bash
    ---

    # /resumeproject — Load project state

    Get up to speed on the current project without bulk-loading it.

    ## Steps
    1. **Detect project root.** Walk up from `pwd` for a `CLAUDE.md` or `.git`. That dir = project
       root. If none found, you're at the vault root (`/root/AI_OS`).
    2. **Read living state** (summaries only, to save tokens):
       - `DECISIONS.md` — key decisions + why
       - `ROADMAP.md` — current plan / what's next
       - The 3 most recent files in `logs/` — stop at `## Raw Session Log`
    3. **Load tasks from beads:** run `bd prime` to orient, then `bd ready` for ready/in-progress items.
    4. **Summarize:** current state, recent decisions, and next tasks — pulled from **beads**, not guessed.

    Arguments: `/resumeproject 10` = read 10 logs instead of 3. Don't load the whole project.
    """

    static let claudeSave = """
    ---
    description: Save the session — update beads, write a log note, CodeRabbit review, commit, push + auto-merge the PR
    allowed-tools: Read, Write, Edit, Bash, AskUserQuestion
    ---

    # /saveproject — Save the session

    You-triggered save. **Running this IS Kameron's permission to push and merge** — never push or merge otherwise.

    ## Steps
    1. **Detect project root** (walk up from `pwd` for `CLAUDE.md`/`.git`).
    2. **Update beads:** `bd close` finished, `bd update` progress, `bd create` for new pending items.
       Beads is the task ledger — pending work lives here, not in prose.
    3. **Write the session log** at `<project>/logs/YYYY-MM-DD-description.md` with frontmatter
       (title, tags, created, updated, status: complete, type: session). Record what was done +
       decisions. For pending items, **link the bead IDs** — don't restate them.
    4. **Update `DECISIONS.md` / `ROADMAP.md`** if decisions or the plan changed. Add `[[wikilinks]]`.
    5. **CodeRabbit review:** run `cr` on the changes. Address findings. **Never commit unreviewed code.**
    6. **Commit + push** on the current feature branch (authorized only because Kameron ran `/saveproject`).
    7. **Open + auto-merge the PR:** create one if none exists (`gh pr create --fill`), then
       `gh pr merge --squash --delete-branch`. Only skip if not cleanly mergeable — then leave it
       open and report why.
    8. **Sync the vault:** `git -C /root/AI_OS add -A && git -C /root/AI_OS commit -m "<what>" && git -C /root/AI_OS push`
    """

    static let codexResumeProject = """
    ---
    name: resumeproject
    description: Load current project state at session start — decisions, roadmap, recent log summaries, and ready beads. Invoke explicitly when resuming work on a project; do not trigger automatically.
    auto_trigger: false
    ---

    # resumeproject — Load project state

    Get up to speed on the current project without bulk-loading it. Do these steps, then summarize and stop:

    1. Detect the project root: walk up from the current directory for a `CLAUDE.md` or `.git`. That
       directory is the project root. If none is found, you are at the vault root (`/root/AI_OS`).
    2. Read the living state (summaries only, to save tokens):
       - `DECISIONS.md` — key decisions and why
       - `ROADMAP.md` — current plan / what's next
       - The 3 most recent files in `logs/` — read only the summary, stop at `## Raw Session Log`
    3. Load tasks from beads: run `bd prime` to orient, then `bd ready` for ready/in-progress items.
    4. Summarize the current state, recent decisions, and next tasks — pulled from beads, not guessed.

    Remember your role on this project: you are the reviewer. After resuming, wait for Claude's changes
    to review — do not start editing.
    """

    static let codexSave = """
    ---
    name: saveproject
    description: Save the session — update beads, write a session log, update DECISIONS/ROADMAP, CodeRabbit review, then commit + push. Does NOT open or merge a pull request (that is Claude's job). Invoke explicitly to wrap up a session.
    auto_trigger: false
    ---

    # saveproject — Save the session (no PR)

    Wrap up the current session. Running this is your permission to commit + push — never push otherwise.

    ## Steps
    1. Detect the project root (walk up from the current directory for `CLAUDE.md`/`.git`).
    2. Update beads: `bd close` finished, `bd update` progress, `bd create` for new pending items.
       Beads is the task ledger — pending work lives there, not in prose.
    3. Write the session log at `<project>/logs/YYYY-MM-DD-description.md` with frontmatter
       (title, tags, created, updated, status: complete, type: session). Link bead IDs for pending items.
    4. Update `DECISIONS.md` / `ROADMAP.md` if decisions or the plan changed. Add `[[wikilinks]]`.
    5. CodeRabbit review: run `cr` on the changes; address findings. Never commit unreviewed code.
    6. Commit + push on the current feature branch.

    Do NOT open or merge a pull request — leave that to Claude's /saveproject. Stop after pushing.
    """

    /// Raise Claude's transcript retention to a year on the box, so /resume history isn't
    /// lost (Claude's default `cleanupPeriodDays` silently deletes sessions older than
    /// 30 days). Merges the key into settings.json, preserving any others.
    /// Best-effort: the script is piped to python3 over stdin so there's no shell quoting.
    private func setClaudeRetention() async {
        let py = """
        import json, os
        p = os.path.expanduser('~/.claude/settings.json')
        d = {}
        if os.path.isfile(p):
            try:
                d = json.load(open(p))
            except Exception:
                d = {}
        d['cleanupPeriodDays'] = 365
        os.makedirs(os.path.dirname(p), exist_ok=True)
        json.dump(d, open(p, 'w'), indent=2)
        """
        _ = try? await SSHManager.shared.runShell("python3", input: py, on: host)
    }

    /// Installs the Claude commands + Codex skills on the box so /resumeproject and
    /// /saveproject (and their Codex $-skill equivalents) actually exist. Overwrites — these files are
    /// canonical and versioned with the app; vault-root paths point at this box's clone.
    private func installAgentCommands() async -> Bool {
        let skills = "\(resolvedHome)/.agents/skills"
        let mk = "mkdir -p \(SSHManager.shellEscaped(claudeDir + "/commands")) "
            + "\(SSHManager.shellEscaped(skills + "/resumeproject")) "
            + "\(SSHManager.shellEscaped(skills + "/saveproject"))"
        guard let m = try? await SSHManager.shared.runShell(mk, on: host), m.ok else { return false }
        let files: [(String, String)] = [
            ("\(claudeDir)/commands/resumeproject.md", Self.claudeResumeProject),
            ("\(claudeDir)/commands/saveproject.md",   Self.claudeSave),
            ("\(skills)/resumeproject/SKILL.md",       Self.codexResumeProject),
            ("\(skills)/saveproject/SKILL.md",         Self.codexSave),
        ]
        for (path, content) in files {
            let body = content.replacingOccurrences(of: "/root/AI_OS", with: vaultDir)
            let w = try? await SSHManager.shared.runShell(
                "cat > \(SSHManager.shellEscaped(path))", input: body, on: host)
            guard w?.ok == true else { return false }
        }
        return true
    }
}
