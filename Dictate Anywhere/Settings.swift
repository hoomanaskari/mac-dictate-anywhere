//
//  Settings.swift
//  Dictate Anywhere
//
//  Centralized settings management with UserDefaults persistence.
//

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

// MARK: - Transcription Engine Choice

enum TranscriptionEngineChoice: String, CaseIterable {
    case parakeet = "parakeet"
    case appleSpeech = "appleSpeech"

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet (FluidAudio)"
        case .appleSpeech: return "Apple Speech"
        }
    }
}

// MARK: - Hotkey Mode

enum HotkeyMode: String, CaseIterable {
    case holdToRecord = "holdToRecord"
    case handsFreeToggle = "handsFreeToggle"

    var displayName: String {
        switch self {
        case .holdToRecord: return "Hold to Record"
        case .handsFreeToggle: return "Tap to Toggle"
        }
    }
}

@Observable
final class Settings {
    // MARK: - Singleton

    static let shared = Settings()

    /// Background queue for sound playback
    private let soundQueue = DispatchQueue(label: "com.dictate-anywhere.sounds", qos: .userInteractive)

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyDisplayName = "hotkeyDisplayName"
        static let hotkeyMode = "hotkeyMode"
        static let engineChoice = "engineChoice"
        static let selectedLanguage = "selectedLanguage"
        static let isFillerWordRemovalEnabled = "isFillerWordRemovalEnabled"
        static let fillerWordsToRemove = "fillerWordsToRemove"
        static let boostMicrophoneVolumeEnabled = "boostMicrophoneVolumeEnabled"
        static let muteSystemAudioDuringRecordingEnabled = "muteSystemAudioDuringRecordingEnabled"
        static let legacyAutoVolumeEnabled = "autoVolumeEnabled"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let soundEffectsVolume = "soundEffectsVolume"
        static let showTextPreview = "showTextPreview"
        static let launchAtLogin = "launchAtLogin"
        static let appAppearanceMode = "appAppearanceMode"
        static let selectedMicrophoneUID = "selectedMicrophoneUID"
        static let userHasChosenEngine = "userHasChosenEngine"
    }

    // MARK: - Hotkey Settings

    /// The key code for the hotkey (nil if not configured)
    var hotkeyKeyCode: UInt16? {
        didSet {
            if let keyCode = hotkeyKeyCode {
                UserDefaults.standard.set(Int(keyCode), forKey: Keys.hotkeyKeyCode)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.hotkeyKeyCode)
            }
        }
    }

    /// Modifier flags for the hotkey
    var hotkeyModifiers: CGEventFlags {
        didSet {
            UserDefaults.standard.set(hotkeyModifiers.rawValue, forKey: Keys.hotkeyModifiers)
        }
    }

    /// Human-readable display name for the hotkey
    var hotkeyDisplayName: String {
        didSet {
            UserDefaults.standard.set(hotkeyDisplayName, forKey: Keys.hotkeyDisplayName)
        }
    }

    /// Hotkey mode: hold-to-record vs hands-free toggle
    var hotkeyMode: HotkeyMode {
        didSet {
            UserDefaults.standard.set(hotkeyMode.rawValue, forKey: Keys.hotkeyMode)
        }
    }

    /// Whether a hotkey has been configured
    var hasHotkey: Bool {
        hotkeyKeyCode != nil || !Self.normalizedModifierFlags(hotkeyModifiers).isEmpty
    }

    // MARK: - Engine Settings

    /// Which transcription engine to use
    var engineChoice: TranscriptionEngineChoice {
        didSet {
            UserDefaults.standard.set(engineChoice.rawValue, forKey: Keys.engineChoice)
        }
    }

    /// Whether the user has explicitly chosen an engine (vs. using the auto-default)
    var userHasChosenEngine: Bool {
        didSet {
            UserDefaults.standard.set(userHasChosenEngine, forKey: Keys.userHasChosenEngine)
        }
    }

    // MARK: - Language Settings

    var selectedLanguage: SupportedLanguage {
        didSet {
            UserDefaults.standard.set(selectedLanguage.rawValue, forKey: Keys.selectedLanguage)
        }
    }

    // MARK: - Filler Word Removal

    var isFillerWordRemovalEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isFillerWordRemovalEnabled, forKey: Keys.isFillerWordRemovalEnabled)
        }
    }

    var fillerWordsToRemove: [String] {
        didSet {
            UserDefaults.standard.set(fillerWordsToRemove, forKey: Keys.fillerWordsToRemove)
        }
    }

    static let defaultFillerWords = ["um", "uh", "erm", "er", "hmm"]

    // MARK: - Microphone Selection

    /// Selected microphone UID. nil = follow system default.
    var selectedMicrophoneUID: String? {
        didSet {
            if let uid = selectedMicrophoneUID {
                UserDefaults.standard.set(uid, forKey: Keys.selectedMicrophoneUID)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.selectedMicrophoneUID)
            }
        }
    }

    // MARK: - Recording Audio

    var boostMicrophoneVolumeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(boostMicrophoneVolumeEnabled, forKey: Keys.boostMicrophoneVolumeEnabled)
        }
    }

    var muteSystemAudioDuringRecordingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(muteSystemAudioDuringRecordingEnabled, forKey: Keys.muteSystemAudioDuringRecordingEnabled)
        }
    }

    // MARK: - Sound Effects

    var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Keys.soundEffectsEnabled)
        }
    }

    var soundEffectsVolume: Float {
        didSet {
            UserDefaults.standard.set(soundEffectsVolume, forKey: Keys.soundEffectsVolume)
        }
    }

    // MARK: - Overlay Settings

    var showTextPreview: Bool {
        didSet {
            UserDefaults.standard.set(showTextPreview, forKey: Keys.showTextPreview)
        }
    }

    // MARK: - App Behavior

    var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    var appAppearanceMode: AppAppearanceMode {
        didSet {
            UserDefaults.standard.set(appAppearanceMode.rawValue, forKey: Keys.appAppearanceMode)
            NotificationCenter.default.post(name: .appAppearanceModeChanged, object: nil)
        }
    }

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults.standard

        // Hotkey
        if let keyCodeInt = defaults.object(forKey: Keys.hotkeyKeyCode) as? Int {
            hotkeyKeyCode = UInt16(keyCodeInt)
        } else {
            hotkeyKeyCode = nil
        }
        let modRaw = defaults.object(forKey: Keys.hotkeyModifiers) as? UInt64 ?? 0
        hotkeyModifiers = Self.normalizedModifierFlags(CGEventFlags(rawValue: modRaw))
        hotkeyDisplayName = defaults.string(forKey: Keys.hotkeyDisplayName) ?? ""
        let modeStr = defaults.string(forKey: Keys.hotkeyMode) ?? HotkeyMode.holdToRecord.rawValue
        hotkeyMode = HotkeyMode(rawValue: modeStr) ?? .holdToRecord

        // Engine
        userHasChosenEngine = defaults.object(forKey: Keys.userHasChosenEngine) as? Bool ?? false
        let engineStr = defaults.string(forKey: Keys.engineChoice) ?? TranscriptionEngineChoice.parakeet.rawValue
        engineChoice = TranscriptionEngineChoice(rawValue: engineStr) ?? .parakeet

        // Language
        let langCode = defaults.string(forKey: Keys.selectedLanguage) ?? "en"
        selectedLanguage = SupportedLanguage(rawValue: langCode) ?? .english

        // Filler words
        isFillerWordRemovalEnabled = defaults.object(forKey: Keys.isFillerWordRemovalEnabled) as? Bool ?? false
        fillerWordsToRemove = defaults.object(forKey: Keys.fillerWordsToRemove) as? [String] ?? Self.defaultFillerWords

        // Microphone selection
        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID)

        // Microphone boost (default: on)
        boostMicrophoneVolumeEnabled = defaults.object(forKey: Keys.boostMicrophoneVolumeEnabled) as? Bool ?? true

        // Recording audio handling (with migration from legacy auto-volume setting).
        if let storedValue = defaults.object(forKey: Keys.muteSystemAudioDuringRecordingEnabled) as? Bool {
            muteSystemAudioDuringRecordingEnabled = storedValue
        } else {
            let migratedValue = defaults.object(forKey: Keys.legacyAutoVolumeEnabled) as? Bool ?? false
            muteSystemAudioDuringRecordingEnabled = migratedValue
            defaults.set(migratedValue, forKey: Keys.muteSystemAudioDuringRecordingEnabled)
        }

        // Sound
        soundEffectsEnabled = defaults.object(forKey: Keys.soundEffectsEnabled) as? Bool ?? true
        soundEffectsVolume = defaults.object(forKey: Keys.soundEffectsVolume) as? Float ?? 0.3

        // Overlay
        showTextPreview = defaults.object(forKey: Keys.showTextPreview) as? Bool ?? true

        // App behavior
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        let appearStr = defaults.string(forKey: Keys.appAppearanceMode) ?? AppAppearanceMode.menuBarOnly.rawValue
        appAppearanceMode = AppAppearanceMode(rawValue: appearStr) ?? .menuBarOnly

        updateLoginItem()
    }

    // MARK: - Methods

    /// Plays a sound effect if enabled
    func playSound(_ name: String) {
        guard soundEffectsEnabled else { return }
        let volume = soundEffectsVolume
        soundQueue.async {
            guard let sound = NSSound(named: name) else { return }
            sound.volume = volume
            sound.play()
        }
    }

    /// Sets the hotkey from a CGEvent
    func setHotkey(keyCode: UInt16?, modifiers: CGEventFlags, displayName: String) {
        let normalizedModifiers = Self.normalizedModifierFlags(modifiers)
        hotkeyKeyCode = keyCode
        hotkeyModifiers = normalizedModifiers
        hotkeyDisplayName = displayName.isEmpty
            ? Self.displayName(keyCode: keyCode, modifiers: normalizedModifiers)
            : displayName
    }

    /// Clears the hotkey
    func clearHotkey() {
        hotkeyKeyCode = nil
        hotkeyModifiers = CGEventFlags(rawValue: 0)
        hotkeyDisplayName = ""
    }

    // MARK: - Login Item

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            }
        } catch {
            print("Failed to update login item: \(error)")
        }
    }

    // MARK: - Filler Word Removal

    func removeFillerWords(from text: String) -> String {
        guard isFillerWordRemovalEnabled, !fillerWordsToRemove.isEmpty else { return text }

        let escapedWords = fillerWordsToRemove
            .map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        guard !escapedWords.isEmpty else { return text }

        let pattern = "\\b(" + escapedWords.joined(separator: "|") + ")\\b"
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let range = NSRange(text.startIndex..., in: text)
            var result = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            while result.contains("  ") {
                result = result.replacingOccurrences(of: "  ", with: " ")
            }
            result = result.replacingOccurrences(of: " ,", with: ",")
            result = result.replacingOccurrences(of: " .", with: ".")
            result = result.replacingOccurrences(of: " !", with: "!")
            result = result.replacingOccurrences(of: " ?", with: "?")
            return result.trimmingCharacters(in: .whitespaces)
        } catch {
            return text
        }
    }

    // MARK: - Key Name Utilities

    static func keyName(for keyCode: UInt16) -> String {
        let keyNames: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".",
            36: "\u{21A9}", 48: "\u{21E5}", 49: "Space", 51: "\u{232B}", 53: "\u{238B}",
            76: "\u{2305}",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 114: "Help", 115: "\u{2196}", 116: "\u{21DE}",
            117: "\u{2326}", 118: "F4", 119: "\u{2198}", 120: "F2", 121: "\u{21DF}",
            122: "F1", 123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
            63: "fn",
        ]
        return keyNames[keyCode] ?? "Key\(keyCode)"
    }

    /// Builds a display name from CGEventFlags + key code
    static func displayName(keyCode: UInt16?, modifiers: CGEventFlags) -> String {
        let normalizedModifiers = normalizedModifierFlags(modifiers)
        var parts: [String] = []
        if normalizedModifiers.contains(.maskControl) { parts.append("\u{2303}") }
        if normalizedModifiers.contains(.maskAlternate) { parts.append("\u{2325}") }
        if normalizedModifiers.contains(.maskShift) { parts.append("\u{21E7}") }
        if normalizedModifiers.contains(.maskCommand) { parts.append("\u{2318}") }
        if let keyCode {
            parts.append(keyName(for: keyCode))
        }
        return parts.joined()
    }

    static func normalizedModifierFlags(_ modifiers: CGEventFlags) -> CGEventFlags {
        let relevantFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return modifiers.intersection(relevantFlags)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let appAppearanceModeChanged = Notification.Name("appAppearanceModeChanged")
}
