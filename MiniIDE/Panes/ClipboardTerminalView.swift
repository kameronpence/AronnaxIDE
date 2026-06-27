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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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
            applyLightThemeIfNeeded()
            if scrollMonitor == nil {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    self?.handleScroll(event) ?? event
                }
            }
        }
    }

    private var themed = false
    /// A light color scheme (light background, dark text). The plain shell honors
    /// this; full-screen TUIs like Claude/Codex paint their own colors and may stay
    /// dark unless their own theme is set to light.
    private func applyLightThemeIfNeeded() {
        guard !themed else { return }
        themed = true
        nativeBackgroundColor = NSColor(calibratedWhite: 0.99, alpha: 1)
        nativeForegroundColor = NSColor(calibratedWhite: 0.15, alpha: 1)
        caretColor = NSColor.systemBlue
    }

    deinit {
        removeScrollMonitor()
    }

    private func removeScrollMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
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
