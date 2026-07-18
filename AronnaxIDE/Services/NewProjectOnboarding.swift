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

    @Published var name = ""
    @Published var isPublic = false

    @Published var phase: Phase = .form
    @Published var log = ""            // captured script output, shown live-ish in the pane
    @Published var resultLine = ""     // the RESULT: OK line, or the reason it failed
    @Published var createdProjectName = ""

    private let settings: AppSettings
    private var work: Task<Void, Never>?

    init(settings: AppSettings) { self.settings = settings }

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

        // VAULT explicit (belt-and-braces over the script's autodetect); OWNER defaults to
        // kameronpence inside the script. The name is shell-escaped — it's already validated
        // to a safe charset, but never trust a form value straight into a command.
        let cmd = "VAULT=\(SSHManager.shellEscaped(vaultDir)) "
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
