import AppKit
import SwiftTerm

/// `LocalProcessTerminalView` with the standard macOS clipboard shortcuts wired in.
///
/// SwiftTerm already implements `copy(_:)`, `paste(_:)`, and `selectAll(_:)`, but
/// SwiftUI's default Edit menu doesn't reliably dispatch Cmd-C / Cmd-V / Cmd-A into
/// an embedded AppKit view, so the shortcuts feel "dead" in the terminal. Handling
/// them in `performKeyEquivalent` guarantees they work whenever the terminal has
/// focus.
///
/// Only the Command-key combos are intercepted — Ctrl-C / Ctrl-V are left alone so
/// they reach the shell/agent as the control codes the user means (interrupt, etc.).
final class ClipboardTerminalView: LocalProcessTerminalView {
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
}
