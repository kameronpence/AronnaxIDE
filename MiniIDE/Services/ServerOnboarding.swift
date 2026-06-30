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

    // MARK: Flow
    @Published var current = 0
    @Published var bootstrapKey = ""   // pubkey to paste onto the box in step 1
    @Published var deployKey = ""      // vault deploy pubkey to add to GitHub in step 4
    @Published var finished = false

    @Published var steps: [Step] = [
        Step(id: 0, title: "Server details",                 role: .you),
        Step(id: 1, title: "Give the app a foothold",        role: .you),
        Step(id: 2, title: "Confirm the app can connect",    role: .app),
        Step(id: 3, title: "Generate the vault deploy key",  role: .app),
        Step(id: 4, title: "Add the deploy key to GitHub",   role: .you),
        Step(id: 5, title: "Clone the vault + memory rules", role: .app),
        Step(id: 6, title: "Check dev tools",                role: .app),
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
        """
        guard let r = try? await SSHManager.shared.runShell(setup, on: host), r.ok else {
            set(3, .failed, "Couldn't generate the deploy key on the box."); return
        }
        let key = r.stdout.split(separator: "\n").map(String.init).last { $0.hasPrefix("ssh-") } ?? ""
        guard !key.isEmpty else { set(3, .failed, "Made the key but couldn't read it back."); return }
        deployKey = key
        set(3, .done, "Deploy key ready.")
        current = 4
        set(4, .waitingOnYou, "Add the deploy key below to the ai-os-vault repo, with write access.")
    }

    // MARK: - Step 4 (you confirm): verify the deploy key reaches the vault
    func verifyDeployKey() async {
        set(4, .running, "Checking the deploy key…")
        let r = try? await SSHManager.shared.runShell(
            "git ls-remote \(vaultRepoSSH) >/dev/null 2>&1 && echo OK", on: host)
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
        if let h = try? await SSHManager.shared.runShell("echo $HOME", on: host), h.ok {
            let home = h.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !home.isEmpty { resolvedHome = home }
        }
        // Shell-quote the home-derived paths (a home dir could contain spaces).
        let vd = SSHManager.shellEscaped(vaultDir)
        let cd = SSHManager.shellEscaped(claudeDir)
        let cm = SSHManager.shellEscaped(globalClaudeMd)
        let prep = "set -e; [ -d \(vd)/.git ] || git clone -q \(vaultRepoSSH) \(vd); "
            + "mkdir -p \(cd); "
            + "grep -q 'Shared Memory — AI_OS Vault' \(cm) 2>/dev/null && echo ALREADY || echo NEEDWRITE"
        guard let r = try? await SSHManager.shared.runShell(prep, on: host), r.ok else {
            set(5, .failed, "Couldn't clone the vault onto the box."); return
        }
        if r.stdout.contains("NEEDWRITE") {
            // Append via stdin — avoids a fragile remote heredoc. Point the rules at the
            // resolved vault dir (matters when home isn't /root).
            let rules = Self.memoryRules.replacingOccurrences(of: "/root/AI_OS", with: vaultDir)
            let w = try? await SSHManager.shared.runShell(
                "cat >> \(cm)", input: "\n" + rules + "\n", on: host)
            guard w?.ok == true else { set(5, .failed, "Cloned, but couldn't write the memory rules."); return }
        }
        set(5, .done, "Vault cloned + memory rules in place.")
        await checkTools()
    }

    // MARK: - Step 6 (app): check dev tools (informational — missing ones don't fail setup)
    func checkTools() async {
        guard !Task.isCancelled else { return }
        current = 6
        set(6, .running, "Checking dev tools…")
        // zsh + tmux are what the app's own Terminal/Coding panes launch through
        // (`exec zsh -lc 'tmux …'`); claude/bd/cr/codex are the agent toolchain.
        guard let r = try? await SSHManager.shared.runShell(
                "bash -lc 'for t in zsh tmux claude bd cr codex; do command -v $t >/dev/null 2>&1 && echo $t:ok || echo $t:missing; done'",
                on: host),
              r.ok, !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // The check itself didn't run — don't assume everything's present.
            set(6, .failed, "Couldn't check the box's tools (connection issue?) — Retry.")
            return
        }
        let missing = r.stdout.split(separator: "\n")
            .filter { $0.hasSuffix(":missing") }
            .map { $0.replacingOccurrences(of: ":missing", with: "") }
        let missingTerminal = missing.filter { $0 == "zsh" || $0 == "tmux" }
        if !missingTerminal.isEmpty {
            // The app's Terminal/Coding panes can't run without these — don't finish or
            // add a host that won't actually work. Install them and Retry.
            set(6, .failed, "Install \(missingTerminal.joined(separator: " + ")) on the box "
                + "— the Terminal & Coding panes need them — then Retry.")
            return
        }
        let agentMissing = missing.filter { $0 != "zsh" && $0 != "tmux" }
        set(6, .done, agentMissing.isEmpty
            ? "zsh, tmux, claude, bd, cr, codex all present."
            : "Ready. Missing agent tools: \(agentMissing.joined(separator: ", ")) — install when you want them.")
        await finish()
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
        let verify = "cd \(SSHManager.shellEscaped(vaultDir)) || exit 1; "
            + "git pull --ff-only >/dev/null 2>&1 || exit 2; "
            + "git push --dry-run origin HEAD:refs/heads/onboard-write-check >/dev/null 2>&1"
        let r = try? await SSHManager.shared.runShell(verify, on: host)
        guard !Task.isCancelled else { return }
        if r?.ok == true {
            settings.addHost(host)            // now the app knows about it
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

    ## Session Commands
    ### /resume
    1. Detect project root (walk up from `pwd` for CLAUDE.md/.git)
    2. Read the project's DECISIONS.md + ROADMAP.md + the 3 most recent logs/ summaries
    3. `bd prime` then `bd ready` -> live ready/in-progress tasks
    4. Summarize current state + next tasks (from beads, not guessed)

    ### /save  (you-triggered — this IS permission to push)
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
}
