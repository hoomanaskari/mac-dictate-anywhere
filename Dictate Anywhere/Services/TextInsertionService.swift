import Foundation
import AppKit
import CoreGraphics

/// Service for inserting text into focused input fields system-wide
/// Uses clipboard + CGEvent keyboard simulation (Cmd+V) for maximum compatibility
/// Text is ALWAYS copied to clipboard, so user can manually paste if auto-paste fails
final class TextInsertionService {
    static let shared = TextInsertionService()

    private init() {}

    // MARK: - Public Interface

    /// Inserts text into the currently focused input field
    /// Text is ALWAYS copied to clipboard first, then Cmd+V is simulated
    /// If auto-paste fails, user can still paste manually
    /// - Parameter text: The text to insert
    /// - Returns: True if text was copied to clipboard (paste may or may not succeed in target app)
    @discardableResult
    func insertText(_ text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return false
        }

        return await pasteText(trimmedText)
    }

    // MARK: - Private Methods

    /// Copies text to clipboard and simulates Cmd+V paste
    /// Clipboard is ALWAYS set - paste simulation may not work in all apps
    private func pasteText(_ text: String) async -> Bool {
        // Copy to clipboard FIRST - this always succeeds and serves as fallback
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return false
        }

        // Small delay for clipboard to settle
        try? await Task.sleep(for: .milliseconds(50))

        // Simulate Cmd+V
        simulatePaste()

        return true
    }

    /// Simulates Cmd+V keystroke using CGEvent
    private func simulatePaste() {
        let vKeyCode: CGKeyCode = 9  // V key

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
