import UIKit
import SwiftTerm

/// `TerminalView` tuned for the phone.
///
/// SwiftTerm's iOS view is a `UIScrollView`, so the plain shell already scrolls its
/// scrollback with a one-finger drag. But two things it does NOT do out of the box:
///
///  1. **Selection / copy** is blocked while `allowMouseReporting` is on (the default) —
///     pans get reported to the app instead of selecting text. The macOS app turns it
///     off for the same reason; we do too (see `TerminalSurface`).
///  2. **Agent scroll.** Claude/Codex run full-screen inside tmux, so there's no
///     scroll-view scrollback to drag — their history lives in tmux/the TUI. SwiftTerm's
///     iOS pan only ever emits click-drags, never wheel events, so nothing scrolls.
///     We add a **two-finger swipe** that emits mouse-wheel escape sequences to the PTY;
///     tmux (mouse on) and Claude both scroll on those.
///
/// Plus hardware ⌘C / ⌘V / ⌘A for when a keyboard is attached.
final class AronnaxTerminalView: TerminalView {
    /// True while a full-screen agent is showing, so two-finger swipes become wheel
    /// events. False for the plain shell, where the native scroll view handles scrollback.
    var wheelScrollEnabled = false

    /// Sends raw bytes to the remote PTY (wired to the SSH session in `TerminalSurface`).
    var sendToRemote: (([UInt8]) -> Void)?

    private var wheelAccum: CGFloat = 0
    /// Points of vertical travel per emitted wheel step. ~2 lines feels right on a phone.
    private let wheelStep: CGFloat = 22

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

    /// Adds the two-finger scroll gesture. One-finger pans are left to the scroll view
    /// (shell scrollback) and to SwiftTerm's own selection handling.
    func installAronnaxGestures() {
        let two = UIPanGestureRecognizer(target: self, action: #selector(twoFingerPan(_:)))
        two.minimumNumberOfTouches = 2
        two.maximumNumberOfTouches = 2
        addGestureRecognizer(two)
    }

    @objc private func twoFingerPan(_ g: UIPanGestureRecognizer) {
        guard wheelScrollEnabled else { return }
        switch g.state {
        case .began:
            wheelAccum = 0
        case .changed:
            wheelAccum += g.translation(in: self).y
            g.setTranslation(.zero, in: self)
            while abs(wheelAccum) >= wheelStep {
                // Finger down (dy > 0) reveals older content → wheel up, matching natural scroll.
                if wheelAccum > 0 { sendWheel(up: true);  wheelAccum -= wheelStep }
                else              { sendWheel(up: false); wheelAccum += wheelStep }
            }
        default:
            break
        }
    }

    /// SGR mouse-wheel event (button 64 = up, 65 = down) at the top-left cell. Modern
    /// tmux (mouse on) and Claude's TUI both request SGR mouse mode and scroll on these.
    private func sendWheel(up: Bool) {
        let seq = "\u{1b}[<\(up ? 64 : 65);1;1M"
        sendToRemote?(Array(seq.utf8))
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copy(_:))),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:))),
            UIKeyCommand(input: "a", modifierFlags: .command, action: #selector(selectAll(_:))),
        ]
    }
}
