import SwiftUI

/// Splits a hotkey display name (e.g. "L⌃L⌥A" or "fn⌘Space") into
/// individual keycap tokens for rendering as `DSKeycap`s.
enum HotkeyKeycapTokenizer {
    private static let modifierSymbols: Set<Character> = ["\u{2303}", "\u{2325}", "\u{21E7}", "\u{2318}"]

    static func tokens(from displayName: String) -> [String] {
        guard !displayName.isEmpty else { return [] }

        var tokens: [String] = []
        var remainder = Substring(displayName)

        while !remainder.isEmpty {
            if remainder.hasPrefix("fn") {
                tokens.append("fn")
                remainder = remainder.dropFirst(2)
                continue
            }
            let first = remainder.first!
            if (first == "L" || first == "R"),
               remainder.count >= 2,
               modifierSymbols.contains(remainder[remainder.index(after: remainder.startIndex)]) {
                tokens.append("\(first) \(remainder[remainder.index(after: remainder.startIndex)])")
                remainder = remainder.dropFirst(2)
                continue
            }
            if modifierSymbols.contains(first) {
                tokens.append(String(first))
                remainder = remainder.dropFirst()
                continue
            }
            // Remainder is the key name (letter, "Space", "F5", …).
            tokens.append(String(remainder))
            break
        }

        return tokens
    }
}

/// Molecule: renders a hotkey display name as a row of keycaps.
struct DSKeycapGroup: View {
    let displayName: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(HotkeyKeycapTokenizer.tokens(from: displayName).enumerated()), id: \.offset) { _, token in
                DSKeycap(text: token)
            }
        }
    }
}
