# Plan: "AronnaxIDE" — a native macOS SwiftUI IDE that drives a headless Mac mini

## Context

You want a native macOS app that runs on your MacBook Pro and acts as a control
surface for a **headless Mac mini**. The mini is where the real work happens —
Claude Code and Codex CLIs run there inside **tmux**, along with any dev servers
they spin up. The MacBook is just a window onto that machine.

Three requirements drive the whole design:

1. **No API, ever.** All AI runs on your existing subscriptions: Claude Code CLI
   uses Claude Pro/Max, Codex CLI uses your ChatGPT plan. Plain (non-coding) chat
   with Claude / ChatGPT happens through the **web chats** (claude.ai /
   chatgpt.com) logged in with those same subscriptions. No tokens, no billing.
2. **Sleep-resilient.** Because the agents and dev servers live in **tmux on the
   mini**, they keep running whether the MacBook is awake, asleep, or closed. The
   app never holds state — when the laptop wakes, it reconnects SSH and re-attaches
   to the existing tmux sessions, and nothing on the mini was interrupted.
3. **Five surfaces**: a Terminal, a Chat pane (drives the CLI agents + web chats),
   a Browser (to view what the agents build), an **Obsidian vault editor**, and a
   **beads issue panel** — all backed by the mini.
4. **One source of truth on the mini.** The Obsidian vault and the bd (beads)
   database live on the mini. The app edits them over SSH and the agents read/write
   the *same* files — so what you see and what the agents see never diverge.
5. **The mini is a hub to many machines.** Beyond the mini there are AWS **EC2**
   (staging/prod) and **Lightsail** instances. They're reached **via the mini
   (ProxyJump)** — reusing the access the mini already has — so the same hop the
   agents use is the hop the app uses.
6. **Multiple GitHub identities, per project.** A "work" account for the
   EC2 staging→prod projects and a "personal" account for mini-local projects (some
   deployed to Lightsail). Each project must commit/push under the *right* account.

## Architecture

**App:** SwiftUI macOS app, single window. Layout: a collapsible **left sidebar**
(Hosts/Projects switcher · Vault file tree · Beads issue list) and a **tabbed/split
main workspace** (Terminal · Chat · Browser · Markdown editor · Beads graph · Logs ·
Git/Deploy), with panes show/hide-able so you can see e.g. editor + browser + chat
at once. Swift 6.3 / Xcode 26.5 (both confirmed installed).

### Foundation: Hosts, Projects & GitHub identity

- **Host** — a machine the app can reach: `mini` (the hub), plus EC2 / Lightsail
  hosts. Each host records how it's reached (`direct` or `proxyJump: mini`), user,
  and identity. Sourced from `~/.ssh/config` where possible; extra metadata in app
  settings. Every feature (terminal, tunnels, logs, git) is **host-scoped**.
- **GitHubAccount** — a named identity (`work`, `personal`) mapped to an SSH host
  alias / key (e.g. `github.com-work`) configured on the mini. The app *displays
  and selects* the identity; the actual keys live on the mini's `~/.ssh`.
- **Project** — ties together: the repo's host + path, its GitHubAccount, and its
  deploy target. e.g. *staging-app* lives on EC2-staging, pushes to `work`, deploys
  to EC2-prod; *my-side-project* lives on the mini, pushes to `personal`, deploys to
  Lightsail. This is the backbone the Git/Deploy panel and correct-identity pushes
  hang off of. The app derives a project's account from its `git remote` URL /
  ssh-host-alias and flags a mismatch before any push.

**Connectivity — shell out to system `/usr/bin/ssh`** (not a pure-Swift SSH lib):
- Respects your existing `~/.ssh/config`, keys, ssh-agent, and ProxyJump for free.
- PTY handling comes from SwiftTerm; reconnection is just relaunching a process.
- Keepalives via `ServerAliveInterval` so dropped links are detected fast.
- **SSH multiplexing (ControlMaster):** one shared connection **per host** (the
  mini, and each EC2/Lightsail box via the mini) is reused by that host's terminal,
  file I/O, bd/git commands, and port-forwards — so the many small calls stay fast
  and don't re-handshake.
