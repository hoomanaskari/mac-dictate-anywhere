import Foundation
import AppKit
import ServiceManagement

// MARK: - App Appearance Mode

enum AppAppearanceMode: String, CaseIterable {
    case menuBarOnly = "menuBarOnly"
    case dockAndMenuBar = "dockAndMenuBar"

    var displayName: String {
        switch self {
        case .menuBarOnly: return "Menu Bar Only"
        case .dockAndMenuBar: return "Dock and Menu Bar"
        }
    }
}

@Observable
final class SettingsManager {
    // MARK: - Singleton

    static let shared = SettingsManager()

    /// Background queue for sound playback to avoid blocking MainActor
    private let soundQueue = DispatchQueue(label: "com.dictate-anywhere.sounds", qos: .userInteractive)

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let isFnKeyEnabled = "isFnKeyEnabled"
        static let isCustomShortcutEnabled = "isCustomShortcutEnabled"
        static let customShortcutKeyCode = "customShortcutKeyCode"
        static let customShortcutModifiers = "customShortcutModifiers"
        static let customShortcutDisplayName = "customShortcutDisplayName"
        static let isModifierOnlyShortcut = "isModifierOnlyShortcut"
        static let showTextPreview = "showTextPreview"
        static let selectedLanguage = "selectedLanguage"
        static let isAutoStopEnabled = "isAutoStopEnabled"
        static let isHandsFreeEnabled = "isHandsFreeEnabled"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let soundEffectsVolume = "soundEffectsVolume"
        static let isFillerWordRemovalEnabled = "isFillerWordRemovalEnabled"
        static let fillerWordsToRemove = "fillerWordsToRemove"
        static let launchAtLogin = "launchAtLogin"
        static let appAppearanceMode = "appAppearanceMode"
        static let analyticsEnabled = "analyticsEnabled"
        static let useSystemDefaultMicrophone = "useSystemDefaultMicrophone"
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

    // MARK: - Overlay Settings

    /// Whether to show text preview in the overlay window during dictation
    var showTextPreview: Bool {
        didSet {
            UserDefaults.standard.set(showTextPreview, forKey: Keys.showTextPreview)
        }
    }

    // MARK: - Language Settings

