//
//  InputSourceMonitor.swift
//  Dictate Anywhere
//
//  Watches the macOS keyboard input source (Carbon TIS API) and reports
//  selection changes so mapped transcription profiles can be applied.
//

import AppKit
import Carbon

struct InputSourceInfo: Equatable {
    let id: String
    let localizedName: String
    let languageCodes: [String]
}

@MainActor
final class InputSourceMonitor {
    /// Fires (debounced, on the main actor) with the new input source ID.
    var onSelectedInputSourceChanged: ((String) -> Void)?

    private var observer: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?

    func startMonitoring() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleChangeCallback()
            }
        }
    }

    func stopMonitoring() {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observer = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    /// Users often cycle through sources with Ctrl+Space; only the source
    /// they land on matters.
    private func scheduleChangeCallback() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let self, let id = self.currentInputSourceID() else { return }
            self.onSelectedInputSourceChanged?(id)
        }
    }

    func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return Self.stringProperty(of: source, key: kTISPropertyInputSourceID)
    }

    func availableInputSources() -> [InputSourceInfo] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
        ] as CFDictionary
        guard let cfList = TISCreateInputSourceList(filter, false)?.takeRetainedValue(),
              let list = cfList as NSArray as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard Self.boolProperty(of: source, key: kTISPropertyInputSourceIsSelectCapable),
                  Self.boolProperty(of: source, key: kTISPropertyInputSourceIsEnabled),
                  let id = Self.stringProperty(of: source, key: kTISPropertyInputSourceID) else {
                return nil
            }
            let name = Self.stringProperty(of: source, key: kTISPropertyLocalizedName) ?? id
            return InputSourceInfo(id: id, localizedName: name, languageCodes: Self.languageCodes(of: source))
        }
    }

    /// Maps an input source's declared BCP-47 codes to a supported language by
    /// primary subtag ("zh-Hans" -> .chinese). Norwegian keyboards declare
    /// "nb"; our raw value spells it "no".
    nonisolated static func deriveLanguage(fromBCP47 codes: [String]) -> SupportedLanguage? {
        guard let first = codes.first?.lowercased() else { return nil }
        var primary = first.split(separator: "-").first.map(String.init) ?? first
        if primary == "nb" { primary = "no" }
        return SupportedLanguage(rawValue: primary)
    }

    // MARK: - TIS property helpers

    private nonisolated static func stringProperty(of source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private nonisolated static func boolProperty(of source: TISInputSource, key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }

    private nonisolated static func languageCodes(of source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as NSArray as? [String] ?? []
    }
}
