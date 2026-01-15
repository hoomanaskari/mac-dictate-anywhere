import Foundation
import AppKit

@Observable
final class SettingsManager {
    // MARK: - Singleton

    static let shared = SettingsManager()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let isFnKeyEnabled = "isFnKeyEnabled"
        static let isCustomShortcutEnabled = "isCustomShortcutEnabled"
        static let customShortcutKeyCode = "customShortcutKeyCode"
        static let customShortcutModifiers = "customShortcutModifiers"
        static let customShortcutDisplayName = "customShortcutDisplayName"
        static let isModifierOnlyShortcut = "isModifierOnlyShortcut"
    }

    // MARK: - Fn Key Settings

    var isFnKeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isFnKeyEnabled, forKey: Keys.isFnKeyEnabled)
        }
    }

    // MARK: - Custom Shortcut Settings

    var isCustomShortcutEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCustomShortcutEnabled, forKey: Keys.isCustomShortcutEnabled)
        }
    }

    /// The key code (CGKeyCode) for the custom shortcut
    var customShortcutKeyCode: UInt16? {
        didSet {
            if let keyCode = customShortcutKeyCode {
                UserDefaults.standard.set(Int(keyCode), forKey: Keys.customShortcutKeyCode)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.customShortcutKeyCode)
            }
        }
    }

    /// The modifier flags for the custom shortcut
    var customShortcutModifiers: NSEvent.ModifierFlags {
        didSet {
            UserDefaults.standard.set(customShortcutModifiers.rawValue, forKey: Keys.customShortcutModifiers)
        }
    }

    /// Human-readable display name for the shortcut (e.g., "⌘⇧D")
    var customShortcutDisplayName: String {
        didSet {
            UserDefaults.standard.set(customShortcutDisplayName, forKey: Keys.customShortcutDisplayName)
        }
    }

    /// Whether the shortcut is modifier-only (e.g., Ctrl+Opt+Cmd without a key)
    var isModifierOnlyShortcut: Bool {
        didSet {
            UserDefaults.standard.set(isModifierOnlyShortcut, forKey: Keys.isModifierOnlyShortcut)
        }
    }

    // MARK: - Computed Properties

    /// Returns true if a custom shortcut has been configured
    var hasCustomShortcut: Bool {
        // Either a key-based shortcut or a modifier-only shortcut
        customShortcutKeyCode != nil || (isModifierOnlyShortcut && !customShortcutModifiers.isEmpty)
    }

    // MARK: - Initialization

    private init() {
        // Load Fn key setting (default: enabled)
        isFnKeyEnabled = UserDefaults.standard.object(forKey: Keys.isFnKeyEnabled) as? Bool ?? true

        // Load custom shortcut settings (default: disabled, no shortcut)
        isCustomShortcutEnabled = UserDefaults.standard.object(forKey: Keys.isCustomShortcutEnabled) as? Bool ?? false

        if let keyCodeInt = UserDefaults.standard.object(forKey: Keys.customShortcutKeyCode) as? Int {
            customShortcutKeyCode = UInt16(keyCodeInt)
        } else {
            customShortcutKeyCode = nil
        }

        let modifiersRaw = UserDefaults.standard.object(forKey: Keys.customShortcutModifiers) as? UInt ?? 0
        customShortcutModifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)

        customShortcutDisplayName = UserDefaults.standard.string(forKey: Keys.customShortcutDisplayName) ?? ""

        isModifierOnlyShortcut = UserDefaults.standard.object(forKey: Keys.isModifierOnlyShortcut) as? Bool ?? false
    }

    // MARK: - Methods

    /// Clears the custom shortcut
    func clearCustomShortcut() {
        customShortcutKeyCode = nil
        customShortcutModifiers = []
        customShortcutDisplayName = ""
        isModifierOnlyShortcut = false
    }

    /// Sets a new custom shortcut from an NSEvent (key + modifiers)
    func setCustomShortcut(from event: NSEvent) {
        customShortcutKeyCode = event.keyCode
        customShortcutModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        customShortcutDisplayName = Self.displayName(for: event)
        isModifierOnlyShortcut = false
    }

    /// Sets a modifier-only shortcut (e.g., Ctrl+Opt+Cmd)
    func setModifierOnlyShortcut(modifiers: NSEvent.ModifierFlags) {
        customShortcutKeyCode = nil
        customShortcutModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        customShortcutDisplayName = Self.displayNameForModifiers(modifiers)
        isModifierOnlyShortcut = true
    }

    /// Generates a human-readable display name for a keyboard shortcut
    static func displayName(for event: NSEvent) -> String {
        var parts: [String] = []

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Add modifier symbols in standard macOS order
        if modifiers.contains(.control) {
            parts.append("⌃")
        }
        if modifiers.contains(.option) {
            parts.append("⌥")
        }
        if modifiers.contains(.shift) {
            parts.append("⇧")
        }
        if modifiers.contains(.command) {
            parts.append("⌘")
        }

        // Add the key name
        let keyName = Self.keyName(for: event.keyCode)
        parts.append(keyName)

        return parts.joined()
    }

    /// Generates a human-readable display name for modifier-only shortcuts
    static func displayNameForModifiers(_ modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []

        let cleanModifiers = modifiers.intersection(.deviceIndependentFlagsMask)

        // Add modifier symbols in standard macOS order
        if cleanModifiers.contains(.control) {
            parts.append("⌃")
        }
        if cleanModifiers.contains(.option) {
            parts.append("⌥")
        }
        if cleanModifiers.contains(.shift) {
            parts.append("⇧")
        }
        if cleanModifiers.contains(.command) {
            parts.append("⌘")
        }

        return parts.joined()
    }

    /// Returns a human-readable name for a key code
    static func keyName(for keyCode: UInt16) -> String {
        // Common key codes to names mapping
        let keyNames: [UInt16: String] = [
            // Letters (QWERTY layout)
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".",

            // Special keys
            36: "↩", // Return
            48: "⇥", // Tab
            49: "Space",
            51: "⌫", // Delete
            53: "⎋", // Escape
            76: "⌅", // Enter (keypad)
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 114: "Help", 115: "↖", // Home
            116: "⇞", // Page Up
            117: "⌦", // Forward Delete
            118: "F4", 119: "↘", // End
            120: "F2", 121: "⇟", // Page Down
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",

            // Function keys
            63: "fn",
        ]

        return keyNames[keyCode] ?? "Key\(keyCode)"
    }
}
