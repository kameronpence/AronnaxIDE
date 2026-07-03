# AronnaxIDE

A native **macOS + iOS** control surface for a headless Mac mini. The mini ("kepler")
is where the real work happens — Claude Code and Codex CLIs run there inside **tmux**,
along with dev servers — and AronnaxIDE is the window onto it from the MacBook and the
iPhone.

Surfaces (macOS): **Terminal · Chat · Browser · Obsidian vault · Beads · Logs · Git/Deploy**.

Design principles:
- **No API** — AI runs on existing subscriptions (Claude Max via Claude Code,
  ChatGPT via Codex) and the claude.ai / chatgpt.com web chats.
- **Sleep-resilient** — work lives in tmux on the mini; the app reconnects on wake.
- **Mini as hub** — AWS EC2 / Lightsail hosts are reached via ProxyJump through the
  mini. Per-project GitHub identity.

See the full plan in `docs/PLAN.md` and the live backlog in beads (`bd ready`).

## Targets

| Target        | Platform | What it is |
|---------------|----------|------------|
| `AronnaxIDE`  | macOS 14+ | The full IDE: multi-pane control surface, SSH over `/usr/bin/ssh` with ControlMaster + ProxyJump. |
| `AronnaxIOS`  | iOS 17+  | A phone companion — Terminal + a Claude/Codex switcher over a pure-Swift SSH transport ([Citadel](https://github.com/orlandos-nl/Citadel)) via Tailscale, so agents can be steered from the iPhone. |

Both drive the **same** tmux sessions on the mini (session name = agent + a stable hash
of the project dir), so the Mac and the phone attach to one live agent, not two.

## Build

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonsson/XcodeGen):

```sh
brew install xcodegen      # one-time
xcodegen generate          # writes AronnaxIDE.xcodeproj (gitignored)
open AronnaxIDE.xcodeproj   # build & run in Xcode (⌘R)
```

From the command line:

```sh
xcodegen generate
# macOS app
xcodebuild -scheme AronnaxIDE -destination 'platform=macOS' build
# iOS app (to a connected device)
xcodebuild -scheme AronnaxIOS -destination 'platform=iOS,name=<device>' build
```

Requirements: macOS 14+, Xcode 26+, Swift 6.3 toolchain.

> **Note:** the iOS target needs an `AronnaxIOS/Secrets.swift` (gitignored) that
> defines the mini's Tailscale host/user and the app's SSH key. It's intentionally
> not committed. See `AronnaxIOS/SSHTerminalSession.swift` for the expected symbols.

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
