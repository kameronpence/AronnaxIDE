import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` with the standard macOS clipboard shortcuts wired in,
/// plus scroll-wheel forwarding for alt-screen apps.
///
/// **Clipboard:** SwiftTerm implements `copy(_:)`, `paste(_:)`, and `selectAll(_:)`,
/// but SwiftUI's default Edit menu doesn't reliably dispatch Cmd-C / Cmd-V / Cmd-A
/// into an embedded AppKit view, so we handle them in `performKeyEquivalent`. Ctrl-C
/// / Ctrl-V are left alone so they reach the shell/agent as control codes.
///
/// **Scroll:** SwiftTerm's `scrollWheel` scrolls its own scrollback, which is empty
/// for an app on the alternate screen (tmux, Claude/Codex), so scrolling there does
/// nothing. `scrollWheel` is `public` (not `open`) so we can't override it; instead a
/// local event monitor forwards the wheel to the app as mouse-wheel events when the
/// app has mouse reporting on, and otherwise lets SwiftTerm scroll its buffer
/// (normal screen) — never sending stray input to a shell that didn't ask for it.
final class ClipboardTerminalView: LocalProcessTerminalView {
    private var scrollMonitor: Any?
    private var hoverMonitor: Any?

    /// True when this terminal (or a descendant) holds first responder — i.e. it's
    /// the focused agent. `performKeyEquivalent` is offered to every view in the
    /// window, so without this the first terminal in the hierarchy would claim
    /// Cmd-V for both panes and paste into the wrong agent in Both view.
    private var isFocusedTerminal: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) ?? false
    }

    // MARK: - Dictation

    /// macOS Dictation queries `selectedRange()` to find where to insert text. SwiftTerm returns
    /// `{NSNotFound, 0}` ("no selection") whenever there's no *visual* selection — i.e. the normal
    /// state with just a blinking cursor — which tells Dictation there's no insertion point, so it
    /// silently refuses to start (the "Dictation won't start in this app" symptom). A terminal
    /// always has a caret, so report a valid zero-length insertion point when there's no real
    /// selection. Dictated text still routes through `insertText(_:)`, which SwiftTerm forwards to
    /// the shell/agent as input.
    override func selectedRange() -> NSRange {
        let range = super.selectedRange()
        return range.location == NSNotFound ? NSRange(location: 0, length: 0) : range
    }

    /// The in-progress dictation ("marked") text and the overlay that shows it live.
    private var markedText = ""
    private var dictationOverlay: NSTextField?

    /// SwiftTerm's `setMarkedText` is a no-op, so the terminal shows nothing while you dictate
    /// and only the committed result appears — unlike every other text field. macOS delivers the
    /// live transcription through the marked-text protocol, so we implement it: report the marked
    /// state, and draw the provisional text as an overlay at the caret. On commit, `insertText`
    /// clears the overlay and lets SwiftTerm send the final text to the shell/agent as input.
    override func hasMarkedText() -> Bool { !markedText.isEmpty }

    override func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
                           : NSRange(location: 0, length: (markedText as NSString).length)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        refreshDictationOverlay()
    }

    override func unmarkText() {
        markedText = ""
        refreshDictationOverlay()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        refreshDictationOverlay()
        super.insertText(string, replacementRange: replacementRange)   // final text → the shell
    }

    private func refreshDictationOverlay() {
        guard !markedText.isEmpty else {
            dictationOverlay?.removeFromSuperview()
            dictationOverlay = nil
            return
        }
        let field = dictationOverlay ?? {
            let f = NSTextField(labelWithString: "")
            f.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            f.textColor = NSColor.systemBlue
            f.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 0.96)
            f.drawsBackground = true
            f.isBordered = false
            f.lineBreakMode = .byCharWrapping
            f.maximumNumberOfLines = 0
            addSubview(f)
            dictationOverlay = f
            return f
        }()
        field.stringValue = markedText
        // Anchor at the caret: firstRect gives the caret in screen coords; map back to this view.
        let caretScreen = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        if let window {
            let originView = convert(window.convertPoint(fromScreen: caretScreen.origin), from: nil)
            let maxW = max(80, bounds.width - originView.x - 8)
            let size = field.sizeThatFits(NSSize(width: maxW, height: .greatestFiniteMagnitude))
            field.frame = NSRect(x: originView.x, y: originView.y,
                                 width: min(size.width, maxW), height: size.height)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the focused terminal may claim clipboard shortcuts; otherwise defer so
        // the event reaches the pane the user is actually working in.
        guard isFocusedTerminal else { return super.performKeyEquivalent(with: event) }

        // Mask to the modifiers that matter so Caps Lock (and fn / numeric pad)
        // don't break the match — macOS shortcuts ignore Caps Lock.
        let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(relevant)
        if mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "c":
                // Only claim Cmd-C when there's a selection to copy; otherwise let
                // it fall through rather than silently clearing the clipboard.
                if selectionActive {
                    copy(self)
                    return true
                }
            case "v":
                paste(self)
                return true
            case "a":
                selectAll(self)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Scroll forwarding

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeScrollMonitor()
        } else {
            applySetupIfNeeded()
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handleScroll(event) ?? event
                }
            }
            if hoverMonitor == nil {
                hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                    // Return handleHover's result directly — it returns nil to CONSUME the
                    // hover. A `?? event` fallback here would turn that consume-nil back into
                    // the event and defeat the suppression; only fall back if self is gone.
                    guard let self else { return event }
                    return self.handleHover(event)
                }
            }
        }
    }

    /// Swallow *bare* hover motion over this terminal so it never reaches SwiftTerm's
    /// `mouseMoved`. In `.anyEvent` mouse mode (which Claude/Codex request for their
    /// hover UI), `mouseMoved` reports motion to the app — and, unlike `mouseDragged`,
    /// it does NOT check `allowMouseReporting` — so just passing the pointer over a
    /// collapsed agent action expands it (no click). `.anyEvent` is the ONLY mode whose
    /// `sendMotionEvent()` is true, so gating on it suppresses exactly the hover reports
    /// and nothing else. Returning nil consumes the event before dispatch, so SwiftTerm's
    /// `mouseMoved` never runs.
    ///
    /// We deliberately let Command-held motion through: SwiftTerm's `mouseMoved` also drives
    /// Command-hover URL preview and link highlighting (the default `linkHighlightMode` is
    /// `.hoverWithModifier`, which only acts while Command is down), so preserving those means
    /// suppressing only the modifier-free hover that triggers the agent's expand-on-hover.
    /// Button *drags* fire `mouseDragged` (and clicks fire `mouseDown`/`Up`), not
    /// `.mouseMoved`, so local selection and clicks are unaffected; the plain shell
    /// (`mouseMode == .off`) is untouched entirely.
    private func handleHover(_ event: NSEvent) -> NSEvent? {
        guard event.window == window,
              terminal.mouseMode == .anyEvent,
              !event.modifierFlags.contains(.command) else { return event }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return event }
        return nil
    }

    private var configured = false
    /// One-time setup once the view has a window:
    /// - A light color scheme (light background, dark text). The plain shell honors
    ///   this; full-screen TUIs like Claude/Codex paint their own colors and may stay
    ///   dark unless their own theme is set to light.
    /// - Disable mouse *reporting* to the app. SwiftTerm's `mouseDown` sends drags to
    ///   the app (and skips local selection) whenever an app has mouse mode on — and
    ///   under tmux that's most of the time, so drag-select only ever filled tmux's
    ///   own buffer, never the system clipboard. With reporting off, drags become a
    ///   *local* SwiftTerm selection that Cmd-C copies to the clipboard — for both
    ///   Claude and Codex, even when the agent grabs the mouse. Scrolling still works
    ///   because `handleScroll` forwards the wheel directly via `terminal.sendEvent`,
    ///   which doesn't go through `allowMouseReporting`.
    private func applySetupIfNeeded() {
        guard !configured else { return }
        configured = true
        nativeBackgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1)
        nativeForegroundColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        caretColor = NSColor.systemBlue
        allowMouseReporting = false
    }

    deinit {
        removeScrollMonitor()
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
        if let hoverMonitor {
            NSEvent.removeMonitor(hoverMonitor)
            self.hoverMonitor = nil
        }
    }

    /// Returns nil to consume the event (forwarded to the app), or the event to let
    /// SwiftTerm handle it normally.
    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard event.window == window,
              event.deltaY != 0,
              terminal.mouseMode != .off else {
            return event
        }
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.contains(local) else { return event }

        let button = event.deltaY > 0 ? 64 : 65   // 64 = wheel up, 65 = wheel down
        let (col, row) = cell(for: local)
        // Cell coords cover the cell-based mouse modes; pass real (top-left-origin)
        // backing pixels too for SGR-pixel mode.
        let backing = convertToBacking(NSPoint(x: local.x, y: bounds.height - local.y))
        let pixelX = max(0, Int(backing.x))
        let pixelY = max(0, Int(backing.y))
        let ticks = max(1, min(Int(abs(event.deltaY).rounded()), 5))
        for _ in 0..<ticks {
            terminal.sendEvent(buttonFlags: button, x: col, y: row, pixelX: pixelX, pixelY: pixelY)
        }
        return nil
    }

    /// The 0-based terminal cell at a view-local point (`sendEvent` adds 1).
    private func cell(for local: NSPoint) -> (col: Int, row: Int) {
        let cols = max(terminal.cols, 1)
        let rows = max(terminal.rows, 1)
        let cellW = bounds.width / CGFloat(cols)
        let cellH = bounds.height / CGFloat(rows)
        let col = cellW > 0 ? min(max(Int(local.x / cellW), 0), cols - 1) : 0
        let row = cellH > 0 ? min(max(Int((bounds.height - local.y) / cellH), 0), rows - 1) : 0
        return (col, row)
    }
}
