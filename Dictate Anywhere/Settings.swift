//
//  Settings.swift
//  Dictate Anywhere
//
//  Centralized settings management with UserDefaults persistence.
//

import Foundation
import AppKit
import ServiceManagement
import IOKit.hidsystem

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

    var displayName: String {
        switch self {
        case .parakeet: return "Parakeet (FluidAudio)"
        }
    }
}

// MARK: - Hotkey Mode

enum HotkeyMode: String, CaseIterable, Codable {
    case holdToRecord = "holdToRecord"
    case handsFreeToggle = "handsFreeToggle"

    var displayName: String {
        switch self {
        case .holdToRecord: return "Hold to Record"
        case .handsFreeToggle: return "Tap to Toggle"
        }
    }
}

// MARK: - Hotkey Binding

nonisolated struct HotkeyModifiers: OptionSet, Codable, Equatable {
    let rawValue: UInt64

    static let command = HotkeyModifiers(rawValue: CGEventFlags.maskCommand.rawValue)
    static let control = HotkeyModifiers(rawValue: CGEventFlags.maskControl.rawValue)
    static let option = HotkeyModifiers(rawValue: CGEventFlags.maskAlternate.rawValue)
    static let shift = HotkeyModifiers(rawValue: CGEventFlags.maskShift.rawValue)
    static let function = HotkeyModifiers(rawValue: CGEventFlags.maskSecondaryFn.rawValue)
    // Retained for migration/sanitization only. Caps Lock is not supported as a hotkey.
    static let capsLock = HotkeyModifiers(rawValue: CGEventFlags.maskAlphaShift.rawValue)

    static let leftControl = HotkeyModifiers(rawValue: UInt64(NX_DEVICELCTLKEYMASK))
    static let rightControl = HotkeyModifiers(rawValue: UInt64(NX_DEVICERCTLKEYMASK))
    static let leftShift = HotkeyModifiers(rawValue: UInt64(NX_DEVICELSHIFTKEYMASK))
    static let rightShift = HotkeyModifiers(rawValue: UInt64(NX_DEVICERSHIFTKEYMASK))
    static let leftCommand = HotkeyModifiers(rawValue: UInt64(NX_DEVICELCMDKEYMASK))
    static let rightCommand = HotkeyModifiers(rawValue: UInt64(NX_DEVICERCMDKEYMASK))
    static let leftOption = HotkeyModifiers(rawValue: UInt64(NX_DEVICELALTKEYMASK))
    static let rightOption = HotkeyModifiers(rawValue: UInt64(NX_DEVICERALTKEYMASK))

    static let relevant: HotkeyModifiers = [
        .command, .control, .option, .shift, .function,
        .leftControl, .rightControl, .leftShift, .rightShift,
        .leftCommand, .rightCommand, .leftOption, .rightOption,
    ]
}

struct HotkeyBinding: Codable, Identifiable, Equatable {
    var id: UUID
    var keyCode: UInt16?
    var modifiersRawValue: UInt64
    var displayName: String
    var mode: HotkeyMode

    nonisolated var modifiers: HotkeyModifiers {
        get { Settings.normalizedHotkeyModifiers(HotkeyModifiers(rawValue: modifiersRawValue)) }
        set { modifiersRawValue = Settings.normalizedHotkeyModifiers(newValue).rawValue }
    }

    var hasBinding: Bool {
        keyCode != nil || !modifiers.isEmpty
    }

    /// Default binding: ⌃⌥⌘ (modifier-only), hold to record
    static let defaultBinding = HotkeyBinding(
        id: UUID(),
        keyCode: nil,
        modifiersRawValue: HotkeyModifiers([.control, .option, .command]).rawValue,
        displayName: "\u{2303}\u{2325}\u{2318}",
        mode: .holdToRecord
    )
}

// MARK: - Conflict Detector

