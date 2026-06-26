# MiniIDE

A native macOS (SwiftUI) IDE that runs on the MacBook Pro and acts as a control
surface for a **headless Mac mini**. The mini is where the real work happens —
Claude Code and Codex CLIs run there inside **tmux**, along with dev servers — and
MiniIDE is the window onto it.

Surfaces: **Terminal · Chat · Browser · Obsidian vault · Beads · Logs · Git/Deploy**.

Design principles:
- **No API** — AI runs on existing subscriptions (Claude Max via Claude Code,
  ChatGPT via Codex) and the claude.ai / chatgpt.com web chats.
- **Sleep-resilient** — work lives in tmux on the mini; the app reconnects on wake.
- **Mini as hub** — AWS EC2 / Lightsail hosts are reached via ProxyJump through the
  mini. Per-project GitHub identity.

See the full plan in `docs/PLAN.md` and the live backlog in beads (`bd ready`).

## Build

This project's Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonsson/XcodeGen):

```sh
brew install xcodegen      # one-time
xcodegen generate          # writes MiniIDE.xcodeproj (gitignored)
open MiniIDE.xcodeproj      # build & run in Xcode (⌘R)
```

Or build from the command line:

```sh
xcodegen generate
xcodebuild -scheme MiniIDE -destination 'platform=macOS' build
```

Requirements: macOS 14+, Xcode 26+, Swift 6.3 toolchain.

## Issue tracking (beads)

Development is tracked in [beads](https://github.com/gastownhall/beads) — the
`.beads/` database is committed and syncs through git, so Claude Code and Codex
share one backlog.

```sh
bd ready          # what's unblocked to work on
bd list           # all issues
bd show IDE-48l   # an issue's details
```

Milestones are epics (`M0`–`M12`); claim work by marking an issue `in_progress`.
