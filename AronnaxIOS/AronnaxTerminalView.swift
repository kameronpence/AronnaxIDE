import UIKit
import SwiftTerm

/// `TerminalView` tuned for the phone.
///
/// SwiftTerm's iOS view is a `UIScrollView`. For a plain shell (normal screen) its own
/// pan scrolls the scrollback natively. But Claude/Codex run in tmux, which uses the
/// terminal's *alternate* screen — so SwiftTerm has no scrollback to move; the history
/// lives in tmux and is reached by mouse-wheel events (tmux `mouse on` → copy-mode).
///
/// So in agent mode we don't add a competing gesture (which the scroll view's own pan
/// starves); we hook SwiftTerm's **own** pan recognizer and translate a one-finger drag
/// into wheel events sent to the PTY. Natural drag-to-scroll, no buttons.
///
/// Also: a deferred first-responder grab (avoids a launch hang) and hardware ⌘C/⌘V/⌘A.
final class AronnaxTerminalView: TerminalView {
    /// True while a tmux-backed agent (Claude/Codex) is showing: a one-finger drag emits
    /// wheel events instead of moving the (empty) native scrollback. False for the plain
    /// shell, where the drag scrolls SwiftTerm's own scrollback.
    var agentScrollEnabled = false {
        didSet {
            // Bounce guarantees the scroll view's pan engages (and thus calls our hooked
            // handler) even though the alternate screen has nothing to scroll.
            alwaysBounceVertical = agentScrollEnabled
        }
    }

    /// Sends raw bytes to the remote PTY (wired to the SSH session in `TerminalSurface`).
    var sendToRemote: (([UInt8]) -> Void)?

    private var wheelAccum: CGFloat = 0
    /// Points of vertical drag per emitted wheel step. ~1 line feels responsive on a phone.
    private let wheelStep: CGFloat = 16

    /// Hooks SwiftTerm's own scroll-view pan so a one-finger drag can drive agent scroll.
    /// Adding a *target* to the existing recognizer (rather than a new recognizer) means we
    /// never lose gesture arbitration to it — we ride along with every drag it recognizes.
    func installAronnaxGestures() {
        panGestureRecognizer.addTarget(self, action: #selector(agentScrollPan(_:)))
    }

    @objc private func agentScrollPan(_ g: UIPanGestureRecognizer) {
        guard agentScrollEnabled else { return }   // plain shell → let native scroll run
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

    /// SGR mouse-wheel event (button 64 = up, 65 = down) at the top-left cell. tmux
    /// (mouse on) enters copy-mode and scrolls its scrollback on these.
    private func sendWheel(up: Bool) {
        let seq = "\u{1b}[<\(up ? 64 : 65);1;1M"
        sendToRemote?(Array(seq.utf8))
    }

    /// Takes focus (raising the keyboard) once the view is actually in a window. Doing this
    /// off the initial `makeUIView` path avoids an intermittent main-thread hang at launch.
    private var hasTakenFocus = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !hasTakenFocus else { return }
        hasTakenFocus = true
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