- **ProxyJump:** EC2/Lightsail connections set `-J mini` (or the host's
  `ProxyJump`), so onward hops ride the mini exactly like the agents do.
- *Rationale:* far less code and far more robust than reimplementing SSH/PTY with
  Citadel/swift-nio-ssh, and it inherits whatever already works in your terminal.

**Persistence model:** every remote process runs inside a named tmux session on
the mini. The app only ever **attaches** (`tmux new-session -A -s <name>`), so it
is never the source of truth and detach/reattach is lossless.

### Components

1. **Terminal pane** — `SwiftTerm` `LocalProcessTerminalView` running
   `ssh -t <mini> -- tmux new-session -A -s main`. A normal shell, persistent.

2. **Chat pane (drives the CLI agents)** — Claude Code and Codex each run in their
   own tmux window (`agent-claude`, `agent-codex`). The pane shows the agent's TUI
   in an attached SwiftTerm view, with a **chat-style input box** below it that
   sends prompts via `tmux send-keys` to the selected window. A segmented control
   switches between Claude Code / Codex.
   - *Rationale:* both CLIs are full-screen TUIs. Rendering their TUI and feeding
     it input is reliable; scraping streaming TUI output into a custom bubble UI is
     not. This gives a chat-like feel without fighting the TUIs.

3. **Web chats** — `WKWebView` tabs pointed at claude.ai and chatgpt.com, using a
   **persistent** `WKWebsiteDataStore` so your subscription logins stick. This is
   the "chat with Claude and ChatGPT, not API" path.

4. **Browser pane** — `WKWebView` with a URL bar. A **port-forward manager** opens
   `ssh -N -L <local>:localhost:<remote> <mini>` tunnels so dev servers bound to
   the mini's localhost are viewable at `http://localhost:<local>`. Manual URLs
   (incl. LAN `http://mac-mini.local:PORT`) also supported.

5. **Reconnect-on-wake** — a `WakeObserver` listens for
   `NSWorkspace.didWakeNotification` (and network-path changes) and restarts the
   ssh terminal session + all port-forwards. Since tmux/dev servers persist on the
   mini, this is a pure reconnect, not a restart of work.

6. **Obsidian vault pane** — the vault lives on the mini. The sidebar shows the
   markdown file tree (`ssh <mini> find <vault> -name '*.md'`); a file opens in a
   native SwiftUI markdown editor (edit + live preview). Reads/writes go over
   **SFTP** through the shared ControlMaster connection (atomic write-then-rename
   so a half-saved file never collides with an agent). Because the agents edit the
   same files, the pane **watches for remote changes** (`fswatch` on the mini
   streamed over ssh, polling mtimes as fallback) and refreshes — with a conflict
   guard if both you and an agent touched a file. Obsidian-style `[[wikilinks]]`
   are clickable to jump between notes.

