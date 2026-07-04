# Editing AronnaxIDE *with* AronnaxIDE

You don't need Claude Desktop to work on this app. AronnaxIDE can drive Claude Code (and
Codex) running on kepler, in the AronnaxIDE project itself — and that agent already has
full project context because it auto-loads `CLAUDE.md` from the project folder.

This is the dogfooding loop: **edit on kepler through the app → build/run on the Mac.**

## The mental model (important)

- **kepler** holds the source and runs the agents. When you use the Coding pane, Claude
  Code / Codex are editing the copy at
  `/Users/kepler/Documents/AI_OS/Projects/AronnaxIDE` — *not* anything on the Mac.
- **The Mac** is where you *build and run* the app, because AronnaxIDE is a Mac app that
  runs on your MacBook. You never build it on kepler.
- The two stay in sync through GitHub: the agent pushes from kepler, you pull on the Mac.

## Make a change

1. Open **AronnaxIDE** on your MacBook.
2. Sidebar → **Working on: kepler**, then select the **AronnaxIDE** project.
3. Open the **Coding** pane and pick **Claude** (or **Codex**). It attaches to that agent
   running in the AronnaxIDE folder on kepler. Claude Code reads `CLAUDE.md` on start, so
   it already knows the architecture and the build workflow.
4. Tell it what you want changed. It edits the files on kepler, and — following the
   session rules in `CLAUDE.md` — **commits and pushes** when done.

## See / build the change on the Mac

The agent's edits are on kepler. To get them into the app you run:

```bash
cd "/Users/kameron/Documents/Coding Projects/IDE"
git pull            # grab what the agent pushed from kepler
xcodegen generate   # only needed if files were added/removed
```

Then in **Xcode-beta** on the Mac: scheme **AronnaxIDE**, destination **My Mac**, **⌘R**.

> ⌘R runs a fresh *debug* build in a separate location — it does **not** update the app
> in `/Applications`. That's normal. Use it to try changes fast.

## Ship it to your installed app

When you want the change in the app you actually launch (`/Applications/AronnaxIDE.app`):

```bash
cd "/Users/kameron/Documents/Coding Projects/IDE"
git pull && xcodegen generate
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project AronnaxIDE.xcodeproj -scheme AronnaxIDE -configuration Release \
  -derivedDataPath /tmp/aronnax-rel build
# quit the running app first, then replace it:
osascript -e 'quit app "AronnaxIDE"'
ditto /tmp/aronnax-rel/Build/Products/Release/AronnaxIDE.app /Applications/AronnaxIDE.app
open /Applications/AronnaxIDE.app
```

## Notes

- If ⌘R just **error-beeps**: there's no `.xcodeproj` — run `xcodegen generate` first.
- If a build fails with **`cannot execute tool 'metal'`**: run once —
  `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain`.
- You're editing the app *with* the app: if a change breaks the build, the copy you're
  currently running keeps working — just fix and rebuild.
- The **iOS** app (`AronnaxIOS`) builds the same way but needs your iPhone plugged into
  the Mac, and an `AronnaxIOS/Secrets.swift` (gitignored) that already exists locally.
