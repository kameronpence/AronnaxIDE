import Foundation
import Combine

/// Drives the "New Project" wizard: creates a fully-wired LOCAL project — GitHub repo,
/// beads with a Dolt remote, and vault memory — with nothing left half-made.
///
/// The whole flow lives in one tested vault script, `commands/new-project.sh`. This model
/// does NOT reimplement any of it; it calls the script and surfaces its own progress and
/// FAIL/RESULT lines. Same governing rule as `ServerOnboarding.runVaultScript`: one code
/// path means local creation and the server onboarding can't diverge.
///
/// WHERE IT RUNS — the correction to the original handoff. AronnaxIDE is a Mac GUI that runs
/// on Kameron's MacBook and reaches kepler (the hub) over SSH; the vault, `gh` auth, and the
/// `Projects/` tree all live on kepler, not this Mac. So the script runs **over SSH on the
/// hub**, never as a local `Process` — a local run would execute on the MacBook, where none
/// of what the script needs exists. New projects always target the hub, never the active host
/// (which may be a remote server that has no vault of its own).
@MainActor
final class NewProjectOnboarding: ObservableObject {

    enum Phase: Equatable { case form, running, done, failed }

    /// A GitHub account the project can be created under. `alias` is the SSH host alias the
    /// origin uses (github.com = personal, github-gatsa = the GATSA account); `owner` is the
    /// resolved account name, used as both the repo owner and the gh account to act as.
    struct Account: Identifiable, Hashable {
        let id: String       // == alias, unique per account
        let alias: String
        let owner: String
        var displayName: String { owner }
    }

    @Published var name = ""
    @Published var isPublic = false

    @Published var accounts: [Account] = []
    @Published var selectedAccountID: String?
    @Published var accountsLoading = false
    @Published var accountsError: String?   // set when one or more accounts couldn't be resolved

    @Published var phase: Phase = .form
    @Published var log = ""            // captured script output, shown live-ish in the pane
    @Published var resultLine = ""     // the RESULT: OK line, or the reason it failed
    @Published var createdProjectName = ""

    private let settings: AppSettings
    private var work: Task<Void, Never>?

    init(settings: AppSettings) { self.settings = settings }

    var selectedAccount: Account? { accounts.first { $0.id == selectedAccountID } }