7. **Beads (bd) issue panel** — the bd repo lives on the mini. The sidebar/panel
   renders the issue list and ready/blocked/open status from `bd list --json` /
   `bd ready --json`, with a **dependency-graph view** (rendered via a lightweight
   graph layout, or Mermaid in a WKWebView from `bd`'s dep output). You can create
   and update issues (`bd create`, `bd update`, `bd dep`) from the app. The agents
   use the same bd database on the mini for their task memory, so the panel and the
   agents stay in sync; it refreshes on the same watch/poll cycle as the vault.

8. **Host switcher + multi-host tunnels** — the Terminal pane has a host picker;
   selecting a host opens `ssh -t <host> -- tmux new-session -A -s main` (EC2/
   Lightsail via `-J mini`), each host getting its own persistent tmux. The
   port-forward manager can forward any host's web port into the Browser pane
   (e.g. staging's app, or a prod admin port) via the mini.

9. **Remote log viewer** — pick a host + a log source (file path, `journalctl`,
   `pm2 logs`, `docker logs`, …); the pane streams it (`ssh <host> tail -F …`) with
   live text filtering and pause/scrollback. Useful for you and for handing prod
   log context to the agent.

10. **Git/Deploy status panel** — per Project: current branch, dirty/ahead-behind
    state, last commits, and **which GitHub account** it pushes to (with a warning
    if the remote's identity doesn't match the project's configured account). Shows
    a record of pushes and deploys (vibe-code → commit/push → deploy). Read-first;
    actions like commit/push/deploy are explicit buttons that run on the relevant
    host under the correct identity (never auto-fired).

11. **Host health panel** — at-a-glance status: is each host reachable (mini
    directly, others via mini), are the agent tmux windows alive, which tunnels are
    up, and per-project git state — so you can see the whole fleet in one place.

12. **Settings** — hosts (alias, reach-via, user, identity), GitHub accounts,
    projects (host/path/account/deploy target), tmux session names, vault path, bd
    repo path, log sources, and port-forwards. Stored in `UserDefaults` + a small
    config file (and read from `~/.ssh/config` where available).

## Development workflow (how we build AronnaxIDE)

The app is **built and used on this MacBook Pro** (Xcode 26.5 is here; a macOS GUI
app needs it). Two agents collaborate: **Claude Code** and **Codex CLI**, both
local, coordinating through **beads**.

- **Local git repo** in this folder, pushed to a new repo on your **personal**
  GitHub account (e.g. `mini-ide`).
- **This project gets its own beads database** (`.beads/` in the repo) — separate
  from the mini's bd db that the app's Beads panel talks to. *Everything* is logged
  here: each milestone → an epic issue, each task → a child issue with
  dependencies, and decisions captured as issues/notes.
- **Beads is the Claude↔Codex handoff surface.** Because bd's JSONL syncs through
  git, both agents share one tracker that merges like code. Work is claimed by
  marking an issue in-progress so we don't collide; `bd ready` shows what's
  unblocked to pick up next.
- First implementation steps: `git init` → locate/confirm `bd` + `codex` (see
  prerequisites) → `bd init` → seed the milestone/task issues → create the GitHub
  repo and push.

## Build milestones

- **M0** — Xcode app project scaffold; add `SwiftTerm` via SwiftPM; sidebar +
  tabbed-workspace SwiftUI shell; app entitlements (outgoing network for WKWebView).
- **M1** — `SSHManager` with ControlMaster multiplexing; Terminal pane attaching to
  tmux `main`.
- **M2** — Keepalives + reconnect-on-wake (`WakeObserver`).
- **M3** — Chat pane: agent tmux windows, attached view, `send-keys` input box,
  Claude Code / Codex switcher.
- **M4** — Browser pane: port-forward manager + URL bar.
- **M5** — Web-chat tabs (claude.ai, chatgpt.com) with persistent login.
- **M6** — Obsidian vault pane: remote file tree, markdown editor, SFTP load/save,
  remote-change watcher, wikilinks.
- **M7** — Beads panel: issue list + status, dependency graph, create/update,
  shared db with agents.
- **M8** — Hosts/Projects foundation: host registry + ProxyJump, host switcher in
  terminal, multi-host tunnels.
- **M9** — Remote log viewer (stream + filter).
- **M10** — Git/Deploy panel: per-project branch/state, GitHub-account mapping +
  mismatch warning, commit/push/deploy actions.
- **M11** — Host health panel.
- **M12** — Settings UI + polish (layout persistence, reconnect/sync indicators,
  conflict handling).

## Key files (new project)

- `AronnaxIDE.xcodeproj` + `Info.plist` + `AronnaxIDE.entitlements`
- `AronnaxIDEApp.swift` — `@main` App entry, window setup
- `ContentView.swift` — sidebar + tabbed workspace + reconnect/sync status bar
- `HostRegistry.swift` + `Project.swift` + `GitHubAccount.swift` — fleet model,
  ssh-config import, project↔account mapping
- `SSHManager.swift` — per-host Process ssh, ControlMaster mux, ProxyJump,
  port-forwards, reconnect
- `RemoteFS.swift` — SFTP list/read/atomic-write over the shared connection
- `RemoteWatcher.swift` — `fswatch`-over-ssh change stream (+ mtime-poll fallback)
- `WakeObserver.swift` — NSWorkspace/network notifications
- `TerminalPane.swift` — SwiftTerm `NSViewRepresentable`
- `ChatPane.swift` + `AgentController.swift` — agent switch + `tmux send-keys`
- `BrowserPane.swift` + `PortForwardManager.swift` — WKWebView + tunnels
- `WebChatView.swift` — persistent-cookie WKWebView for claude.ai / chatgpt.com
- `VaultPane.swift` + `MarkdownEditor.swift` — file tree, editor/preview, wikilinks
- `BeadsPanel.swift` + `BeadsController.swift` — `bd` JSON parse, list, graph, edits
- `LogViewer.swift` — host log source picker + `tail -F` stream + filter
- `GitDeployPanel.swift` + `GitController.swift` — per-project status, account
  mismatch check, commit/push/deploy actions
- `HostHealthPanel.swift` — reachability/agents/tunnels/git overview
- `AppSettings.swift` + `SettingsView.swift`

## Verification (end-to-end)

- **Build/run** in Xcode (or `xcodebuild`), app launches with 3 panes.
- **Terminal:** `tmux ls` on the mini shows `main`; detach + reattach is lossless.
- **Sleep test:** start a long-running command in tmux, sleep the MacBook, wake →
  command still running and the pane re-attaches automatically.
- **Chat:** send a prompt to Claude Code, see it respond in the TUI; switch to
  Codex and do the same.
- **Browser:** run a dev server on the mini bound to localhost → loads via the
  forwarded port; sleep/wake → still loads after auto-reconnect.
- **Web chat:** log into claude.ai once, quit + relaunch the app → still logged in.
- **Vault:** open a note, edit + save → change appears on the mini; have an agent
  edit a note → the pane refreshes and shows it (conflict guard fires if both edit).
- **Beads:** `bd create` from the app shows up in `bd list` on the mini and in the
  panel; an agent's `bd update` reflects in the panel on the next refresh.
- **Multi-host:** open a terminal to EC2-staging via the mini (ProxyJump) and run a
  command; forward a staging web port and load it in the Browser pane.
- **Logs:** stream a prod log file, apply a filter, confirm live tail + scrollback.
- **Git/Deploy:** a project shows correct branch/state and the *right* GitHub
  account; a deliberately mismatched remote raises the warning before push.

## Prerequisites I'll need from you during the build

- **Tooling install (confirmed, do at M0):**
  - **Install Codex CLI** on this Mac (you've used the Codex *desktop app*; the CLI
    is needed for Codex to co-develop and to be a tmux-drivable agent). Install via
    `npm i -g @openai/codex` (or Homebrew), then `codex login` against your ChatGPT
    plan. Later install it on the mini too for the in-app agent.
  - **Set up `bd` for this project.** beads was only initialized for another
    project; confirm the `bd` binary (install if missing), then `bd init` here so
    AronnaxIDE gets its own `.beads/` db.
- The mini's SSH hostname/alias (and confirmation key-based `ssh <mini>` works),
  plus the EC2/Lightsail host aliases and that the **mini can `ssh` to each**
  (ProxyJump relies on the mini's existing access).
- Confirmation that Claude Code and Codex are installed and logged in on the mini.
- The **Obsidian vault path** and the **bd repo path** on the mini, and that `bd`
  is installed there (with `--json` output available).
- The **GitHub account setup on the mini** (e.g. `github.com-work` /
  `github.com-personal` host aliases or how each repo authenticates), and for each
  project: its host, repo path, account, and deploy target.
- Per host, the **log sources** you care about (file paths / `journalctl` / `pm2` /
  `docker`).
- Optional: `fswatch` installed on the mini for instant change detection (the app
  falls back to mtime polling if it isn't).
