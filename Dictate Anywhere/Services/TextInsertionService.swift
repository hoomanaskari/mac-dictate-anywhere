import Foundation
import AppKit
import CoreGraphics

/// Service for inserting text into focused input fields system-wide
/// Uses clipboard + CGEvent keyboard simulation (Cmd+V) for maximum compatibility
/// Falls back to clipboard-only when no focused input is detected
final class TextInsertionService {
    static let shared = TextInsertionService()

    private init() {}

    // MARK: - Public Interface

    /// Inserts text into the currently focused input field
    /// Always attempts to paste since user explicitly triggered dictation
    /// - Parameter text: The text to insert
    /// - Returns: True if paste was attempted, false if text was empty
    @discardableResult
    func insertText(_ text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return false
        }

        // Always attempt to paste - user explicitly triggered dictation
        // so they expect text to be inserted wherever their cursor is
        return await pasteText(trimmedText)
    }

    // MARK: - Private Methods

    /// Copies text to clipboard and simulates Cmd+V paste
    private func pasteText(_ text: String) async -> Bool {
        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return false
        }

        // Small delay for clipboard to settle
        try? await Task.sleep(for: .milliseconds(50))

        // Simulate Cmd+V
        let success = simulatePaste()

        if success {
            NSSound(named: "Pop")?.play()
        }

        return success
    }

    /// Simulates Cmd+V keystroke using CGEvent
    private func simulatePaste() -> Bool {
        let vKeyCode: CGKeyCode = 9  // V key

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        return true
    }
}
