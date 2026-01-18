import Foundation
import AppKit
import CoreGraphics

/// Result of a text insertion attempt
enum TextInsertionResult {
    case success              // Auto-paste succeeded
    case copiedOnly           // Text copied to clipboard but auto-paste failed
    case failed               // Complete failure (couldn't even copy)

    var didCopyToClipboard: Bool {
        switch self {
        case .success, .copiedOnly: return true
        case .failed: return false
        }
    }

    var didAutoPaste: Bool {
        switch self {
        case .success: return true
        case .copiedOnly, .failed: return false
        }
    }
}

/// Service for inserting text into focused input fields system-wide
/// Uses clipboard + multiple paste methods for maximum compatibility
/// Text is ALWAYS copied to clipboard, so user can manually paste if auto-paste fails
final class TextInsertionService {
    static let shared = TextInsertionService()

    private init() {}

    // MARK: - Public Interface

    /// Inserts text into the currently focused input field
    /// Text is ALWAYS copied to clipboard first, then paste is attempted via multiple methods
    /// If auto-paste fails, user can still paste manually
    /// - Parameter text: The text to insert
    /// - Returns: Result indicating success level (success, copiedOnly, or failed)
    func insertText(_ text: String) async -> TextInsertionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return .failed
        }

        return await pasteText(trimmedText)
    }

    /// Checks if Accessibility permission is granted (required for auto-paste)
    func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    // MARK: - Private Methods

    /// Copies text to clipboard and attempts auto-paste via multiple methods
    /// Tries CGEvent first, then AppleScript as fallback
    private func pasteText(_ text: String) async -> TextInsertionResult {
        // Copy to clipboard FIRST - this always succeeds and serves as fallback
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return .failed
        }

        // Check Accessibility permission before attempting auto-paste
        guard hasAccessibilityPermission() else {
            return .copiedOnly
        }

        // Small delay for clipboard to settle
        try? await Task.sleep(for: .milliseconds(50))

        // Try CGEvent method first (fastest, works in debug builds)
        if simulatePasteWithCGEvent() {
            // Give it time to process
            try? await Task.sleep(for: .milliseconds(100))
            return .success
        }

        // Fallback to AppleScript method (may work better with Hardened Runtime)
        if await simulatePasteWithAppleScript() {
            return .success
        }

        // Auto-paste failed, but text is in clipboard
        return .copiedOnly
    }

    /// Simulates Cmd+V keystroke using CGEvent
    /// Returns true if events were posted (doesn't guarantee they were received)
    private func simulatePasteWithCGEvent() -> Bool {
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

    /// Simulates Cmd+V using AppleScript via System Events
    /// This method sometimes works better with Hardened Runtime
    private func simulatePasteWithAppleScript() async -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                if let scriptObject = NSAppleScript(source: script) {
                    scriptObject.executeAndReturnError(&error)

                    if error == nil {
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(returning: false)
                    }
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
