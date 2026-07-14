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

    private var wheelAccum: CGFloat = 0
    /// Points of vertical drag per emitted wheel step. ~1 line feels responsive on a phone.
    private let wheelStep: CGFloat = 16

    /// Adds a one-finger pan for agent scroll. It's our OWN recognizer with a delegate that
    /// allows simultaneous recognition, so SwiftTerm's scroll-view pan can't starve it
    /// (riding the scroll view's own pan via addTarget never fired — verified p=0 on device).
    func installAronnaxGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(agentScrollPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
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

    /// Wheel up (64) / down (65) via SwiftTerm's own `sendEvent`, exactly like the macOS
    /// app's ClipboardTerminalView — it encodes the event in whatever mouse mode tmux
    /// negotiated and routes it through the terminal's send delegate to the PTY. (Sending a
    /// hardcoded SGR escape string assumed one encoding and is why raw bytes didn't scroll.)
    private func sendWheel(up: Bool) {
        getTerminal().sendEvent(buttonFlags: up ? 64 : 65, x: 0, y: 0)
    }

    /// Whether this pane is the focused leaf. With many terminals on screen, only the focused
    /// one may hold the keyboard; `TerminalSurface` sets this and drives first-responder on
    /// focus changes. The initial grab (below) fires only for the pane focused at launch.
    var wantsFocus = false

    /// Takes focus (raising the keyboard) once the view is actually in a window — but only if
    /// this is the focused leaf. Deferring off the initial `makeUIView` path avoids an
    /// intermittent main-thread hang at launch.
    private var hasTakenFocus = false
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, wantsFocus, !hasTakenFocus else { return }
        hasTakenFocus = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.window != nil, self.wantsFocus else { return }
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

extension AronnaxTerminalView: UIGestureRecognizerDelegate {
    /// Recognize our scroll pan alongside SwiftTerm's own recognizers instead of being
    /// starved by the scroll view's pan.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
