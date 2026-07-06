import UIKit
import SwiftTerm

/// `TerminalView` tuned for the phone.
///
/// SwiftTerm's iOS view is a `UIScrollView`. We leave its native pans (selection +
/// scrollback) intact and do NOT try to translate a drag into scrolling: claude/codex run
/// in tmux, whose alternate screen leaves SwiftTerm nothing to scroll, and a custom pan
/// only loses a fight with the scroll view's own gesture. Agent scrollback is driven
/// instead by the on-screen scroll buttons (see `ContentView` / `SSHTerminalSession.scrollAgent`).
///
/// This subclass only adds: a deferred first-responder grab (avoids a launch hang) and
/// hardware ⌘C / ⌘V / ⌘A for when a keyboard is attached.
final class AronnaxTerminalView: TerminalView {
    /// Takes focus (raising the keyboard + key bar) once the view is actually in a window.
    /// Doing this off the initial `makeUIView` path avoids an intermittent main-thread hang
    /// at launch (blank screen) caused by laying the keyboard out before the view is ready.
    private var hasTakenFocus = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasTakenFocus else { return }
        hasTakenFocus = true
        // Raise the keyboard shortly AFTER the first frame is on screen. Immediately (or in
        // makeUIView) it wedges the launch → blank screen; a brief beat lets the UI draw
        // first, then the keyboard + key bar come up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.window != nil else { return }
            _ = self.becomeFirstResponder()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:))),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))),
            UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:))),
        ]
    }
}
