# MiniIDE development workflow — Claude creates, Codex verifies

Two agents build MiniIDE together, coordinating through **beads** (`.beads/`,
synced via git) and the shared backlog (`bd ready`, milestones `M0`–`M12`).

- **Claude Code** — implements tasks (writes the code).
- **Codex** — the **verifier**: reviews everything Claude creates for bugs,
  correctness issues, and slop. They run together and support each other.

## The per-task loop

Each beads task goes through this cycle:

1. **Claim.** Claude marks the task `in_progress` (`bd update <id> --status in_progress`).
2. **Implement.** Claude writes the code for that task only (keep diffs scoped).
3. **Verify.** Claude runs Codex on the task's working-tree diff:
   ```sh
   codex review --uncommitted --title "<task-id>: <task title>" \
     "Review for correctness bugs, race conditions, Swift 6 concurrency issues,
      resource leaks, error handling, and slop. Be adversarial. This is task
      <task-id>: <one-line task intent>."
   ```
   (Use `--base main` or `--commit <sha>` to scope differently.)
4. **Triage findings** (tiered, to avoid bookkeeping noise):
   - **Trivial** (typos, obvious small bugs, slop) → fix inline in the same task.
   - **Substantive** (real bugs, design concerns, deferred or disputed items) →
     file a linked beads issue:
     `bd create "<finding>" -t bug --deps discovered-from:<task-id> -d "<detail + Codex's reasoning>"`
   - **Always** record a one-line review verdict on the task:
     `bd update <task-id> --append-notes "Codex review: <verdict + what it caught>"`
5. **Resolve.** Claude fixes findings and re-runs Codex until clean. On a genuine
   disagreement, Claude resolves it and **logs the rationale** in the issue/notes
   (only escalates to the user if truly stuck).
6. **Close & commit.** Build green (`xcodebuild ... build`), then
   `bd update <task-id> --status closed` and commit (beads exports on commit).

## Principles

- **Scope diffs to one task** so Codex reviews a tight, reviewable change.
- **No API** anywhere — Codex uses the ChatGPT subscription; Claude Code uses
  Claude Max. See `docs/PLAN.md`.
- **Beads is the source of truth** for what's done, what's under review, and what
  Codex found. A reader should be able to reconstruct the verification history.