    /// Enumerate the GitHub accounts on the hub via ONE consolidated command — the vault's
    /// `list-github-accounts.sh`, run in a login shell exactly like `new-project.sh`.
    ///
    /// This replaced a per-alias approach (parse ssh config + one `ssh -T` per alias, each its
    /// own runShell) that silently returned only the default account over some SSH transports,
    /// so GATSA never appeared. Doing all the ssh work in a single script ON the box — where
    /// `ssh -G` sees the real config/Includes and the keys are present — is robust: verified to
    /// return both accounts over direct, non-login, and login shells. The script emits
    /// `<alias>|<account>` lines (deploy keys already filtered).
    func loadAccounts(force: Bool = false) async {
        guard let hub, force || accounts.isEmpty else { return }
        accountsLoading = true
        accountsError = nil
        let script = SSHManager.shellEscaped("\(vaultDir)/commands/list-github-accounts.sh")
        let cmd = "zsh -lc \(SSHManager.shellEscaped("bash \(script)"))"
        let result = try? await SSHManager.shared.runShell(cmd, on: hub, timeoutSeconds: 60)
        var found: [Account] = []
        var anyUnresolved = false
        for line in (result?.stdout ?? "").split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            if parts[1] == "!UNRESOLVED" { anyUnresolved = true; continue }
            found.append(Account(id: parts[0], alias: parts[0], owner: parts[1]))
        }
        // Only trust the list if the script actually completed (exit 0). A non-zero exit means
        // the enumeration itself broke, so whatever we parsed may be a truncated subset — the
        // very failure this whole approach exists to avoid. Discard it entirely so Create stays
        // blocked (it requires a non-empty list) and only the error + Retry shows.
        if result?.ok != true {
            accounts = []
            accountsError = "Couldn't list your GitHub accounts on kepler — check the connection and Retry."
        } else {
            accounts = found
            if found.isEmpty {
                accountsError = "No GitHub accounts resolved on kepler — Retry."
            } else if anyUnresolved {
                accountsError = "A GitHub account couldn't be reached and was left out — Retry to include it."
            }
        }
        // Keep a valid selection: default to personal (github.com) if present, else the first.
        if selectedAccountID == nil || !accounts.contains(where: { $0.id == selectedAccountID }) {
            selectedAccountID = accounts.first { $0.alias == "github.com" }?.id ?? accounts.first?.id
        }
        accountsLoading = false
    }

    /// New projects ALWAYS go on the hub (kepler): that is where the vault, `gh` auth, and
    /// `Projects/` live. Deliberately not `activeHost`, which can be a remote box.
    private var hub: Host? { settings.hub }
    private var vaultDir: String { settings.resolvedAgentWorkdir }

    /// Creating a project writes to the hub (files + a GitHub repo), so it's subject to the
    /// same guardrails the panes honor: block on a read-only hub, confirm when the global
    /// "confirm before every write" is on. The view routes Create through these.
    var hubIsReadOnly: Bool { settings.isReadOnly(hub) }
    var confirmWrites: Bool { settings.confirmWrites }

    /// The same rule the script enforces (the name becomes a directory, a GitHub repo name,
    /// and a bd prefix): plain ASCII `[A-Za-z0-9._-]`, never starting with `.`. Validate here
    /// too so the user gets an inline error instead of a script exit. ASCII-only on purpose —
    /// Swift's `isLetter`/`isNumber` accept Unicode (`café`, `项目1`), which the script rejects.
    /// A leading `-` is rejected too: the script parses any leading-hyphen argument as a flag
    /// (`unknown flag: -demo`, exit 2), so such a name could never succeed.
    var nameValid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !n.hasPrefix("."), !n.hasPrefix("-") else { return false }
        return n.allSatisfy { Self.allowedNameChars.contains($0) }
    }
    private static let allowedNameChars =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    /// The single choke point for launching a run — re-checks every guardrail here, not just
    /// in the view, so a confirmation dialog that was open while the hub flipped to read-only
    /// (or an empty/invalid name) can't slip a provisioning run through when it resolves.
    /// Also flips to `.running` synchronously so a rapid double-tap of Create can't launch two
    /// runs racing through git init / commit / `bd init`.
    func start() {
        guard phase != .running, nameValid, !hubIsReadOnly else { return }
        phase = .running
        work = Task { await run() }
    }
    func cancel() { work?.cancel(); work = nil }

    func reset() {
        cancel()
        name = ""
        isPublic = false
        phase = .form
        log = ""
        resultLine = ""
        createdProjectName = ""
    }

    private func run() async {
        guard let hub else {
            phase = .failed
            resultLine = "No hub host is configured — can't reach kepler, where the vault lives."
            return
        }
        let projectName = name.trimmingCharacters(in: .whitespaces)
        // phase is already .running (set synchronously in start()); just clear prior output.
        log = ""
        resultLine = ""

        let script = SSHManager.shellEscaped("\(vaultDir)/commands/new-project.sh")

        // Fail loudly if the vault predates the script rather than silently doing nothing —
        // a skipped run here would look like a create that quietly did nothing.
        // Cancellation (wizard closed mid-run) also surfaces as a thrown error → nil here;
        // check it BEFORE mutating to .failed, or a cancelled+reset model gets clobbered
        // back to a failure state after closeWizard already reset it to .form.
        let probe = try? await SSHManager.shared.runShell(
            "test -f \(script) && echo present", on: hub, timeoutSeconds: 30)
        if Task.isCancelled { return }
        guard let probe, probe.ok, probe.stdout.contains("present") else {
            phase = .failed
            resultLine = "The vault at \(vaultDir) has no commands/new-project.sh — is it on main and up to date?"
            return
        }

        // VAULT explicit (belt-and-braces over the script's autodetect). OWNER/ORIGIN_HOST/
        // GH_ACCOUNT come from the picked account: the repo owner, the SSH alias the origin
        // uses, and the gh account to create as (the script switches to it and restores after).
        // Falls back to the personal default when no account resolved. The name is shell-escaped
        // — already validated to a safe charset, but never trust a form value into a command.
        let owner = selectedAccount?.owner ?? "kameronpence"
        let alias = selectedAccount?.alias ?? "github.com"
        let cmd = "VAULT=\(SSHManager.shellEscaped(vaultDir)) "
            + "OWNER=\(SSHManager.shellEscaped(owner)) "
            + "ORIGIN_HOST=\(SSHManager.shellEscaped(alias)) "
            + "GH_ACCOUNT=\(SSHManager.shellEscaped(owner)) "
            + "bash \(script) \(SSHManager.shellEscaped(projectName))"
            + (isPublic ? " --public" : "")

        // Run under a LOGIN shell. `runShell` uses a non-login remote shell, whose PATH (from
        // ~/.zshenv only) has git but NOT gh or bd — those come from Homebrew + ~/.local/bin,
        // set in the login files. The script's `command -v gh bd` check would fail on a
        // perfectly configured hub otherwise. Verified on kepler: `env -i zsh -c` resolves
        // only git; `env -i zsh -lc` resolves all three. Same reason the terminal panes use
        // a login shell for tmux/claude/codex.
        let loginCmd = "zsh -lc \(SSHManager.shellEscaped(cmd))"

        // Generous timeout: gh repo create + first push + bd init (spins up Dolt) + dolt push
        // can take a while on the first run for a project.
        let r = try? await SSHManager.shared.runShell(loginCmd, on: hub, timeoutSeconds: 300)
        if Task.isCancelled { return }   // wizard closed mid-run — don't overwrite reset state
        guard let r else {
            phase = .failed
            resultLine = "new-project.sh timed out or never completed."
            return
        }

        log = (r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Trust the script's own verdict, not just the exit code: it prints `RESULT: OK` only
        // after verifying origin/main, the dolt remote, vault memory, and a real bd write.
        if r.ok, let ok = resultOKLine(r.stdout) {
            resultLine = ok
            createdProjectName = projectName
            // A freshly created project must appear, not arrive pre-hidden. `hiddenProjectPaths`
            // is keyed by full path and never pruned, so if a project once lived at this path,
            // was hidden, then deleted, the stale flag would hide the new one on sight. Clear it.
            let newPath = (settings.projectsRoot as NSString).appendingPathComponent(projectName)
            settings.setProjectHidden(newPath, false)
            settings.requestProjectsRefresh()   // hub rescans Projects/ so it shows in the sidebar
            phase = .done
        } else {
            resultLine = failureReason(r)
            phase = .failed
        }
    }

    private func resultOKLine(_ stdout: String) -> String? {
        stdout.split(separator: "\n").map(String.init)
            .first { $0.contains("RESULT: OK") }?
            .trimmingCharacters(in: .whitespaces)
    }

    /// Surface the script's own FAIL/VERIFY/RESULT lines — they name the exact thing that broke.
    private func failureReason(_ r: CommandResult) -> String {
        let why = (r.stdout + "\n" + r.stderr)
            .split(separator: "\n").map(String.init)
            .filter { $0.contains("FAIL") || $0.contains("RESULT") || $0.contains("VERIFY") }
            .suffix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return why.isEmpty ? "new-project.sh failed (exit \(r.exitCode))." : why
    }
}