enum ConflictDetector {
    /// Checks if a binding duplicates another binding in the array (by key combo, ignoring mode)
    static func internalConflict(for binding: HotkeyBinding, in bindings: [HotkeyBinding]) -> String? {
        guard binding.hasBinding else { return nil }
        let normalizedMods = binding.modifiers
        for other in bindings where other.id != binding.id && other.hasBinding {
            let otherMods = other.modifiers
            if other.keyCode == binding.keyCode && otherMods == normalizedMods {
                return "Duplicate of another shortcut"
            }
        }
        return nil
    }

    /// Checks if a binding conflicts with well-known macOS system shortcuts
    static func systemConflict(for binding: HotkeyBinding) -> String? {
        guard binding.hasBinding else { return nil }
        let mods = Settings.deviceIndependentModifiers(from: binding.modifiers)
        let key = binding.keyCode

        // Known system shortcuts: (keyCode, modifiers, description)
        let systemShortcuts: [(UInt16?, HotkeyModifiers, String)] = [
            (49, .command, "Spotlight"),                                           // ⌘Space
            (49, [.command, .option], "Finder Search"),                            // ⌘⌥Space
            (nil, [.control, .command], "Dictation"),                              // ⌃⌘ (modifier-only)
            (12, [.command, .option], "Force Quit"),                               // ⌘⌥Q
            (53, [.command, .option], "Force Quit"),                               // ⌘⌥Esc
            (20, [.command, .shift], "Screenshot area"),                           // ⌘⇧3
            (21, [.command, .shift], "Screenshot selection"),                      // ⌘⇧4
            (23, [.command, .shift], "Screenshot options"),                        // ⌘⇧5
        ]

        for (sysKey, sysMods, desc) in systemShortcuts {
            if key == sysKey && mods == sysMods {
                return "Conflicts with macOS \(desc)"
            }
        }
        return nil
    }
}

@Observable
final class Settings {
    // MARK: - Singleton

    static let shared = Settings()
    private nonisolated static let functionKeyCodes: Set<UInt16> = [63, 179]

