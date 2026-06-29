# AronnaxIDE — Project Handoff & Setup Summary

> Hand this file to Claude in a new window to restore full context.
> (`read /Users/kameron/Documents/Coding Projects/IDE/AronnaxIDE-handoff.md`)

## What it is
**AronnaxIDE** (internal product name still `MiniIDE` in code/bundle) is a native **Swift/SwiftUI macOS app**. You build and run it **on your MacBook via Xcode (⌘R)**. It's a control surface for a **headless Mac mini named `kepler`**, which it drives over system `ssh` + `tmux`.

**Hard constraints (do not violate):**
- **No API, ever.** All AI runs on subscription CLIs only — **Claude Code** and **Codex** running *on the mini* inside tmux. No tokens/billing.
- **Sleep-resilient.** Agents + dev servers live in tmux on the mini, so closing/sleeping the MacBook never interrupts them; the app just re-attaches.
- **One source of truth on the mini.** The Obsidian vault and the beads DB live on the mini; the app and the agents read/write the same files.

## Surfaces (tabs)
Terminal · Coding (Claude/Codex agent TUIs) · Browser · Vault (Obsidian markdown) · Beads (bd issues) · Logs · Health · Git/Deploy — plus a left sidebar (Hosts + clickable Projects) and a usage panel (Claude + Codex % used / reset times).

## Infrastructure / setup
- **Host:** Mac mini `kepler`. `~/.ssh/config` on the MacBook: `Host kepler` → `HostName keplers-mac-mini.local`, `User kepler`. Static IP `10.63.1.233`, Private Wi-Fi Address **off** (it broke DHCP reservations earlier).
- **Connectivity:** system `/usr/bin/ssh` with **ControlMaster multiplexing** (one shared socket per host, in `$TMPDIR/miniide-cm/`), keepalives, **ProxyJump** for EC2/Lightsail (reached *through* the mini).
- **tmux on the mini (`~/.tmux.conf`) — IMPORTANT:** `set -g mouse off` (mouse-on caused scroll to trap the pane in copy-mode and swallow keystrokes — the "terminal is broken" bug). Also `set-clipboard on`, `allow-passthrough on`, custom status colors.
- **Agent workdir (fallback):** `/Users/kepler/Documents/Projects/AI_OS` — this is the **Obsidian vault** that is the agents' shared memory. Agents now run **per-project** (tmux session keyed by the project dir) when a project is selected.
- **Issue tracking:** **beads (`bd`)**, Dolt-backed, run over ssh. Used for ALL task tracking (no TodoWrite/markdown TODOs).
- **Git:** GitHub repo `kameronpence/mini-ide`. Active branch **`m8-projects`** (NOT merged to `main` yet).

## Build / run
- Project file is generated: `xcodegen generate` → `MiniIDE.xcodeproj` (gitignored). `project.yml` is the source of truth.
- Build check: `xcodebuild -project MiniIDE.xcodeproj -scheme MiniIDE -destination 'platform=macOS' build`
- Run: **Xcode ⌘R** (the running app is Xcode-managed; Claude can't relaunch it — you must ⌘R after changes).
- App is non-sandboxed, no hardened runtime (so it can shell out to ssh + use WKWebView/Process).

## Workflow rules (mandatory)
1. **Codex is the required verifier** — `codex review --uncommitted` on every change before commit. **If Codex usage runs out, stop code work** (it resets on a schedule).
2. **xcodebuild after every change.**
3. **beads for all tracking** (`bd ready`, `bd create`, `bd close`).
4. Each feature on its own branch.
5. Secrets stay in `.gitignore` — never commit them, never have Claude send them; you enter credentials directly.
6. Comms: one thing at a time, short, don't make you repeat yourself, don't talk down.
7. Session close: commit + **push** (work isn't done until pushed).

## Key files
- `MiniIDEApp.swift` — `@main`, WindowGroup + Settings scene.
- `ContentView.swift` — sidebar + tabbed/split workspace + status bar; `WorkspaceTab` enum; `SidebarView` (clickable projects → `settings.selectedProjectPath`).
- `Models/AppSettings.swift` — hosts/accounts/projects, `agentWorkdir`, `selectedProjectPath`, `activePath`; persists workdir/tmux/accounts to UserDefaults.
- `Models/Fleet.swift` — `Host`, `HostReach` (`.direct` / `.proxyJump(via:)`), `GitHubAccount`, `Project`.
- `Services/SSHManager.swift` — ssh arg construction, ControlMaster, ProxyJump, port-forward args, `streamArguments` (logs), `closeMaster`/`resetMasterOnce`.
- `Services/` — `RemoteFS` (read/write/`contentHash`), `LogStreamController`, `HealthController`, `BeadsController`, `GitController`, `ProjectService`, `UsageService`, `AgentController`, `ConnectionMonitor`.
- `Panes/` — `TerminalPane` (host picker + auto-reconnect), `CodingPane` (per-project agents), `BrowserPane`, `VaultPane` (editor + preview + wikilinks + RemoteWatcher), `BeadsPanel`, `LogViewer`, `HostHealthPanel`, `GitDeployPanel`, `Workspace.swift` (recursive split tiling).
- `SettingsView.swift` — editable settings (⌘,).

## What was built (all committed + pushed to `m8-projects`)
- **M8 global project selection** — click a project in the sidebar; Coding/Vault/Beads/Git all follow it. Removed per-panel dropdowns. Agents run per-project.
- **Terminal fix** — was a tmux copy-mode trap (not a connection issue); set tmux mouse off. Added **auto-reconnect with backoff**.
- **M9 Logs** — live remote log streaming (tail file / `pm2 logs` / `docker logs -f`), filter, real pause/resume, follow.
- **M11 Health** — host reachability + alive tmux sessions, concurrent + bounded probes.
- **Vault wikilinks** — `[[links]]` clickable in preview, resolve by basename.
- **RemoteWatcher (M6.4)** — polls the open note's md5; auto-reloads on agent edit when clean; **conflict guard** (banner + Reload / Keep mine) that blocks navigation until resolved; all writes are conflict-aware.
- **M8 host switcher + multi-host tunnels** — Terminal host picker (EC2/Lightsail via ProxyJump); Browser port-forward host picker.
- **M12 Settings** — editable + persisted workdir/tmux/GitHub accounts.
- **Branding** — AronnaxIDE name, app icon (`CFBundleIconName: AppIcon`).

## Current state
- All milestones **M0–M12 implemented**, build **green**.
- **#1 Settings + #3 host switcher were built WITHOUT Codex** (it was out) — need a Codex pass before merge.
- Everything else is Codex-reviewed.

## Parked items (NOT done)
1. **Git/Deploy account-mismatch detection** — the only genuinely unfinished *feature*: the Git panel shows the push identity + a generic confirm, but does **not** auto-assign GitHub accounts to projects nor auto-flag a wrong-account push. Decision pending: build it, or ship as-is.
2. **`IDE-9vw` (P3)** — persist the split-pane layout across launches (deferred, needs Codex).
3. **Merge `m8-projects` → `main`** — pending Codex pass on #1/#3.
4. Stale "lands later / read-only for now" comments in `AppSettings.swift` and `GitDeployPanel.swift` should be deleted (the work is done).

## Next task: Obsidian / token reduction
Goal: restructure the agents' shared Obsidian vault at **`/Users/kepler/Documents/Projects/AI_OS`** on the mini to **cut token spend** (it's the agents' shared context/memory). Read the websites the user provides + the current vault structure, then propose concrete changes.
