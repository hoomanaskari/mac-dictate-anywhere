//
//  InputSourceSettingsSection.swift
//  Dictate Anywhere
//
//  "Input Source Switching" section of General settings: opt-in toggle plus
//  per-input-source mapping rows. Language/model options are always derived
//  from ParakeetModelChoice / Apple Speech capability APIs — no local tables.
//

import SwiftUI

struct InputSourceSettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        let availableSources = appState.inputSourceMonitor.availableInputSources()

        VStack(alignment: .leading, spacing: DS.Spacing.section) {
            DSSection(overline: "Input Source Switching") {
                DSStackedRow(
                    label: "Match speech model to keyboard input source",
                    caption: "When you change keyboard input sources, apply the mapped engine, model, and language automatically.",
                    isOn: $settings.inputSourceAutoSwitchEnabled
                )
                if settings.inputSourceAutoSwitchEnabled {
                    ForEach(settings.inputSourceMappings) { mapping in
                        DSDivider()
                        InputSourceMappingRow(
                            mapping: mapping,
                            availableSources: availableSources,
                            takenSourceIDs: Set(
                                settings.inputSourceMappings
                                    .filter { $0.id != mapping.id }
                                    .map(\.inputSourceID)
                            )
                        )
                    }
                }
            }
            .onChange(of: settings.inputSourceAutoSwitchEnabled) { _, enabled in
                guard enabled,
                      let inputSourceID = appState.inputSourceMonitor.currentInputSourceID() else { return }
                appState.enqueueInputSourceProfileApply(for: inputSourceID)
            }

            if settings.inputSourceAutoSwitchEnabled {
                if canAddMapping(availableSources: availableSources) {
                    DSAddButton(title: "Add mapping") {
                        addMapping(availableSources: availableSources)
                    }
                }
                if !inactiveMappingNames.isEmpty {
                    DSHint(
                        text: "Inactive until downloaded in Speech Model settings: \(inactiveMappingNames.joined(separator: ", ")). Auto-switching never downloads models.",
                        icon: "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    private var inactiveMappingNames: [String] {
        appState.settings.inputSourceMappings.compactMap { mapping in
            switch mapping.engine {
            case .appleSpeech:
                return AppleSpeechEngine.isSupported ? nil : "Apple Speech"
            case .parakeet:
                guard let model = mapping.parakeetModel else { return nil }
                return appState.parakeetEngine.checkModelOnDisk(for: model) ? nil : model.displayName
            }
        }
    }

    private func canAddMapping(availableSources: [InputSourceInfo]) -> Bool {
        let taken = Set(appState.settings.inputSourceMappings.map(\.inputSourceID))
        return availableSources.contains { !taken.contains($0.id) }
    }

    private func addMapping(availableSources: [InputSourceInfo]) {
        let settings = appState.settings
        let taken = Set(settings.inputSourceMappings.map(\.inputSourceID))
        guard let source = availableSources.first(where: { !taken.contains($0.id) }) else { return }
        settings.addInputSourceMapping(
            inputSourceID: source.id,
            displayName: source.localizedName,
            derivedLanguage: InputSourceMonitor.deriveLanguage(fromBCP47: source.languageCodes),
            isModelDownloaded: { appState.parakeetEngine.checkModelOnDisk(for: $0) }
        )
    }
}

// MARK: - Mapping Row

private struct InputSourceMappingRow: View {
    @Environment(AppState.self) private var appState
    let mapping: InputSourceMapping
    let availableSources: [InputSourceInfo]
    let takenSourceIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSInfoRow(label: "Input source") {
                HStack(spacing: 10) {
                    DSDropdown(
                        selection: sourceBinding,
                        options: sourceOptions,
                        title: { sourceName(for: $0) }
                    )
                    DSIconButton(
                        systemImage: "trash",
                        accessibilityLabel: "Delete mapping"
                    ) {
                        appState.settings.removeInputSourceMapping(id: mapping.id)
                    }
                }
            }
            DSInfoRow(label: "Engine") {
                DSDropdown(
                    selection: engineBinding,
                    options: engineOptions,
                    title: \.displayName
                )
            }
            if mapping.engine == .parakeet {
                DSInfoRow(label: "Model") {
                    DSDropdown(
                        selection: modelBinding,
                        options: Array(ParakeetModelChoice.allCases),
                        title: { modelTitle(for: $0) }
                    )
                }
            }
            languageRow
        }
    }

    @ViewBuilder
    private var languageRow: some View {
        DSInfoRow(label: "Language") {
            if mapping.engine == .appleSpeech {
                DSDropdown(
                    selection: languageBinding,
                    options: appState.appleSpeechSupportedLanguages.isEmpty
                        ? [mapping.language]
                        : appState.appleSpeechSupportedLanguages,
                    title: \.displayWithFlag
                )
            } else if let selectable = mapping.parakeetModel?.selectableLanguages {
                DSDropdown(
                    selection: languageBinding,
                    options: selectable,
                    title: \.displayWithFlag
                )
            } else {
                Text(mapping.parakeetModel?.fixedLanguageLabel ?? "")
                    .font(DS.Fonts.ui(13.5))
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    // MARK: Options & titles

    private var sourceOptions: [String] {
        var ids = availableSources.map(\.id).filter { !takenSourceIDs.contains($0) }
        if !ids.contains(mapping.inputSourceID) {
            ids.insert(mapping.inputSourceID, at: 0)
        }
        return ids
    }

    private func sourceName(for id: String) -> String {
        if let source = availableSources.first(where: { $0.id == id }) {
            return source.localizedName
        }
        // Source no longer enabled in macOS; show the cached name.
        return "\(mapping.inputSourceDisplayName) (not enabled)"
    }

    private var engineOptions: [TranscriptionEngineChoice] {
        AppleSpeechEngine.isSupported ? Array(TranscriptionEngineChoice.allCases) : [.parakeet]
    }

    private func modelTitle(for model: ParakeetModelChoice) -> String {
        appState.parakeetEngine.checkModelOnDisk(for: model)
            ? model.displayName
            : "\(model.displayName) (not downloaded)"
    }

    // MARK: Bindings (route every edit through updateInputSourceMapping)

    private var sourceBinding: Binding<String> {
        Binding(
            get: { mapping.inputSourceID },
            set: { newID in
                var updated = mapping
                updated.inputSourceID = newID
                if let source = availableSources.first(where: { $0.id == newID }) {
                    updated.inputSourceDisplayName = source.localizedName
                }
                appState.settings.updateInputSourceMapping(updated)
            }
        )
    }

    private var engineBinding: Binding<TranscriptionEngineChoice> {
        Binding(
            get: { mapping.engine },
            set: { newEngine in
                var updated = mapping
                updated.engine = newEngine
                appState.settings.updateInputSourceMapping(updated)
            }
        )
    }

    private var modelBinding: Binding<ParakeetModelChoice> {
        Binding(
            get: { mapping.parakeetModel ?? appState.settings.parakeetModelChoice },
            set: { newModel in
                var updated = mapping
                updated.parakeetModel = newModel
                appState.settings.updateInputSourceMapping(updated)
            }
        )
    }

    private var languageBinding: Binding<SupportedLanguage> {
        Binding(
            get: { mapping.language },
            set: { newLanguage in
                var updated = mapping
                updated.language = newLanguage
                appState.settings.updateInputSourceMapping(updated)
            }
        )
    }
}