    /// Background queue for sound playback
    private let soundQueue = DispatchQueue(label: "com.dictate-anywhere.sounds", qos: .userInteractive)

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let hotkeyBindings = "hotkeyBindings"
        // Legacy keys for migration
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
        static let legacyAppleSpeechMigrationPending = "legacyAppleSpeechMigrationPending"
        static let aiPostProcessingEnabled = "aiPostProcessingEnabled"
        static let aiPostProcessingPrompt = "aiPostProcessingPrompt"
        static let customVocabulary = "customVocabulary"
    }

    // MARK: - Hotkey Settings

    /// All configured hotkey bindings
    var hotkeyBindings: [HotkeyBinding] {
        didSet {
            guard let data = try? JSONEncoder().encode(hotkeyBindings) else { return }
            UserDefaults.standard.set(data, forKey: Keys.hotkeyBindings)
        }
    }

    /// Whether any hotkey has been configured
    var hasHotkey: Bool {
        hotkeyBindings.contains { $0.hasBinding }
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

    /// True when an existing user had the discontinued Apple Speech engine
    /// selected and still needs to download Parakeet.
    var legacyAppleSpeechMigrationPending: Bool {
        didSet {
            UserDefaults.standard.set(
                legacyAppleSpeechMigrationPending,
                forKey: Keys.legacyAppleSpeechMigrationPending
            )
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
            cachedFillerRegex = nil
        }
    }

    /// Cached compiled regex for filler word removal (invalidated when words change)
    private var cachedFillerRegex: NSRegularExpression?

    static let defaultFillerWords = ["um", "uh", "erm", "er", "hmm"]

    // MARK: - Custom Vocabulary (AI Post Processing)

    var customVocabulary: [String] {
        didSet {
            UserDefaults.standard.set(customVocabulary, forKey: Keys.customVocabulary)
        }
    }

    // MARK: - AI Post Processing

    var aiPostProcessingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(aiPostProcessingEnabled, forKey: Keys.aiPostProcessingEnabled)
        }
    }

    var aiPostProcessingPrompt: String {
        didSet {
            UserDefaults.standard.set(aiPostProcessingPrompt, forKey: Keys.aiPostProcessingPrompt)
        }
    }

    /// Vocabulary terms only apply when AI post-processing is enabled.
    var effectiveCustomVocabulary: [String] {
        aiPostProcessingEnabled ? customVocabulary : []
    }

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

        // Hotkey bindings (with migration from legacy single-hotkey format)
        if let data = defaults.data(forKey: Keys.hotkeyBindings),
           let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data) {
            let normalized = decoded.map(Self.canonicalizedHotkeyBinding)
            hotkeyBindings = normalized
            if normalized != decoded, let encoded = try? JSONEncoder().encode(normalized) {
                defaults.set(encoded, forKey: Keys.hotkeyBindings)
            }
        } else if defaults.object(forKey: Keys.hotkeyKeyCode) != nil
                    || defaults.object(forKey: Keys.hotkeyModifiers) != nil {
            // Migrate legacy single-hotkey properties
            let keyCode: UInt16? = (defaults.object(forKey: Keys.hotkeyKeyCode) as? Int).map { UInt16($0) }
            let modRaw = defaults.object(forKey: Keys.hotkeyModifiers) as? UInt64 ?? 0
            let mods = Self.hotkeyModifiers(from: CGEventFlags(rawValue: modRaw))
            let name = defaults.string(forKey: Keys.hotkeyDisplayName) ?? ""
            let modeStr = defaults.string(forKey: Keys.hotkeyMode) ?? HotkeyMode.holdToRecord.rawValue
            let mode = HotkeyMode(rawValue: modeStr) ?? .holdToRecord
            let migrated = Self.canonicalizedHotkeyBinding(HotkeyBinding(
                id: UUID(), keyCode: keyCode, modifiersRawValue: mods.rawValue,
                displayName: name.isEmpty ? Self.displayName(keyCode: keyCode, modifiers: mods) : name,
                mode: mode
            ))
            let migratedBindings = [migrated]
            hotkeyBindings = migratedBindings
            // Persist in new format
            if let data = try? JSONEncoder().encode(migratedBindings) {
                defaults.set(data, forKey: Keys.hotkeyBindings)
            }
            // Clean up legacy keys
            defaults.removeObject(forKey: Keys.hotkeyKeyCode)
            defaults.removeObject(forKey: Keys.hotkeyModifiers)
            defaults.removeObject(forKey: Keys.hotkeyDisplayName)
            defaults.removeObject(forKey: Keys.hotkeyMode)
        } else {
            // Fresh install: default binding
            hotkeyBindings = [HotkeyBinding.defaultBinding]
        }

        // Engine
        let hasChosenEngine = defaults.object(forKey: Keys.userHasChosenEngine) as? Bool ?? false
        userHasChosenEngine = hasChosenEngine
        let storedEngineRaw = defaults.string(forKey: Keys.engineChoice)
        let hadDiscontinuedAppleSpeech = storedEngineRaw == "appleSpeech"
        let previouslyPendingMigration = defaults.object(forKey: Keys.legacyAppleSpeechMigrationPending) as? Bool ?? false
        engineChoice = .parakeet
        if storedEngineRaw != TranscriptionEngineChoice.parakeet.rawValue {
            defaults.set(TranscriptionEngineChoice.parakeet.rawValue, forKey: Keys.engineChoice)
        }
        if hadDiscontinuedAppleSpeech {
            userHasChosenEngine = false
        }
        // Apply auto-default before first render to avoid transient startup mismatch.
        let parakeetExistsOnDisk = Self.parakeetModelExistsOnDisk()
        if !hasChosenEngine, parakeetExistsOnDisk {
            engineChoice = .parakeet
        }
        legacyAppleSpeechMigrationPending = (hadDiscontinuedAppleSpeech || previouslyPendingMigration) && !parakeetExistsOnDisk

        // Language
        let langCode = defaults.string(forKey: Keys.selectedLanguage) ?? "en"
        selectedLanguage = SupportedLanguage(rawValue: langCode) ?? .english

        // Filler words
        isFillerWordRemovalEnabled = defaults.object(forKey: Keys.isFillerWordRemovalEnabled) as? Bool ?? false
        fillerWordsToRemove = defaults.object(forKey: Keys.fillerWordsToRemove) as? [String] ?? Self.defaultFillerWords

        // Custom Vocabulary
        customVocabulary = defaults.object(forKey: Keys.customVocabulary) as? [String] ?? []

        // AI Post Processing
        aiPostProcessingEnabled = defaults.object(forKey: Keys.aiPostProcessingEnabled) as? Bool ?? false
        aiPostProcessingPrompt = defaults.string(forKey: Keys.aiPostProcessingPrompt) ?? ""

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

    /// Adds a new empty hotkey binding
    func addBinding() -> HotkeyBinding {
        let binding = HotkeyBinding(
            id: UUID(), keyCode: nil, modifiersRawValue: 0,
            displayName: "", mode: .holdToRecord
        )
        hotkeyBindings.append(binding)
        return binding
    }

    /// Updates an existing binding by ID
    func updateBinding(_ binding: HotkeyBinding) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == binding.id }) else { return }
        hotkeyBindings[index] = Self.canonicalizedHotkeyBinding(binding)
    }

    /// Updates a binding's key combo
    func updateBindingHotkey(id: UUID, keyCode: UInt16?, modifiers: HotkeyModifiers, displayName: String) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == id }) else { return }
        let normalizedModifiers = Self.normalizedHotkeyModifiers(modifiers)
        var updated = hotkeyBindings[index]
        updated.keyCode = keyCode
        updated.modifiersRawValue = normalizedModifiers.rawValue
        updated.displayName = displayName.isEmpty
            ? Self.displayName(keyCode: keyCode, modifiers: normalizedModifiers)
            : displayName
        hotkeyBindings[index] = Self.canonicalizedHotkeyBinding(updated)
    }

    /// Clears a binding's key combo (keeps the row)
    func clearBindingHotkey(id: UUID) {
        guard let index = hotkeyBindings.firstIndex(where: { $0.id == id }) else { return }
        hotkeyBindings[index].keyCode = nil
        hotkeyBindings[index].modifiersRawValue = 0
        hotkeyBindings[index].displayName = ""
    }

    /// Removes a binding entirely
    func removeBinding(id: UUID) {
        hotkeyBindings.removeAll { $0.id == id }
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

        // Build and cache the regex (invalidated when fillerWordsToRemove changes)
        let regex: NSRegularExpression
        if let cached = cachedFillerRegex {
            regex = cached
        } else {
            let escapedWords = fillerWordsToRemove
                .map { NSRegularExpression.escapedPattern(for: $0.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
            guard !escapedWords.isEmpty else { return text }

            let pattern = "\\b(" + escapedWords.joined(separator: "|") + ")\\b"
            do {
                let compiled = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                cachedFillerRegex = compiled
                regex = compiled
            } catch {
                return text
            }
        }

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
    }

    // MARK: - Key Name Utilities

    nonisolated static func keyName(for keyCode: UInt16) -> String {
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
            54: "R\u{2318}", 55: "L\u{2318}",
            58: "L\u{2325}", 61: "R\u{2325}",
            59: "L\u{2303}", 62: "R\u{2303}",
            56: "L\u{21E7}", 60: "R\u{21E7}",
            63: "fn",
            179: "fn",
        ]
        return keyNames[keyCode] ?? "Key\(keyCode)"
    }

    /// Builds a display name from modifier profile + key code
    nonisolated static func displayName(keyCode: UInt16?, modifiers: HotkeyModifiers) -> String {
        let normalizedModifiers = normalizedHotkeyModifiers(modifiers)
        var parts: [String] = []
        if normalizedModifiers.contains(.function) { parts.append("fn") }
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .control,
            left: .leftControl,
            right: .rightControl,
            symbol: "\u{2303}"
        )
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .option,
            left: .leftOption,
            right: .rightOption,
            symbol: "\u{2325}"
        )
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .shift,
            left: .leftShift,
            right: .rightShift,
            symbol: "\u{21E7}"
        )
        appendSideAware(
            parts: &parts,
            modifiers: normalizedModifiers,
            any: .command,
            left: .leftCommand,
            right: .rightCommand,
            symbol: "\u{2318}"
        )
        if let keyCode {
            let key = keyName(for: keyCode)
            // Avoid rendering duplicate "fn" when a legacy binding stores fn as keyCode.
            if !(normalizedModifiers.contains(.function) && key.lowercased() == "fn") {
                parts.append(key)
            }
        }
        return parts.joined()
    }

    private static func parakeetModelExistsOnDisk() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent("Library/Application Support/FluidAudio/Models")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        if let contents = try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
            return contents.contains { $0.lastPathComponent.hasPrefix("parakeet") }
        }
        return false
    }

    nonisolated static func normalizedModifierFlags(_ modifiers: CGEventFlags) -> CGEventFlags {
        cgEventFlags(from: hotkeyModifiers(from: modifiers))
    }

    nonisolated static func hotkeyModifiers(from flags: CGEventFlags) -> HotkeyModifiers {
        var modifiers = HotkeyModifiers()
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }

        let raw = flags.rawValue
        if raw & HotkeyModifiers.leftCommand.rawValue != 0 { modifiers.insert(.leftCommand) }
        if raw & HotkeyModifiers.rightCommand.rawValue != 0 { modifiers.insert(.rightCommand) }
        if raw & HotkeyModifiers.leftControl.rawValue != 0 { modifiers.insert(.leftControl) }
        if raw & HotkeyModifiers.rightControl.rawValue != 0 { modifiers.insert(.rightControl) }
        if raw & HotkeyModifiers.leftOption.rawValue != 0 { modifiers.insert(.leftOption) }
        if raw & HotkeyModifiers.rightOption.rawValue != 0 { modifiers.insert(.rightOption) }
        if raw & HotkeyModifiers.leftShift.rawValue != 0 { modifiers.insert(.leftShift) }
        if raw & HotkeyModifiers.rightShift.rawValue != 0 { modifiers.insert(.rightShift) }
        return normalizedHotkeyModifiers(modifiers)
    }

    nonisolated static func normalizedHotkeyModifiers(_ modifiers: HotkeyModifiers) -> HotkeyModifiers {
        var normalized = modifiers.intersection(.relevant)
        if normalized.intersection([.leftCommand, .rightCommand]).isEmpty == false {
            normalized.insert(.command)
        }
        if normalized.intersection([.leftControl, .rightControl]).isEmpty == false {
            normalized.insert(.control)
        }
        if normalized.intersection([.leftOption, .rightOption]).isEmpty == false {
            normalized.insert(.option)
        }
        if normalized.intersection([.leftShift, .rightShift]).isEmpty == false {
            normalized.insert(.shift)
        }
        return normalized
    }

    nonisolated static func deviceIndependentModifiers(from modifiers: HotkeyModifiers) -> HotkeyModifiers {
        let normalized = normalizedHotkeyModifiers(modifiers)
        var broad: HotkeyModifiers = []
        if normalized.contains(.command) { broad.insert(.command) }
        if normalized.contains(.control) { broad.insert(.control) }
        if normalized.contains(.option) { broad.insert(.option) }
        if normalized.contains(.shift) { broad.insert(.shift) }
        if normalized.contains(.function) { broad.insert(.function) }
        return broad
    }

    nonisolated static func cgEventFlags(from modifiers: HotkeyModifiers) -> CGEventFlags {
        let broad = deviceIndependentModifiers(from: modifiers)
        var flags = CGEventFlags(rawValue: 0)
        if broad.contains(.command) { flags.insert(.maskCommand) }
        if broad.contains(.control) { flags.insert(.maskControl) }
        if broad.contains(.option) { flags.insert(.maskAlternate) }
        if broad.contains(.shift) { flags.insert(.maskShift) }
        if broad.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    nonisolated static func keyedModifiersMatch(event: HotkeyModifiers, target: HotkeyModifiers) -> Bool {
        let normalizedEvent = normalizedHotkeyModifiers(event)
        let normalizedTarget = normalizedHotkeyModifiers(target)
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .command, left: .leftCommand, right: .rightCommand, exact: false) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .control, left: .leftControl, right: .rightControl, exact: false) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .option, left: .leftOption, right: .rightOption, exact: false) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .shift, left: .leftShift, right: .rightShift, exact: false) else { return false }
        if normalizedTarget.contains(.function) && !normalizedEvent.contains(.function) { return false }
        return true
    }

    nonisolated static func modifierOnlyModifiersMatch(event: HotkeyModifiers, target: HotkeyModifiers) -> Bool {
        let normalizedEvent = normalizedHotkeyModifiers(event)
        let normalizedTarget = normalizedHotkeyModifiers(target)
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .command, left: .leftCommand, right: .rightCommand, exact: true) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .control, left: .leftControl, right: .rightControl, exact: true) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .option, left: .leftOption, right: .rightOption, exact: true) else { return false }
        guard groupMatch(event: normalizedEvent, target: normalizedTarget, any: .shift, left: .leftShift, right: .rightShift, exact: true) else { return false }
        if normalizedTarget.contains(.function) != normalizedEvent.contains(.function) { return false }
        return true
    }

    private nonisolated static func canonicalizedHotkeyBinding(_ binding: HotkeyBinding) -> HotkeyBinding {
        var normalized = binding
        let hadCapsKey = normalized.keyCode == 57
        let hadCapsModifier = HotkeyModifiers(rawValue: normalized.modifiersRawValue).contains(.capsLock)
        if hadCapsKey || hadCapsModifier {
            normalized.keyCode = nil
            normalized.modifiersRawValue = 0
            normalized.displayName = ""
            return normalized
        }

        if let keyCode = normalized.keyCode, functionKeyCodes.contains(keyCode) {
            var modifiers = normalized.modifiers
            modifiers.insert(.function)
            normalized.keyCode = nil
            normalized.modifiers = modifiers
            normalized.displayName = displayName(keyCode: nil, modifiers: modifiers)
            return normalized
        }

        let modifiers = normalizedHotkeyModifiers(HotkeyModifiers(rawValue: normalized.modifiersRawValue))
        normalized.modifiersRawValue = modifiers.rawValue
        normalized.displayName = normalized.keyCode == nil && modifiers.isEmpty
            ? ""
            : displayName(keyCode: normalized.keyCode, modifiers: modifiers)
        return normalized
    }

    private nonisolated static func appendSideAware(
        parts: inout [String],
        modifiers: HotkeyModifiers,
        any: HotkeyModifiers,
        left: HotkeyModifiers,
        right: HotkeyModifiers,
        symbol: String
    ) {
        let hasLeft = modifiers.contains(left)
        let hasRight = modifiers.contains(right)
        if hasLeft { parts.append("L\(symbol)") }
        if hasRight { parts.append("R\(symbol)") }
        if !hasLeft && !hasRight && modifiers.contains(any) { parts.append(symbol) }
    }

    private nonisolated static func groupMatch(
        event: HotkeyModifiers,
        target: HotkeyModifiers,
        any: HotkeyModifiers,
        left: HotkeyModifiers,
        right: HotkeyModifiers,
        exact: Bool
    ) -> Bool {
        let targetAny = target.contains(any)
        let targetLeft = target.contains(left)
        let targetRight = target.contains(right)
        let eventAny = event.contains(any)
        let eventLeft = event.contains(left)
        let eventRight = event.contains(right)

        if !targetAny && !targetLeft && !targetRight {
            return exact ? (!eventAny && !eventLeft && !eventRight) : true
        }

        if targetLeft || targetRight {
            if targetLeft && !eventLeft { return false }
            if targetRight && !eventRight { return false }
            if !eventAny { return false }
            if exact {
                if !targetLeft && eventLeft { return false }
                if !targetRight && eventRight { return false }
            }
            return true
        }

        return eventAny
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let appAppearanceModeChanged = Notification.Name("appAppearanceModeChanged")
}
