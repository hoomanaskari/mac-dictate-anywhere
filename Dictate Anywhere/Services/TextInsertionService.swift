import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// Service for inserting text into focused input fields system-wide
/// Uses clipboard + CGEvent keyboard simulation (Cmd+V) for maximum compatibility
/// Falls back to clipboard-only when no focused input is detected
final class TextInsertionService {
    static let shared = TextInsertionService()

    private init() {}

    // MARK: - Public Interface

    /// Inserts text into the currently focused input field
    /// If no focused input is detected, copies to clipboard as fallback
    /// - Parameter text: The text to insert
    /// - Returns: True if text was pasted into a focused input, false if copied to clipboard only
    @discardableResult
    func insertText(_ text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return false
        }

        // Check if there's a focused text input
        let hasFocusedInput = checkForFocusedTextInput()

        if hasFocusedInput {
            // Paste into focused input
            return await pasteText(text)
        } else {
            // Fallback: copy to clipboard only
            return copyToClipboard(text)
        }
    }

    // MARK: - Private Methods

    /// Checks if there's a focused text input element using Accessibility API
    private func checkForFocusedTextInput() -> Bool {
        // Get the frontmost application
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the focused UI element
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            return false
        }

        // Check the role of the focused element
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element as! AXUIElement,
            kAXRoleAttribute as CFString,
            &role
        )

        if let roleString = role as? String {
            // Common text input roles
            let textInputRoles = [
                "AXTextField",
                "AXTextArea",
                "AXComboBox",
                "AXSearchField",
                "AXWebArea"  // Web content areas (browser inputs)
            ]
            return textInputRoles.contains(roleString)
        }

        return false
    }

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

    /// Copies text to clipboard only (fallback when no focused input)
    private func copyToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(text, forType: .string)

        if success {
            NSSound(named: "Pop")?.play()
        }

        return false  // Return false to indicate it was only copied, not pasted
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
