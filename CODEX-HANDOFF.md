# Codex Handoff — Add Server wizard hangs on the vault clone (bead IDE-07d)

You (Codex) are taking over this fix. Read this whole file, then work it. Claude ran the
diagnosis and committed a candidate fix on a branch; your job is to confirm the root cause on
the real box and finish it.

## The bug
In AronnaxIDE (macOS), **Add Server → step 5 "Clone the vault + memory rules" hangs forever**
(spinner, no error) when adding **mygatsa-production**. Adding **mygatsa-staging** works fine.

> Terminology: the GATSA servers are **mygatsa-staging**, **mygatsa-production**, **gatsa-web**.
> Use these names with Kam (kepler's `~/.ssh/config` still has old `gatsa-prod`/`production`
> aliases — mygatsa-production is the box at **3.208.59.162**).

## Diagnosis (evidence gathered)
- The vault repo `git@github-vault:kameronpence/ai-os-vault.git` is **tiny** — 258 KB on GitHub,
  2.9 MB `.git`. So the hang is NOT clone size.
- Step 4 (`git ls-remote` over the same `github-vault` path) **must have passed** to reach step 5,
  so the deploy key + GitHub SSH handshake + basic outbound to github work on the box.
- stdin-over-SSH, `python3`, and `git` all work fine on a comparable box.
- Conclusion: the **bulk `git-upload-pack` transfer stalls** on mygatsa-production (handshake OK,
  data transfer hangs) and onboarding had **nothing to time it out** → infinite spin. Likely a
  box-side network issue (MTU/MSS, security group) specific to production.

## Candidate fix ALREADY on branch `fix/onboarding-clone-hang` (commit 93ee85d)
File: `AronnaxIDE/Services/ServerOnboarding.swift` — Codex-reviewed clean, builds clean.
1. `gitEnv`: all onboarding git runs with `GIT_TERMINAL_PROMPT=0` + `GIT_SSH_COMMAND` that adds
   `BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3`, so a
   stalled transfer aborts in ~30s and no prompt can block a headless step.
2. `runStep(...)`: client-side watchdog that terminates the ssh process if a step exceeds its
   timeout → the wizard shows a clear failure + Retry instead of spinning. Applied to the clone,
   the ls-remote verify, the memory-rules write, and the finish verify.

## Your TODO
1. **Confirm the root cause on mygatsa-production (3.208.59.162).** From kepler:
   ```
   ssh root@3.208.59.162 'cd /tmp && rm -rf vtest && \
     echo "== no-keepalive (reproduce hang), cap 45s =="; \
     start=$(date +%s); timeout 45 git clone -q git@github-vault:kameronpence/ai-os-vault.git vtest; \
     echo "exit=$? in $(( $(date +%s)-start ))s"; rm -rf vtest; \
     echo "== WITH keepalive fix, cap 45s =="; start=$(date +%s); \
     GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3" \
     timeout 45 git clone -q git@github-vault:kameronpence/ai-os-vault.git vtest; \
     echo "exit=$? in $(( $(date +%s)-start ))s"; rm -rf vtest'
   ```
   - `exit=124` on the first = stall confirmed. Clone to `/tmp` + `rm` = no footprint.
2. **If it's a hard box-side stall** (keepalive aborts but clone still never completes), the real
   fix is box-side: try an MSS/MTU clamp on mygatsa-production, and/or add an **HTTPS clone
   fallback** in `cloneVault()` (clone `https://github.com/kameronpence/ai-os-vault.git` when the
   SSH clone fails — HTTPS may dodge the SSH-path stall). Implement whichever actually works.
3. **Verify** the branch fix compiles and behaves:
   `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project AronnaxIDE.xcodeproj -scheme AronnaxIDE -destination 'platform=macOS' build`
4. This is a **macOS** app — it ships when the fix lands on `main` and Kam runs `~/bin/aronnax-ship`
   on his MacBook. You commit + (with Kam's ok) push/merge; **do not close IDE-07d until Kam
   confirms Add Server works on-device.**

## SECOND SYMPTOM (same class): step 6 "Install dev tools" HANGS
Onboarding step 6 (`installTools`/`checkTools` in `ServerOnboarding.swift`) **hangs forever** on
mygatsa-production — same root class as the clone: those `runShell` calls are NOT wrapped in the
`runStep` watchdog and are NOT bounded, so they spin with no timeout. Likely concrete cause: on a
fresh box `apt-get`/`dpkg` **blocks on a lock** held by unattended-upgrades/cloud-init, or hits a
slow/unreachable package mirror — neither of which the code times out. The `curl | bash` CLI
installers can also block on a prompt.

Fix direction:
- Route step-6 commands through `runStep` (or an equivalent bounded call) so they can't spin —
  surface a clear failure + Retry instead of an endless spinner.
- Make apt non-interactive + lock-tolerant: `DEBIAN_FRONTEND=noninteractive`, and
  `apt-get -o DPkg::Lock::Timeout=60 …` so it fails instead of waiting on a held lock. Give
  `apt-get update`/install a sensible timeout.
- Stop swallowing the package-manager error (`_ = try?`) — report what actually failed.
- zsh matters because the panes launch via `exec zsh -lc '…'` (`SSHManager.loginShellArguments`);
  if zsh genuinely can't be installed on a box, consider a **bash fallback** so the box is still
  usable. Diagnose first on 3.208.59.162 (`cat /etc/os-release`, which pkg mgr, is a lock held).

## Rules
- Call him **Kam**. One thing at a time. Use mygatsa-* terminology.
- `xcodegen generate` after any branch switch (the `.xcodeproj` is gitignored).
- Beads: `bd show IDE-07d` for the tracked task; update it as you go.
