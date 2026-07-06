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
///  2. **Agent scroll.** Claude/Codex run inside tmux, which puts SwiftTerm's outer
///     terminal into its alternate screen — so there's no scroll-view scrollback to drag;
///     the history lives in tmux's scrollback. A wheel-up event (with tmux `mouse on`)
///     makes tmux enter copy-mode and scroll that history. SwiftTerm's own pans never emit
///     wheel events, so in agent mode we take over a **one-finger drag** and translate it
///     into mouse-wheel escape sequences, suspending SwiftTerm's selection / scroll pans
///     for the duration so the drag scrolls instead of selecting.
///
/// Plus hardware ⌘C / ⌘V / ⌘A for when a keyboard is attached.
final class AronnaxTerminalView: TerminalView {
    /// Sends raw bytes to the remote PTY (wired to the SSH session in `TerminalSurface`).
    var sendToRemote: (([UInt8]) -> Void)?

    /// Our one-finger scroll gesture. Enabled only in agent (tmux) mode.
    private var scrollPan: UIPanGestureRecognizer?
    /// SwiftTerm's own pan recognizers (selection + the scroll view's scroll) that we
    /// disable while agent-scroll is active, so we can restore them for the plain shell.
    private var suspendedPans: [UIPanGestureRecognizer] = []

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

    /// Installs the one-finger agent-scroll gesture, disabled until an agent target is
    /// selected (see `setAgentScroll`). In the plain shell it stays off so SwiftTerm's
    /// native scroll/selection pans keep working.
    func installAronnaxGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(scrollPanHandler(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.isEnabled = false
        addGestureRecognizer(pan)
        scrollPan = pan
    }

    /// Toggle agent scroll. On: a one-finger drag emits mouse-wheel events (tmux scrolls
    /// its copy-mode history on those), and SwiftTerm's own selection / scroll pans are
    /// suspended so the drag scrolls instead of selecting or fighting the scroll view.
    /// Off: restore the suspended pans for the plain shell's native scrollback + selection.
    func setAgentScroll(_ on: Bool) {
        guard let scrollPan else { return }
        scrollPan.isEnabled = on
        if on {
            // Already suspended (e.g. switching claude → codex) — don't re-capture, or the
            // now-disabled originals would be lost and never restored.
            guard suspendedPans.isEmpty else { return }
            suspendedPans = (gestureRecognizers ?? [])
                .compactMap { $0 as? UIPanGestureRecognizer }
                .filter { $0 !== scrollPan && $0.isEnabled }
            suspendedPans.forEach { $0.isEnabled = false }
        } else {
            suspendedPans.forEach { $0.isEnabled = true }
            suspendedPans = []
        }
    }

    @objc private func scrollPanHandler(_ g: UIPanGestureRecognizer) {
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

extension AronnaxTerminalView: UIGestureRecognizerDelegate {
    /// Let our scroll pan coexist with SwiftTerm's remaining recognizers (taps, long-press)
    /// rather than being starved by them.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
