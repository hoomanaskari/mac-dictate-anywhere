import Foundation
import AppKit

final class ClipboardManager {
    static let shared = ClipboardManager()

    private init() {}

    /// Copies text to the system clipboard
    /// - Parameter text: The text to copy
    /// - Returns: True if the copy was successful
    @discardableResult
    func copyToClipboard(_ text: String) -> Bool {
        // Skip empty or whitespace-only text
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let success = pasteboard.setString(text, forType: .string)

        if success {
            playFeedbackSound()
        }

        return success
    }

    /// Plays a subtle sound to indicate successful copy
    private func playFeedbackSound() {
        // Use system sound for feedback
        NSSound(named: "Pop")?.play()
    }

    /// Clears the clipboard
    func clearClipboard() {
        NSPasteboard.general.clearContents()
    }

    /// Gets the current clipboard text
    func getClipboardText() -> String? {
        return NSPasteboard.general.string(forType: .string)
    }
}