    /// The selected language for transcription
    var selectedLanguage: SupportedLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Keys.selectedLanguage)
        }
    }

    // MARK: - Auto-Stop Settings

    /// Whether to automatically stop dictation when speech ends (end-of-utterance detection)
    var isAutoStopEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoStopEnabled, forKey: Keys.isAutoStopEnabled)
        }
    }

    // MARK: - Hands-Free Mode Settings

    /// Whether hands-free mode is enabled (tap once to start, EOU or tap again to stop)
    var isHandsFreeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isHandsFreeEnabled, forKey: Keys.isHandsFreeEnabled)
        }
    }

    // MARK: - Sound Effects Settings

    /// Whether sound effects are enabled for dictation start/stop
    var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Keys.soundEffectsEnabled)
        }
    }

    /// Volume for sound effects (0.0 to 1.0)
    var soundEffectsVolume: Float {
        didSet {
            UserDefaults.standard.set(soundEffectsVolume, forKey: Keys.soundEffectsVolume)
        }
    }

    // MARK: - Filler Word Removal Settings

    /// Whether filler word removal is enabled
    var isFillerWordRemovalEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isFillerWordRemovalEnabled, forKey: Keys.isFillerWordRemovalEnabled)
        }
    }

    /// List of filler words to remove from transcriptions
    var fillerWordsToRemove: [String] {
        didSet {
            UserDefaults.standard.set(fillerWordsToRemove, forKey: Keys.fillerWordsToRemove)
        }
    }

    /// Default filler words
    static let defaultFillerWords = ["um", "uh", "erm", "er", "hmm"]

    // MARK: - App Behavior Settings

    /// Whether to launch the app at login
    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    /// How the app appears (menu bar only or dock and menu bar)
    var appAppearanceMode: AppAppearanceMode {
        didSet {
            UserDefaults.standard.set(appAppearanceMode.rawValue, forKey: Keys.appAppearanceMode)
            NotificationCenter.default.post(name: .appAppearanceModeChanged, object: nil)
        }
    }

    /// Whether anonymous analytics are enabled (infrastructure only)
    var analyticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(analyticsEnabled, forKey: Keys.analyticsEnabled)
        }
    }

    // MARK: - Microphone Settings

    /// Whether to automatically follow the system default microphone
    /// When enabled, the app always uses whatever device macOS considers the default input
    var useSystemDefaultMicrophone: Bool {
        didSet {
            UserDefaults.standard.set(useSystemDefaultMicrophone, forKey: Keys.useSystemDefaultMicrophone)
            NotificationCenter.default.post(name: .microphoneSelectionModeChanged, object: nil)
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

        // Load overlay settings (default: show text preview)
        showTextPreview = UserDefaults.standard.object(forKey: Keys.showTextPreview) as? Bool ?? true

        // Load language setting (default: English)
        let languageCode = UserDefaults.standard.string(forKey: Keys.selectedLanguage) ?? "en"
        selectedLanguage = SupportedLanguage(rawValue: languageCode) ?? .english

        // Load auto-stop setting (default: enabled)
        isAutoStopEnabled = UserDefaults.standard.object(forKey: Keys.isAutoStopEnabled) as? Bool ?? true

        // Load hands-free mode setting (default: disabled)
        isHandsFreeEnabled = UserDefaults.standard.object(forKey: Keys.isHandsFreeEnabled) as? Bool ?? false

        // Load sound effects settings (default: enabled at 30% volume)
        soundEffectsEnabled = UserDefaults.standard.object(forKey: Keys.soundEffectsEnabled) as? Bool ?? true
        soundEffectsVolume = UserDefaults.standard.object(forKey: Keys.soundEffectsVolume) as? Float ?? 0.3

        // Load filler word removal settings (default: disabled, with default words)
        isFillerWordRemovalEnabled = UserDefaults.standard.object(forKey: Keys.isFillerWordRemovalEnabled) as? Bool ?? false
        fillerWordsToRemove = UserDefaults.standard.object(forKey: Keys.fillerWordsToRemove) as? [String] ?? Self.defaultFillerWords

        // Load app behavior settings
        // For launch at login, check actual SMAppService status rather than just UserDefaults
        let savedLaunchAtLogin = UserDefaults.standard.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        launchAtLogin = savedLaunchAtLogin

        let appearanceModeString = UserDefaults.standard.string(forKey: Keys.appAppearanceMode) ?? AppAppearanceMode.menuBarOnly.rawValue
        appAppearanceMode = AppAppearanceMode(rawValue: appearanceModeString) ?? .menuBarOnly

        analyticsEnabled = UserDefaults.standard.object(forKey: Keys.analyticsEnabled) as? Bool ?? false

        // Load microphone settings (default: use system default)
        useSystemDefaultMicrophone = UserDefaults.standard.object(forKey: Keys.useSystemDefaultMicrophone) as? Bool ?? true

        // Property observers are not called during initialization.
        // Apply side effects explicitly so first-launch behavior matches defaults.
        updateLoginItem()
    }

    // MARK: - Methods

    /// Plays a sound effect if enabled, with the configured volume (runs off MainActor)
    func playSound(_ name: String) {
        guard soundEffectsEnabled else { return }
        let volume = soundEffectsVolume

        soundQueue.async {
            guard let sound = NSSound(named: name) else { return }
            sound.volume = volume
            sound.play()
        }
    }

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

    // MARK: - Login Item Management

    /// Updates the login item registration based on current setting
    private func updateLoginItem() {
        let service = SMAppService.mainApp
        let status = service.status

        if launchAtLogin {
            // Already enabled; nothing to do.
            if status == .enabled {
                return
            }
        } else {
            // Already disabled or unavailable; nothing to do.
            switch status {
            case .notRegistered, .notFound:
                return
            case .enabled, .requiresApproval:
                break
            @unknown default:
                break
            }
        }

        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
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

    // MARK: - Filler Word Removal

    /// Removes filler words from the given text using word boundary-aware matching
    /// - Parameter text: The input text to filter
    /// - Returns: Text with filler words removed (or original text if feature disabled)
    func removeFillerWords(from text: String) -> String {
        guard isFillerWordRemovalEnabled else { return text }
        guard !fillerWordsToRemove.isEmpty else { return text }

        // Build regex pattern with word boundaries
        // Escape special regex characters in filler words and join with |
        let escapedWords = fillerWordsToRemove
            .map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }

        guard !escapedWords.isEmpty else { return text }

        let pattern = "\\b(" + escapedWords.joined(separator: "|") + ")\\b"

        do {
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let range = NSRange(text.startIndex..., in: text)
            var result = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")

            // Clean up multiple spaces that may result from removal
            while result.contains("  ") {
                result = result.replacingOccurrences(of: "  ", with: " ")
            }

            // Clean up spaces before punctuation
            result = result.replacingOccurrences(of: " ,", with: ",")
            result = result.replacingOccurrences(of: " .", with: ".")
            result = result.replacingOccurrences(of: " !", with: "!")
            result = result.replacingOccurrences(of: " ?", with: "?")

            return result.trimmingCharacters(in: .whitespaces)
        } catch {
            // If regex fails, return original text
            return text
        }
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

// MARK: - Notification Names

extension Notification.Name {
    static let appAppearanceModeChanged = Notification.Name("appAppearanceModeChanged")
}
