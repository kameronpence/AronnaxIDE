# Agent + Obsidian Memory System — Setup Summary

> Hand this to Claude in a new window before the token-reduction work.
> Source of truth is the live vault on **kepler** at `~/Documents/Projects/AI_OS/`.
> Design is based on: https://www.mandalivia.com/obsidian/your-obsidian-vault-is-already-an-agent-memory-system/

## The idea
The Obsidian vault **`/Users/kepler/Documents/Projects/AI_OS/`** on the mini IS the
shared memory/brain for Kameron's AI agents (Claude Code + Codex). The agents and
Kameron read/write the **same files**. The vault notes are the source of truth for
"Kameron and his world"; the code in each project is the source of truth for that
code. When notes and code disagree, the agent asks — never guesses.

Mechanism (straight from the article): plain markdown + Obsidian **`[[wikilinks]]`**
form a load-on-demand memory graph. Agents read a small orientation file, then follow
links to pull only the context they need — instead of dumping everything into the
prompt. That link-following / progressive disclosure is the token-saving lever.

## Structure (vault root)
```
AI_OS/
  CLAUDE.md            # orientation for Claude Code  → "read these in order"
  AGENTS.md            # orientation for Codex (verifier role) → same list
  CTX-aboutme.md       # who Kameron is + communication rules (ADHD: one thing,
                       #   short, don't repeat, don't talk down; breathing exercise
                       #   when he's frustrated)
  CTX-work.md          # his jobs: day job, Georgia TSA, his own products
  CTX-project-index.md # every project: path, GitHub identity it pushes under,
                       #   per-project CLAUDE.md/AGENTS.md
  CTX-systems.md       # the fleet, kepler, Docker/colima, secrets, workflow rules
  CTX-now.md           # current focus + deadlines
  .claude/             # Claude Code config for the vault
  .obsidian/           # Obsidian config
  mygatsa-mobile/      # per-project subfolders, each with its own
  myportfoliosite/     #   CLAUDE.md + AGENTS.md + .beads + code
  relayptc/
```

## How the two orientation files work
- **`CLAUDE.md`** and **`AGENTS.md`** are near-identical "read this first" files. They
  tell each agent to load the CTX files **in order** (aboutme → work → project-index →
  systems → now) and restate the non-negotiables.
- `CLAUDE.md` uses `[[CTX-aboutme]]` wikilinks; `AGENTS.md` uses plain `CTX-aboutme.md`
  references (Codex isn't an Obsidian client).
- **Roles:** "Claude builds, Codex verifies." Codex runs `codex review --uncommitted`
  per beads task; trivial findings fixed inline, substantive ones filed as beads.

## The CTX files (what each holds)
- **CTX-aboutme** — identity + the (non-optional) communication rules. ADHD: one thing
  at a time, short replies, never make him repeat, don't talk down; if he's cursing,
  stop and run a breathing exercise. Also: M.Ed. Instructional Tech, one semester left.
- **CTX-work** — day job, Georgia TSA (GATSA), personal products.
- **CTX-project-index** — every project, where it lives, and **per-repo GitHub
  identity**: each repo's `origin` embeds the account
  (`https://<account>@github.com/<owner>/<repo>.git`) and `gh` is the credential
  helper, so `git push` uses the right account automatically (personal `kameronpence`
  vs `GATSA` org) — no `gh auth switch`.
- **CTX-systems** — the fleet (MacBook = workstation; **kepler** = always-on hub with
  everything; AWS EC2 = GATSA staging/prod; Lightsail = PBISario; AWS reached via
  kepler ProxyJump). Docker = **colima**, on-demand, build images inside the VM.
  Workflow rules: feature = branch, rollback-able, **CodeRabbit (`cr`) on every
  commit**, Claude builds + Codex verifies, shared `.beads` per project, any Claude
  login works any project.
- **CTX-now** — top focus (was: building MiniIDE, now done), hard deadline
  (mygatsa-mobile due **July 31**), in-flight (PBISario, myGATSA rewrite, relayptc,
  myportfoliosite).

## Projects (from CTX-project-index)
- **Personal (push as `kameronpence`):** MiniIDE (`~/Documents/Coding Projects/IDE`,
  stays on MacBook), PBISario (Lightsail), RelayPTC.com (kepler), myportfoliosite (kepler).
- **GATSA / work (push as `GATSA`):** mygatsa-mobile (kepler, iOS+Android conf app),
  my.gatsa.org / myGATSA rewrite (EC2), gatsa.org (EC2).

## Notes / open threads
- Frontmatter on CTX files: `title:` + `last-reviewed:` date.
- `openclaw + ClawController` (automated/scheduled work) is **temporarily removed**
  (got too complex); to be reinstalled. Tailnet HTTPS dashboard config exists.
- The fleet workflow names **CodeRabbit** as the commit-review tool *and* Codex as
  verifier — slightly different from the IDE repo, which leaned on Codex alone.

## THE TASK (next session): token reduction
Optimize this vault so the agents spend fewer tokens loading memory. Likely levers:
tighten/split the CTX files, lean harder on load-on-demand wikilinks (don't front-load
everything), trim the always-read orientation files, add indexes/MOCs so agents fetch
only what a task needs. **Kameron will provide additional website URLs** to inform the
approach — read those first, then propose concrete changes to the CTX structure.
