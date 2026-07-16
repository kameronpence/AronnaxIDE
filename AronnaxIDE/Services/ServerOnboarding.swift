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
        Step(id: 7, title: "Set up Obsidian second memory",  role: .app),
        Step(id: 8, title: "Verify + finish",                role: .app),
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

    func reset() {
        cancel()
        name = ""
        address = ""
        user = "root"
        viaHub = false
        projectDir = ""
        current = 0
        bootstrapKey = ""
        deployKey = ""
        deployKeyFingerprint = ""
        finished = false
        resolvedHome = "/root"
        for i in steps.indices {
            steps[i].phase = .idle
            steps[i].detail = ""
        }
    }

    /// Non-interactive git for every remote git call: never prompt (so a missing key or
    /// unknown host fails fast instead of blocking on a prompt no TTY can answer), and give
    /// the git→GitHub SSH connection a connect timeout + keepalives so a *stalled* transfer
    /// aborts in ~30s rather than spinning forever — the root of the "clone hangs" bug (the
    /// handshake/ls-remote succeeds, then the bulk transfer stalls with nothing to time it out).
    private static let gitEnv =
        "GIT_TERMINAL_PROMPT=0 "
        + #"GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3' "#

    /// Runs a remote command but never lets a step hang the wizard forever: SSHManager
    /// kills the ssh process if it exceeds `seconds`, then returns a non-ok result so the
    /// caller surfaces a failure + Retry instead of an endless spinner.
    private func runStep(_ command: String, input: String? = nil, seconds: UInt64 = 120) async -> CommandResult? {
        try? await SSHManager.shared.runShell(
            command,
            input: input,
            on: host,
            timeoutSeconds: TimeInterval(seconds)
        )
    }

    // MARK: - Step 0 → 1: leave the details form
    /// The details form has no async work of its own, so nothing else marks it done —
    /// mark step 0 complete (so its rail row turns green) before starting the foothold.
    func startFoothold() async {
        set(0, .done)
        current = 1
        await prepareFoothold()
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
            set(1, .done)                      // foothold key is confirmed working now
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
        // Clone if absent, otherwise BRING THE EXISTING CLONE UP TO DATE. An already-
        // onboarded box has a vault clone that predates the commands/ tree, so without an
        // update it would fail the install-links.sh probe forever and Retry would replay
        // the same stale state. Onboarding-only behaviour is what froze every box at its
        // onboarding build in the first place — this step has to be a re-sync path too.
        //
        // `git pull --ff-only` alone is NOT sufficient, and assuming it was is how this
        // whole class of bug happens: it fast-forwards whatever branch is checked out, so
        // a box parked on a feature branch would pass and then execute THAT branch's
        // install-links.sh — recreating the exact drift this is meant to prevent. It also
        // won't reject a clone sitting ahead of origin. So check explicitly, and let each
        // failure name itself: on main, clean, and not ahead of origin/main.
        let prep = "set -e; export \(Self.gitEnv); "
            + "if [ -d \(vd)/.git ]; then "
            +   "B=$(git -C \(vd) rev-parse --abbrev-ref HEAD 2>/dev/null); "
            +   "[ \"$B\" = main ] || { echo \"VAULT_OFF_MAIN=$B\"; exit 3; }; "
            +   "[ -z \"$(git -C \(vd) status --porcelain)\" ] || { echo VAULT_DIRTY; exit 4; }; "
            +   "git -C \(vd) fetch -q origin main; "
            +   "git -C \(vd) merge-base --is-ancestor HEAD origin/main || { echo VAULT_AHEAD; exit 5; }; "
            +   "git -C \(vd) merge --ff-only -q origin/main; "
            + "else git clone -q \(vaultRepoSSH) \(vd); fi; "
            + "mkdir -p \(cd); "
            + "git -C \(vd) rev-parse --short HEAD 2>/dev/null | sed 's/^/VAULT_HEAD=/'; "
            + "grep -q 'Shared Memory — AI_OS Vault' \(cm) 2>/dev/null && echo ALREADY || echo NEEDWRITE"
        let prepResult = await runStep(prep, seconds: 120)
        guard let r = prepResult, r.ok else {
            // Say which one it was. "Retry" on a vault that will never fast-forward is the
            // kind of dead end that hides a real problem for weeks.
            let out = (prepResult?.stdout ?? "") + (prepResult?.stderr ?? "")
            let why: String
            if let line = out.split(separator: "\n").first(where: { $0.contains("VAULT_OFF_MAIN=") }) {
                let branch = line.replacingOccurrences(of: "VAULT_OFF_MAIN=", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                why = "The vault at \(vaultDir) is on '\(branch)', not main. Nothing was pulled — "
                    + "a vault on a feature branch is exactly how this drifts. "
                    + "Fix on the box: git -C \(vaultDir) checkout main"
            } else if out.contains("VAULT_DIRTY") {
                why = "The vault at \(vaultDir) has uncommitted changes. Not pulling and not guessing — "
                    + "resolve them on the box, then Retry."
            } else if out.contains("VAULT_AHEAD") {
                why = "The vault at \(vaultDir) has local commits that aren't on origin/main. "
                    + "Not overwriting them — resolve on the box (git -C \(vaultDir) log origin/main..HEAD), then Retry."
            } else {
                why = "Couldn't clone or update the vault on the box — it timed out or the box "
                    + "can't reach github.com (a stalled transfer). Confirm outbound access to "
                    + "github.com, then Retry."
            }
            set(5, .failed, why); return
        }
        if r.stdout.contains("NEEDWRITE") {
            // Append via stdin — avoids a fragile remote heredoc. Point the rules at the
            // resolved vault dir (matters when home isn't /root).
            let rules = Self.memoryRules.replacingOccurrences(of: "/root/AI_OS", with: vaultDir)
            let w = await runStep("cat >> \(cm)", input: "\n" + rules + "\n", seconds: 30)
            guard w?.ok == true else { set(5, .failed, "Cloned, but couldn't write the memory rules."); return }
        }
        // Point the box's agent paths at its vault clone, and verify the agents can
        // actually discover the commands. A failure here names the path that broke.
        if let why = await installAgentCommands() {
            set(5, .failed, why)
            return
        }
        await setClaudeRetention()   // stop Claude's 30-day auto-prune of /resume history
        let head = r.stdout.split(separator: "\n")
            .first { $0.hasPrefix("VAULT_HEAD=") }?
            .replacingOccurrences(of: "VAULT_HEAD=", with: "") ?? "present"
        set(5, .done, "Vault \(head) + memory rules + slash commands in place.")
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
            await setupObsidianMCP()
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
        var sysInstall: CommandResult?
        if !sys.isEmpty {
            set(6, .running, "Installing \(sys.joined(separator: " + "))…")
            let pkgs = sys.joined(separator: " ")
            sysInstall = await runStep("""
            SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo "
            echo "INSTALL_SYS_BEGIN \(pkgs)"
            if command -v apt-get >/dev/null 2>&1; then echo "PKG_MANAGER=apt-get"; DEBIAN_FRONTEND=noninteractive ${SUDO}apt-get -o Dpkg::Use-Pty=0 -o Acquire::AllowReleaseInfoChange=true -o Acquire::AllowReleaseInfoChange::Label=true --allow-releaseinfo-change update -qq || true; DEBIAN_FRONTEND=noninteractive ${SUDO}apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y \(pkgs)
            elif command -v dnf >/dev/null 2>&1; then echo "PKG_MANAGER=dnf"; ${SUDO}dnf install -y \(pkgs)
            elif command -v yum >/dev/null 2>&1; then echo "PKG_MANAGER=yum"; ${SUDO}yum install -y \(pkgs)
            elif command -v apk >/dev/null 2>&1; then echo "PKG_MANAGER=apk"; ${SUDO}apk add \(pkgs)
            else echo NO_PKG_MGR; exit 1; fi
            hash -r 2>/dev/null || true
            for t in \(pkgs); do command -v "$t" && echo "INSTALLED_$t=ok" || { echo "INSTALLED_$t=missing"; exit 20; }; done
            echo "INSTALL_SYS_DONE \(pkgs)"
            """, seconds: 240)
            guard sysInstall?.ok == true else {
                set(6, .failed, "Couldn't install \(sys.joined(separator: " + ")) — \(failureTail(sysInstall))")
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
            set(6, .failed, "Couldn't install \(sysStill.joined(separator: " + ")) — verify still reports missing after install. \(failureTail(sysInstall))")
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
        await setupObsidianMCP()
    }

    private func authHint(_ tool: String) -> String {
        switch tool {
        case "claude": return "run `claude` then `/login`"
        case "codex":  return "`codex login`"
        case "cr":     return "`cr auth login`"
        default:       return tool
        }
    }

    private func failureTail(_ result: CommandResult?) -> String {
        guard let result else { return "Timed out." }
        let combined = (result.stderr + "\n" + result.stdout)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = combined.suffix(8).joined(separator: " ")
        return tail.isEmpty ? "exit \(result.exitCode)" : "exit \(result.exitCode): \(tail)"
    }

    // The filesystem-based Obsidian "second memory" MCP server: obsidian-mcp-server on
    // PyPI, installed with uv as ~/.local/bin/obsidian-mcp. No Obsidian app / API key —
    // it reads the vault straight off disk, so agents on the box get the same
    // obsidian_list/search/append/daily tools the mini has.
    private var obsidianBin: String { "\(resolvedHome)/.local/bin/obsidian-mcp" }
    // The server takes its vault ONLY from its own config file (it does NOT read any
    // OBSIDIAN_VAULT_PATH env var — verified against the source: get_vault_path() reads
    // config["vault_path"] from here and nothing else). Both clients share this one file.
    private var obsidianConfig: String { "\(resolvedHome)/.config/obsidian-mcp/config.json" }

    // MARK: - Step 7 (app): install + wire the Obsidian second-memory MCP into Claude + Codex
    func setupObsidianMCP() async {
        guard !Task.isCancelled else { return }
        current = 7
        set(7, .running, "Installing the Obsidian second-memory server…")
        let binEsc = SSHManager.shellEscaped(obsidianBin)

        // 1. Install uv (if missing) then the filesystem-based obsidian-mcp-server, and
        //    confirm the binary landed. The version is PINNED: the bare PyPI name
        //    `obsidian-mcp-server` is shared by several unrelated forks (one env-var-based
        //    with an `obsidian-mcp-server` entry point, this one config.json-based with an
        //    `obsidian-mcp` entry point). Pinning 0.2.0 guarantees the entry-point name and
        //    the config mechanism below always match. `uv tool install` is idempotent;
        //    tolerate the "already installed" exit and rely on the binary check as the gate.
        let install = """
        export PATH="$HOME/.local/bin:$PATH"
        command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
        export PATH="$HOME/.local/bin:$PATH"
        uv tool install 'obsidian-mcp-server==0.2.0' >/dev/null 2>&1 || uv tool upgrade obsidian-mcp-server >/dev/null 2>&1 || true
        [ -x \(binEsc) ] && echo OBSIDIAN_OK || { echo OBSIDIAN_MISSING; exit 1; }
        """
        let i = await runStep(install, seconds: 240)
        guard i?.ok == true, i?.stdout.contains("OBSIDIAN_OK") == true else {
            set(7, .failed, "Couldn't install the Obsidian MCP server (uv → obsidian-mcp-server) on "
                + "the box — the installer timed out or the box can't reach astral.sh / PyPI. "
                + "\(failureTail(i)) Retry.")
            return
        }

        // 2. Point the server at the vault — THIS is what actually configures it. Merge
        //    into config.json with python (idempotent, preserves daily-notes settings);
        //    the vault path passes as an env var so there's no shell-quoting/injection.
        set(7, .running, "Pointing the server at the vault…")
        let cfgPy = """
        import json, os
        p = os.path.expanduser(os.environ['OBS_CFG'])
        d = {}
        if os.path.isfile(p):
            try:
                d = json.load(open(p))
            except Exception:
                d = {}
        d['vault_path'] = os.environ['OBS_VAULT']
        os.makedirs(os.path.dirname(p), exist_ok=True)
        json.dump(d, open(p, 'w'), indent=2)
        print('VAULT_OK')
        """
        let cfg = await runStep(
            "OBS_CFG=\(SSHManager.shellEscaped(obsidianConfig)) OBS_VAULT=\(SSHManager.shellEscaped(vaultDir)) python3",
            input: cfgPy, seconds: 40)
        guard cfg?.ok == true, cfg?.stdout.contains("VAULT_OK") == true else {
            set(7, .failed, "Installed the server but couldn't write its vault config (\(obsidianConfig)) — \(failureTail(cfg)) Retry.")
            return
        }

        // 3. Register the server with Codex (~/.codex/config.toml). Python, not a grep +
        //    append: the old version guarded the whole thing on `grep [mcp_servers.obsidian]`
        //    and echoed CODEX_ALREADY, so an already-registered box could never be corrected —
        //    onboarding-only again. This ensures the block AND its env on every run.
        //
        //    LOG_LEVEL matters more than it looks. obsidian-mcp-server reads a .env from
        //    whatever cwd Codex launches it in. Laravel projects set lowercase
        //    LOG_LEVEL=debug (relayPTC.com/.env:21), and newer builds validate against
        //    ^(DEBUG|INFO|WARNING|ERROR|CRITICAL)$ — so the server dies in startup
        //    validation and Codex reports "connection closed: initialize response". An
        //    explicit env var here beats the project's .env file (verified).
        //
        //    The boxes only escape this today by luck: their Laravel .envs happen not to set
        //    LOG_LEVEL, and they happen to run an older build (1.28.1) without the strict
        //    check. Either can change on the next `uv tool upgrade` or the next project
        //    deployed. Pin it so the box doesn't depend on either.
        set(7, .running, "Registering Obsidian with Codex…")
        let codexPy = """
        import os, re, time
        p = os.path.expanduser('~/.codex/config.toml')
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if not os.path.exists(p):
            open(p, 'a').close()
        t = open(p).read()
        orig = t
        if '[mcp_servers.obsidian]' not in t:
            t += '\\n[mcp_servers.obsidian]\\ncommand = "%s"\\nargs = []\\n' % os.environ['OBS_BIN']
        # Ensure [mcp_servers.obsidian.env] exists and pins LOG_LEVEL.
        m = re.search(r'^\\[mcp_servers\\.obsidian\\.env\\][ \\t]*\\n(.*?)(?=^\\[|\\Z)', t, re.S | re.M)
        if m:
            if not re.search(r'^[ \\t]*LOG_LEVEL[ \\t]*=', m.group(1), re.M):
                t = t[:m.end(1)] + 'LOG_LEVEL = "INFO"\\n' + t[m.end(1):]
        else:
            t += '\\n[mcp_servers.obsidian.env]\\nLOG_LEVEL = "INFO"\\n'
        if t != orig:
            open(p + '.bak-%d' % int(time.time()), 'w').write(orig)
            open(p, 'w').write(t)
            print('CODEX_WROTE')
        else:
            print('CODEX_ALREADY')
        # Prove it, rather than trusting that a write returned 0.
        v = open(p).read()
        assert '[mcp_servers.obsidian]' in v, 'obsidian block missing after write'
        env = re.search(r'^\\[mcp_servers\\.obsidian\\.env\\][ \\t]*\\n(.*?)(?=^\\[|\\Z)', v, re.S | re.M)
        assert env and re.search(r'^[ \\t]*LOG_LEVEL[ \\t]*=', env.group(1), re.M), 'LOG_LEVEL not pinned'
        print('CODEX_VERIFIED')
        """
        let c = await runStep("OBS_BIN=\(binEsc) python3", input: codexPy, seconds: 40)
        guard c?.ok == true, c?.stdout.contains("CODEX_VERIFIED") == true else {
            set(7, .failed, "Installed the server but couldn't register it in ~/.codex/config.toml "
                + "with LOG_LEVEL pinned — \(failureTail(c)) Retry.")
            return
        }

        // 4. Register the server with Claude Code (~/.claude.json, user scope). That file
        //    is JSON, so merge with python — idempotent, preserves every other key.
        set(7, .running, "Registering Obsidian with Claude…")
        let claudePy = """
        import json, os, time
        p = os.path.expanduser('~/.claude.json')
        d = {}
        if os.path.isfile(p):
            try:
                d = json.load(open(p))
            except Exception:
                d = {}
            try:
                import shutil
                shutil.copy(p, p + '.bak-%d' % int(time.time()))
            except Exception:
                pass
        d.setdefault('mcpServers', {})
        d['mcpServers']['obsidian'] = {
            'type': 'stdio',
            'command': os.environ['OBS_BIN'],
            'args': [],
        }
        os.makedirs(os.path.dirname(p), exist_ok=True)
        json.dump(d, open(p, 'w'), indent=2)
        print('CLAUDE_OK')
        """
        let cl = await runStep("OBS_BIN=\(binEsc) python3", input: claudePy, seconds: 40)
        guard cl?.ok == true, cl?.stdout.contains("CLAUDE_OK") == true else {
            set(7, .failed, "Installed the server + Codex config but couldn't write ~/.claude.json — \(failureTail(cl)) Retry.")
            return
        }

        set(7, .done, "Obsidian second memory wired into Claude + Codex (vault at \(vaultDir)).")
        await finish()
    }

    // MARK: - Step 8 (app): verify the round-trip + commit the host to the app
    func finish() async {
        guard !Task.isCancelled else { return }
        current = 8
        set(8, .running, "Verifying read + write access…")
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
            set(8, .done, "\(host.displayName) is set up and added to the app.")
            finished = true
        } else {
            set(8, .failed, "Verify failed — the deploy key likely needs WRITE access "
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
        case 7: await setupObsidianMCP()
        case 8: await finish()
        default: break
        }
    }

    /// The memory-system block appended to a server's global CLAUDE.md — same rules as
    /// the mini. The add-server wizard installs the filesystem-based Obsidian MCP, so the
    /// second-memory tools are available here too (no Obsidian app needed).
    static let memoryRules = """
    # Shared Memory — AI_OS Vault

    Your long-term memory is the AI_OS vault at /root/AI_OS — a git repo synced through
    GitHub, shared with the agents on the mini and the other servers.

    ## Second memory (Obsidian MCP)
    This box has the filesystem-based Obsidian MCP server wired into Claude + Codex — it
    reads the vault directly (no Obsidian app). Use its obsidian_list / obsidian_search /
    obsidian_append / obsidian_daily tools to read and write notes; fall back to plain
    file reads (cat / grep / rg) if the MCP tools aren't loaded.

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

    ### /saveproject  (you-triggered — this IS permission to push AND merge)
    1. Update beads: `bd close` finished, `bd update` progress, `bd create` new pending items
    2. Write a session log at <project>/logs/YYYY-MM-DD-description.md (frontmatter, type: session)
    3. Record what was done + decisions; link bead IDs; update DECISIONS.md/ROADMAP.md if changed
    4. Write durable knowledge to /root/AI_OS/permanent/ (kebab-case, frontmatter, [[wikilinks]])
    5. Run CodeRabbit (`cr`) on the changes — address findings; never commit unreviewed code
    6. git add + commit + push on the current feature branch
    7. Open + auto-merge the PR: `gh pr create --fill` if none exists, then `gh pr merge --squash --delete-branch` (skip only if not cleanly mergeable)
    8. Sync the vault: git -C /root/AI_OS add -A && git -C /root/AI_OS commit -m "<what>" && git -C /root/AI_OS push

    ## Rules (how to work)
    - Call him Kam every reply.
    - ADHD: one thing at a time, short replies, never make him repeat himself, don't talk down.
      If he's cursing in frustration, stop and do a breathing exercise — see CTX-aboutme.
    - Never push OR merge to git on your own. ONLY triggers: Kameron runs /saveproject (which authorizes
      commit → push → PR → auto-merge), or gives an explicit imperative to push/merge now (e.g. "push
      and merge") — a casual mention of the words "push"/"merge" in conversation is NOT authorization.
      Mid-work commits / "looks done" / finishing a feature are NOT permission.
    - Every new task = its own branch. Commit locally as you go; push only per the rule above.
    - Run CodeRabbit (`cr`) on every commit. Shared bd beads per project.
    - Never undo an approved fix — ask first. Fix it right the first time. Root cause, not symptoms.
    - Only change what was explicitly asked — no surprise refactors/features.
    - Database safety: never migrate:fresh / migrate:reset; migrate only. Ask before destructive DB commands.
    - Secrets stay in gitignored .env — never commit them.
    """

    // MARK: - Agent commands: NOT stored here, deliberately
    //
    // The command bodies used to live here as ~100 lines of Swift string literals that
    // installAgentCommands() cat'd onto each box at onboarding. That is what froze every
    // box at its onboarding build: gatsa-prod and gatsa-web ran a saveproject half the
    // current size for weeks — including an UNPINNED `git -C <vault> add -A && commit &&
    // push` that would commit the vault to whatever branch was checked out — because
    // shipping new text required re-onboarding, and nobody re-onboarded.
    //
    // The bodies now live in the vault at commands/, exactly once, and reach every
    // machine by symlink. kepler, the boxes' daily timers, and this wizard all run the
    // same commands/install-links.sh. To change a command, edit the vault — not Swift.
    //
    // Putting command text back in this file is the original bug. Don't.
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
        _ = await runStep("python3", input: py, seconds: 30)
    }

    /// Points the box's agent command/skill paths at its vault clone, by running the
    /// vault's own `commands/install-links.sh`. Safe to re-run — this is also the
    /// repair/re-sync path for an already-onboarded box.
    ///
    /// This function used to embed the command bodies as Swift string literals and
    /// `cat >` them onto the box. That was wrong three separate ways, and every one of
    /// them shipped to production:
    ///
    ///  1. It wrote Codex's skills to `~/.agents/skills/`, which Codex does not read.
    ///     Worse, the whole idea was misconceived: `$saveproject` is not a skill and never
    ///     has been — it was absent from `~/.codex/skills` on every machine. It works
    ///     because `~/.codex/AGENTS.md`, which Codex reads globally every session,
    ///     documents the convention. gatsa-prod had no such file at all, so `$saveproject`
    ///     genuinely could not work there, while this function reported success.
    ///
    ///  2. It only checked that `cat > path` exited 0. A write into a directory nothing
    ///     reads exits 0 every time, so the step went green for ~2 weeks and 4 onboardings
    ///     while delivering nothing. A write that succeeds is not evidence a feature works.
    ///
    ///  3. It ran only at onboarding, so a box froze at whatever build onboarded it.
    ///     gatsa-prod and gatsa-web ran a `saveproject` half the current size for weeks,
    ///     including an UNPINNED `git -C <vault> add -A && commit && push` that would
    ///     commit the vault to whatever branch happened to be checked out.
    ///
    /// The content now lives in the vault, exactly once, and every machine — kepler, the
    /// daily timers, and this wizard — runs the same script. Do not reintroduce command
    /// text here: putting bodies back into Swift strings is the original bug.
    /// Returns nil on success, or the reason it failed — the caller shows that reason.
    /// The old version returned a bare Bool and the wizard just said "Retry", which is
    /// how a broken install looked identical to a working one for two weeks.
    private func installAgentCommands() async -> String? {
        let script = SSHManager.shellEscaped("\(vaultDir)/commands/install-links.sh")

        // Fail loudly if the vault predates the commands tree, rather than silently
        // falling back to a stale embedded copy.
        guard let probe = await runStep("test -f \(script) && echo present", seconds: 30),
              probe.ok, probe.stdout.contains("present") else {
            return "The vault at \(vaultDir) has no commands/install-links.sh — is it on main and up to date?"
        }

        // The script links the agent paths at the vault AND verifies discovery: every
        // link resolves, every target exists, is non-empty, and ~/.codex/AGENTS.md is
        // present and full-parity. It exits non-zero if any of that fails, so a red step
        // here means the commands are genuinely not installed — not that a write
        // happened to return 0.
        let cmd = "VAULT=\(SSHManager.shellEscaped(vaultDir)) "
            + "TARGET_HOME=\(SSHManager.shellEscaped(resolvedHome)) "
            + "bash \(script)"
        guard let r = await runStep(cmd, seconds: 120) else {
            return "install-links.sh timed out or never completed."
        }
        guard r.ok else {
            // Surface the script's own FAIL lines — they name the exact path that broke.
            let why = (r.stdout + "\n" + r.stderr)
                .split(separator: "\n")
                .filter { $0.contains("FAIL") || $0.contains("MISSING") }
                .joined(separator: "\n")
            return why.isEmpty
                ? "Agent commands failed verification on this box."
                : "Agent commands failed verification:\n\(why)"
        }
        return nil
    }
}
