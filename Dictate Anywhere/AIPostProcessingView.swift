//
//  AIPostProcessingView.swift
//  Dictate Anywhere
//
//  "Transcript Cleanup" page: AI post-processing settings.
//

import SwiftUI
import FoundationModels
import AppKit

struct AIPostProcessingView: View {
    @Environment(AppState.self) private var appState
    @State private var newFillerWord = ""
    @State private var ollamaAvailability: OllamaPostProcessingService.Availability?
    @State private var ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
    @State private var ollamaPendingDeletionModel: String?
    @State private var ollamaStatusMessage: String?
    @State private var isCheckingOllama = false
    @State private var ollamaCheckID: UUID?
    @State private var openRouterAvailability: OpenRouterPostProcessingService.Availability?
    @State private var openRouterStatusMessage: String?
    @State private var isCheckingOpenRouter = false
    @State private var openRouterCheckID: UUID?
    @State private var openAICompatibleAvailability: OpenAICompatiblePostProcessingService.Availability?
    @State private var openAICompatibleStatusMessage: String?
    @State private var isCheckingOpenAICompatible = false
    @State private var openAICompatibleCheckID: UUID?
    @State private var isConfirmingS1MiniDeletion = false
    @State private var s1MiniActionError: String?
    private let shouldAutoRefreshProviderAvailability: Bool

    init(
        initialOllamaAvailability: OllamaPostProcessingService.Availability? = nil,
        initialOllamaCLIAvailability: OllamaPostProcessingService.CLIAvailability = OllamaPostProcessingService.cliAvailability(),
        initialOllamaStatusMessage: String? = nil,
        initialOpenRouterAvailability: OpenRouterPostProcessingService.Availability? = nil,
        initialOpenRouterStatusMessage: String? = nil,
        initialOpenAICompatibleAvailability: OpenAICompatiblePostProcessingService.Availability? = nil,
        initialOpenAICompatibleStatusMessage: String? = nil,
        shouldAutoRefreshProviderAvailability: Bool = true
    ) {
        _ollamaAvailability = State(initialValue: initialOllamaAvailability)
        _ollamaCLIAvailability = State(initialValue: initialOllamaCLIAvailability)
        _ollamaStatusMessage = State(initialValue: initialOllamaStatusMessage)
        _openRouterAvailability = State(initialValue: initialOpenRouterAvailability)
        _openRouterStatusMessage = State(initialValue: initialOpenRouterStatusMessage)
        _openAICompatibleAvailability = State(initialValue: initialOpenAICompatibleAvailability)
        _openAICompatibleStatusMessage = State(initialValue: initialOpenAICompatibleStatusMessage)
        self.shouldAutoRefreshProviderAvailability = shouldAutoRefreshProviderAvailability
    }

    var body: some View {
        @Bindable var settings = appState.settings

        DSPage {
            DSSectionHeader(
                title: "Transcript Cleanup",
                subtitle: "Choose how your transcript is polished before it's pasted."
            )

            DSSection(overline: "Cleanup Method") {
                DSDetailRow(
                    label: "Method",
                    caption: "Choose a built-in model, vocabulary correction only, or a custom model provider. Local filler-word removal below runs before the selected method."
                ) {
                    CleanupMethodMenu(
                        selection: $settings.transcriptPostProcessingMode,
                        offersVocabulary: settings.engineChoice != .parakeet
                            || settings.parakeetModelChoice.supportsFluidAudioVocabulary
                    )
                }
                if let model = cleanupModelIdentity(settings: settings) {
                    DSDivider()
                    DSInfoRow(label: "Model", value: model)
                }
            }

            // Setup for the selected method sits directly under the picker, so
            // its status and any blocking action stay in the same viewport.
            selectedMethodContent(settings: settings)
            if settings.transcriptPostProcessingMode != .none,
               settings.transcriptPostProcessingMode != .s1Mini,
               settings.engineChoice != .assemblyAI {
                DSSection(overline: "Preparation") {
                    DSModelReadinessRow(readiness: appState.cleanupReadiness,
                        label: settings.transcriptPostProcessingMode == .fluidAudioVocabulary ? "Vocabulary recognition" : "Cleanup model",
                        actionTitle: appState.canPrepareCleanupEngine ? (appState.cleanupReadiness.detail == nil ? "Prepare" : "Retry") : nil,
                        action: { Task { await appState.prepareCleanupEngineIfNeeded(force: true) } })
                        .disabled(appState.status != .idle)
                    DSDivider()
                    DSCardCaption(text: "Ready means the local model has been prepared. Preparing downloads missing local support files before first use. Remote services show Configured; preparation checks their connection and model information.")
                }
            }

            let supportedFeatures = settings.transcriptPostProcessingMode.supportedFeatures

            if supportedFeatures.contains(.dictationContext) {
                contextAwarenessContent(settings: settings)
            }

            if supportedFeatures.contains(.localFillerWordRemoval) {
                localFillerWordCleanupContent(settings: settings)
            }
        }
        .task(id: Self.providerTaskID(
            settings: settings,
            ollamaModelActionsRevision: appState.ollamaModelActionsRevision
        )) {
            guard shouldAutoRefreshProviderAvailability else { return }
            ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
            await refreshProviderAvailabilityIfNeeded(settings: settings)
        }
        .task(id: appState.cleanupPreparationKey) {
            await appState.prepareCleanupEngineIfNeeded()
        }
        .alert(
            "Delete Ollama Model?",
            isPresented: Binding(
                get: { ollamaPendingDeletionModel != nil },
                set: { isPresented in
                    if !isPresented {
                        ollamaPendingDeletionModel = nil
                    }
                }
            )
        ) {
            Button("Delete", role: .destructive) {
                guard let model = ollamaPendingDeletionModel else { return }
                ollamaPendingDeletionModel = nil
                Task {
                    await appState.deleteOllamaModel(model)
                }
            }
            Button("Cancel", role: .cancel) {
                ollamaPendingDeletionModel = nil
            }
        } message: {
            Text("This will remove \(ollamaPendingDeletionModel ?? "this model") from the configured Ollama server.")
        }
        .alert("Delete S1-mini by Superwhisper?", isPresented: $isConfirmingS1MiniDeletion) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await appState.s1MiniModelManager.deleteModel()
                        s1MiniActionError = nil
                    } catch {
                        s1MiniActionError = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local model and its downloaded license file. You can download them again later.")
        }
    }


    private func cleanupModelIdentity(settings: Settings) -> String? {
        let customID: String
        switch settings.transcriptPostProcessingMode {
        case .none, .fluidAudioVocabulary: return nil
        case .appleIntelligence: return "Apple Foundation Models — managed by macOS"
        case .s1Mini: return "Superwhisper S1-mini — Qwen3 0.6B fine-tune"
        case .ollama: customID = settings.ollamaModel
        case .openRouter: customID = settings.openRouterModel
        case .openAICompatible: customID = settings.openAICompatibleModel
        }
        let model = customID.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Choose a model ID below" : model
    }

    // MARK: - Selected method

    /// Setup for whichever cleanup method is selected. Every branch opens with
    /// a section named after that method that carries its status and blockers,
    /// so the page never shows configuration for a method you did not pick.
    @ViewBuilder
    private func selectedMethodContent(settings: Settings) -> some View {
        switch settings.transcriptPostProcessingMode {
        case .none:
            DSSection(overline: "No Cleanup") {
                DSCardCaption(text: "Your transcript is pasted exactly as the speech model produced it, after the local filler-word removal below. Pick another method to turn on AI cleanup, per-destination writing styles, and app context.")
            }
        case .fluidAudioVocabulary:
            fluidAudioVocabularyContent(settings: settings)
        case .appleIntelligence:
            if #available(macOS 26, *) {
                appleIntelligenceContent(settings: settings)
            } else {
                DSSection(overline: "Apple Intelligence") {
                    DSInfoRow(label: "Status", value: "Requires macOS 26")
                }
            }
        case .s1Mini:
            s1MiniContent(settings: settings)
        case .ollama:
            ollamaContent(settings: settings)
        case .openRouter:
            openRouterContent(settings: settings)
        case .openAICompatible:
            openAICompatibleContent(settings: settings)
        }
    }

    // MARK: - Context awareness

    @ViewBuilder
    private func contextAwarenessContent(settings: Settings) -> some View {
        @Bindable var settings = settings

        let mode = settings.transcriptPostProcessingMode
        let supportedFeatures = mode.supportedFeatures
        let contextSupport = dictationContextSupport(for: mode, settings: settings)

        // What gets read.
        DSSection(overline: "Context Awareness") {
            DSStackedRow(
                label: "Adapt to the current app and text field",
                caption: contextAwarenessCaption(for: mode, support: contextSupport),
                isOn: $settings.dictationContextAwarenessEnabled
            )

            if settings.dictationContextAwarenessEnabled {
                if contextSupport.offersRemoteTextSharing {
                    DSDivider()
                    DSStackedRow(
                        label: "Share surrounding text with \(mode.displayName)",
                        caption: shareContextCaption(for: mode),
                        isOn: $settings.shareDictationContextWithRemoteProviders
                    )
                } else {
                    DSDivider()
                    DSCardCaption(text: contextDeliveryCaption(for: mode, support: contextSupport))
                }
            }
        }

        if settings.dictationContextAwarenessEnabled {
            if supportedFeatures.contains(.categoryWritingStyles) {
                DSSection(overline: "Writing Style") {
                    writingStyleRow(settings: settings, category: .email)
                    DSDivider()
                    writingStyleRow(settings: settings, category: .workMessaging)
                    DSDivider()
                    writingStyleRow(settings: settings, category: .personalMessaging)
                    DSDivider()
                    writingStyleRow(settings: settings, category: .other)
                    DSDivider()
                    DSCardCaption(text: "\(mode.displayName) is told which of these four destinations you are dictating into, and matches the style you set for it.")
                }
            }

            if supportedFeatures.contains(.s1MiniCategoryStyling) {
                s1MiniAppStylingContent(settings: settings)
            }

            if supportedFeatures.contains(.appCategories) {
                // Which app counts as which destination.
                DSSection(overline: "App Categories") {
                    DSCardCaption(text: appCategoriesCaption(for: mode))

                    if !settings.dictationAppRules.isEmpty {
                        DSDivider()
                    }
                    ForEach(Array(settings.dictationAppRules.enumerated()), id: \.element.id) { index, rule in
                        appRuleRow(settings: settings, index: index, rule: rule)
                        if index < settings.dictationAppRules.count - 1 {
                            DSDivider()
                        }
                    }
                    if !settings.dictationAppRules.isEmpty {
                        DSDivider()
                    }
                    cardPadded {
                        Menu {
                            let apps = availableRunningApps(settings: settings)
                            if apps.isEmpty {
                                Text("No other running apps")
                            } else {
                                ForEach(apps) { app in
                                    Button(app.name) {
                                        addAppRule(app, settings: settings)
                                    }
                                }
                            }
                        } label: {
                            Label("Add Running App", systemImage: "plus")
                        }
                        .buttonStyle(.dsSecondary)
                    }
                }
            }
        }
    }

    private func dictationContextSupport(
        for mode: TranscriptPostProcessingMode,
        settings: Settings
    ) -> DictationContextSupport {
        let isConfiguredServerLocal: Bool
        switch mode {
        case .ollama:
            isConfiguredServerLocal = OllamaPostProcessingService.isLocalServer(
                baseURL: settings.ollamaBaseURL
            )
        case .openAICompatible:
            isConfiguredServerLocal = OllamaPostProcessingService.isLocalServer(
                baseURL: settings.openAICompatibleBaseURL
            )
        case .none, .fluidAudioVocabulary, .appleIntelligence, .s1Mini, .openRouter:
            isConfiguredServerLocal = false
        }
        return mode.dictationContextSupport(
            isConfiguredServerLocal: isConfiguredServerLocal
        )
    }

    private func contextAwarenessCaption(
        for mode: TranscriptPostProcessingMode,
        support: DictationContextSupport
    ) -> String {
        switch support {
        case .categoryOnlyOnDevice:
            return "Detects the app category and cursor position locally. S1-mini receives only its trained email/general context value; surrounding text stays outside the model. Password fields and excluded apps are never read."
        case .fullOnDevice:
            return "Reads a bounded snapshot around the cursor, classifies the destination, and applies its writing style entirely on this Mac. Password fields and excluded apps are never read."
        case .fullLocalServer:
            return "Reads a bounded snapshot around the cursor and supplies it to the configured local server. Password fields and excluded apps are never read."
        case .remoteCategoryWithOptionalText:
            return "Classifies the destination and applies its writing style. Surrounding text is shared only when separately enabled below; password fields and excluded apps are never read."
        case .none:
            return "\(mode.displayName) does not use dictation context."
        }
    }

    /// Opt-in copy for the one selected method that could reach off this Mac.
    private func shareContextCaption(for mode: TranscriptPostProcessingMode) -> String {
        switch mode {
        case .openRouter:
            return "Off by default. The destination category and writing style are always sent. The text around your cursor stays on this Mac unless you turn this on."
        case .ollama, .openAICompatible:
            return "Off by default. The destination category and writing style are always sent. The text around your cursor stays on this Mac unless you turn this on."
        case .none, .fluidAudioVocabulary, .appleIntelligence, .s1Mini:
            return ""
        }
    }

    private func contextDeliveryCaption(
        for mode: TranscriptPostProcessingMode,
        support: DictationContextSupport
    ) -> String {
        switch support {
        case .categoryOnlyOnDevice:
            return "S1-mini by Superwhisper receives only the destination category, so its Automatic context control can choose email or general formatting. The text around your cursor is never passed to the model, and nothing leaves this Mac."
        case .fullOnDevice:
            return "Apple Intelligence runs on this Mac, so anything read around your cursor stays on this device."
        case .fullLocalServer:
            return "The configured \(mode.displayName) server is local, so surrounding text is supplied automatically and never leaves this Mac. The remote-sharing setting is hidden because it has no effect for this endpoint."
        case .none, .remoteCategoryWithOptionalText:
            return ""
        }
    }

    private func appCategoriesCaption(for mode: TranscriptPostProcessingMode) -> String {
        if mode == .s1Mini {
            return "Common email and messaging apps and sites are categorized automatically. Categories select only S1-mini's trained styling values, and its Automatic context maps email to Email and every other category to General. Add an override to recategorize an app or stop reading its field context."
        }
        return "Common email and messaging apps and sites are categorized automatically. Add an override only when an app should use another category or should not expose surrounding text."
    }

    private func writingStyleRow(
        settings: Settings,
        category: DictationContextCategory
    ) -> some View {
        DSDetailRow(
            label: category.displayName,
            caption: styleCaption(for: category)
        ) {
            DSDropdown(
                selection: writingStyleBinding(settings: settings, category: category),
                options: DictationWritingStyle.options(for: category),
                title: \.displayName,
                accessibilityName: "Writing style for \(category.displayName)"
            )
        }
    }

    @ViewBuilder
    private func s1MiniAppStylingContent(settings: Settings) -> some View {
        DSSection(overline: "S1-mini App Styling") {
            s1MiniStylingRow(settings: settings, category: .email)
            DSDivider()
            s1MiniStylingRow(settings: settings, category: .workMessaging)
            DSDivider()
            s1MiniStylingRow(settings: settings, category: .personalMessaging)
            DSDivider()
            s1MiniStylingRow(settings: settings, category: .other)
            DSDivider()
            DSDetailRow(
                label: "Fallback",
                caption: "Used only when no destination app can be captured."
            ) {
                DSDropdown(
                    selection: Binding(
                        get: { settings.s1MiniStyling },
                        set: { settings.s1MiniStyling = $0 }
                    ),
                    options: S1MiniStyling.allCases,
                    title: \.displayName,
                    accessibilityName: "S1-mini fallback style"
                )
            }
            DSDivider()
            DSCardCaption(text: "Every option shown here is one of S1-mini's trained Styling values. Dictate Anywhere selects the value locally from the destination category without changing the model prompt format.")
        }
    }

    private func s1MiniStylingRow(
        settings: Settings,
        category: DictationContextCategory
    ) -> some View {
        DSDetailRow(
            label: category.displayName,
            caption: styleCaption(for: category)
        ) {
            DSDropdown(
                selection: s1MiniStylingBinding(settings: settings, category: category),
                options: S1MiniStyling.allCases,
                title: \.displayName,
                accessibilityName: "S1-mini style for \(category.displayName)"
            )
        }
    }

    private func s1MiniStylingBinding(
        settings: Settings,
        category: DictationContextCategory
    ) -> Binding<S1MiniStyling> {
        Binding(
            get: { settings.s1MiniAppStyling.styling(for: category) },
            set: { styling in
                var appStyling = settings.s1MiniAppStyling
                appStyling.set(styling, for: category)
                settings.s1MiniAppStyling = appStyling
            }
        )
    }

    private func appRuleRow(settings: Settings, index: Int, rule: DictationAppRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.appName)
                    .font(DS.Fonts.ui(13.5, .medium))
                    .foregroundStyle(DS.Colors.ink)
                Text(rule.bundleIdentifier)
                    .font(DS.Fonts.ui(11.5))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                DSDropdown(
                    selection: appRuleCategoryBinding(settings: settings, index: index),
                    options: DictationContextCategory.allCases,
                    title: \.displayName,
                    accessibilityName: "Category for \(rule.appName)"
                )
                Spacer(minLength: 0)
                Text("Read field context")
                    .font(DS.Fonts.ui(13.5, .medium))
                    .foregroundStyle(DS.Colors.ink)
                DSSwitch(
                    accessibilityName: "Read field context for \(rule.appName)",
                    isOn: appRuleContextBinding(settings: settings, index: index)
                )
                DSIconButton(
                    systemImage: "trash",
                    tint: DS.Colors.destructive,
                    accessibilityLabel: "Remove \(rule.appName) override"
                ) {
                    guard settings.dictationAppRules.indices.contains(index) else { return }
                    settings.dictationAppRules.remove(at: index)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    private func writingStyleBinding(
        settings: Settings,
        category: DictationContextCategory
    ) -> Binding<DictationWritingStyle> {
        Binding(
            get: { settings.dictationWritingStyle(for: category) },
            set: { value in
                switch category {
                case .email: settings.emailDictationWritingStyle = value
                case .workMessaging: settings.workMessagingDictationWritingStyle = value
                case .personalMessaging: settings.personalMessagingDictationWritingStyle = value
                case .other: settings.otherDictationWritingStyle = value
                }
            }
        )
    }

    private func appRuleCategoryBinding(settings: Settings, index: Int) -> Binding<DictationContextCategory> {
        Binding(
            get: {
                guard settings.dictationAppRules.indices.contains(index) else { return .other }
                return settings.dictationAppRules[index].category
            },
            set: { category in
                guard settings.dictationAppRules.indices.contains(index) else { return }
                settings.dictationAppRules[index].category = category
            }
        )
    }

    private func appRuleContextBinding(settings: Settings, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                settings.dictationAppRules.indices.contains(index)
                    ? settings.dictationAppRules[index].contextEnabled
                    : false
            },
            set: { enabled in
                guard settings.dictationAppRules.indices.contains(index) else { return }
                settings.dictationAppRules[index].contextEnabled = enabled
            }
        )
    }

    private func styleCaption(for category: DictationContextCategory) -> String {
        switch category {
        case .email: return "Used in mail apps and webmail."
        case .workMessaging: return "Used in Slack, Teams, Discord, and similar work chat."
        case .personalMessaging: return "Used in Messages, WhatsApp, Telegram, and similar personal chat."
        case .other: return "Used when no email or messaging category matches."
        }
    }

    private struct RunningContextApp: Identifiable {
        let bundleIdentifier: String
        let name: String
        var id: String { bundleIdentifier }
    }

    private func availableRunningApps(settings: Settings) -> [RunningContextApp] {
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let existing = Set(settings.dictationAppRules.map { $0.bundleIdentifier.lowercased() })
        return NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && $0.bundleIdentifier != currentBundleIdentifier
                    && $0.bundleIdentifier != nil
            }
            .compactMap { app -> RunningContextApp? in
                guard let bundleIdentifier = app.bundleIdentifier,
                      !existing.contains(bundleIdentifier.lowercased()) else { return nil }
                return RunningContextApp(
                    bundleIdentifier: bundleIdentifier,
                    name: app.localizedName ?? bundleIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addAppRule(_ app: RunningContextApp, settings: Settings) {
        let classification = DictationContextClassifier.classification(
            bundleIdentifier: app.bundleIdentifier,
            documentURL: nil,
            rules: []
        )
        settings.dictationAppRules.append(
            DictationAppRule(
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                category: classification.category
            )
        )
    }

    // MARK: - Shared row helpers

    /// Labeled single-line field row inside a card.
    @ViewBuilder
    private func fieldRow<Field: View>(
        label: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Text(label)
                .font(DS.Fonts.ui(13.5, .medium))
                .foregroundStyle(DS.Colors.ink)
            Spacer(minLength: 0)
            field()
                .frame(width: 320)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    @ViewBuilder
    private func cardPadded<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    // MARK: - Shared prompt editor

    private func cleanupPromptSection(
        text: Binding<String>, label: String, defaultPrompt: String? = nil
    ) -> some View {
        DSSection(overline: "Prompt") {
            cardPadded {
                HStack(alignment: .firstTextBaseline) {
                    Text("Cleanup instructions")
                        .font(DS.Fonts.ui(13.5, .medium))
                        .foregroundStyle(DS.Colors.ink)
                    Spacer(minLength: 0)
                    if let defaultPrompt {
                        Button("Reset to Default") {
                            text.wrappedValue = defaultPrompt
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(text.wrappedValue == defaultPrompt)
                        .accessibilityLabel("Reset \(label) to default")
                    }
                }
                SettingsMultilineTextArea(
                    text: text,
                    label: label,
                    placeholder: "Enter cleanup instructions."
                )
            }
        }
    }

    // MARK: - Local filler word removal

    @ViewBuilder
    private func localFillerWordCleanupContent(settings: Settings) -> some View {
        @Bindable var settings = settings

        DSSection(overline: "Local Filler Word Removal") {
            DSStackedRow(
                label: "Remove selected filler words",
                caption: settings.parakeetModelChoice.usesTrueStreaming
                    ? "Runs locally on this Mac before any AI processing — no AI involved. Helpful for streaming models that transcribe filler words literally."
                    : "Runs locally on this Mac before any AI processing — no AI involved. It removes only the editable words listed here.",
                isOn: $settings.isFillerWordRemovalEnabled
            )

            if settings.isFillerWordRemovalEnabled {
                DSDivider()
                cardPadded {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Words:")
                            .font(DS.Fonts.ui(12.5, .medium))
                            .foregroundStyle(DS.Colors.textSecondary)
                        FlowLayout(spacing: 6) {
                            ForEach(settings.fillerWordsToRemove, id: \.self) { word in
                                DSChip(text: word, onRemove: {
                                    settings.fillerWordsToRemove.removeAll { $0 == word }
                                })
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        DSTextField(
                            placeholder: "Add word…", text: $newFillerWord,
                            accessibilityName: "Add filler word"
                        )
                            .frame(width: 220)
                            .onSubmit { addFillerWord() }

                        Button("Add") { addFillerWord() }
                            .buttonStyle(.dsSecondary)
                            .disabled(addableFillerWord == nil)
                            .accessibilityLabel("Add filler word")

                        Spacer(minLength: 0)

                        Button("Reset to Defaults") {
                            settings.fillerWordsToRemove = Settings.defaultFillerWords
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(settings.fillerWordsToRemove == Settings.defaultFillerWords)
                        .accessibilityLabel("Reset filler words to defaults")
                    }
                }
            }
        }
    }

    private func addFillerWord() {
        guard let word = addableFillerWord else { return }
        appState.settings.fillerWordsToRemove.append(word)
        newFillerWord = ""
    }

    private var addableFillerWord: String? {
        let word = newFillerWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !word.isEmpty && !appState.settings.fillerWordsToRemove.contains(word) ? word : nil
    }

    // MARK: - FluidAudio vocabulary

    @ViewBuilder
    private func fluidAudioVocabularyContent(settings: Settings) -> some View {
        if settings.engineChoice != .parakeet || !settings.parakeetModelChoice.supportsFluidAudioVocabulary {
            DSSection(overline: "Vocabulary Correction") {
                DSInfoRow(label: "Status", value: "Requires Parakeet TDT or multilingual Nemotron")
            }
        } else if settings.transcriptPostProcessingMode.supportedFeatures.contains(.customVocabulary) {
            vocabularySection(
                settings: settings,
                footer: settings.parakeetModelChoice == .nemotronMultilingual
                    ? "These terms guide multilingual Nemotron while it recognizes speech, including live previews. Keep the list short and domain-specific for best precision."
                    : "These terms are applied by FluidAudio's vocabulary rescoring on Parakeet TDT final transcripts only. Keep the list short and domain-specific for best precision."
            )
        }
    }

    // MARK: - Apple Intelligence

    @available(macOS 26, *)
    @ViewBuilder
    private func appleIntelligenceContent(settings: Settings) -> some View {
        let availability = AIPostProcessingService.availability
        switch availability {
        case .available:
            @Bindable var settings = settings
            let supportedFeatures = settings.transcriptPostProcessingMode.supportedFeatures

            if supportedFeatures.contains(.customPrompt) {
                cleanupPromptSection(
                    text: $settings.aiPostProcessingPrompt,
                    label: "Apple Intelligence prompt",
                    defaultPrompt: Settings.recommendedAppleIntelligenceCleanupPrompt
                )
            }

            if supportedFeatures.contains(.customVocabulary) {
                vocabularySection(
                    settings: settings,
                    footer: "These terms are applied only by Apple Intelligence post-processing to preserve product names, names, and domain-specific wording."
                )
            }

        case .unavailable(.deviceNotEligible):
            DSSection(overline: "Apple Intelligence") {
                DSInfoRow(label: "Status", value: "Unavailable on this Mac")
            }

        case .unavailable(.appleIntelligenceNotEnabled):
            DSSection(overline: "Apple Intelligence") {
                DSInfoRow(label: "Status") {
                    HStack(spacing: 10) {
                        DSStatusPill(
                            text: "Not enabled",
                            dotColor: DS.Colors.textSecondary,
                            textColor: DS.Colors.textSecondary,
                            fill: DS.Colors.bgInset
                        )
                        Button("Open Settings") {
                            appState.resolveAttentionIssue(.cleanup(.appleIntelligenceNotEnabled))
                        }
                        .buttonStyle(.dsPrimary)
                    }
                }
            }

        case .unavailable(.modelNotReady):
            DSSection(overline: "Apple Intelligence") {
                cardPadded {
                    DSLoadingMessage(text: "Apple Intelligence model is downloading…")
                }
                DSDivider()
                DSCardCaption(text: "The on-device model is being prepared. This may take a few minutes.")
            }

        case .unavailable(_):
            DSSection(overline: "Apple Intelligence") {
                DSInfoRow(label: "Status", value: "Temporarily unavailable")
            }
        }
    }

    // MARK: - S1-mini

    @ViewBuilder
    private func s1MiniContent(settings: Settings) -> some View {
        @Bindable var settings = settings
        let manager = appState.s1MiniModelManager

        DSSection(overline: "S1-mini by Superwhisper") {
            DSInfoRow(label: "Language", value: "English cleanup")
            DSDivider()
            DSInfoRow(label: "Model", value: "462 MB · English · Local transcript normalizer")
            DSDivider()
            DSModelReadinessRow(
                readiness: s1MiniReadiness(manager: manager),
                actionTitle: !manager.isModelDownloaded && !manager.isBusy ? "Download Model"
                    : (appState.canPrepareCleanupEngine ? (appState.cleanupReadiness.detail == nil ? "Prepare Model" : "Retry") : nil),
                action: {
                    if manager.isModelDownloaded {
                        Task { await appState.prepareCleanupEngineIfNeeded(force: true) }
                    } else {
                        downloadS1MiniModel()
                    }
                }
            )
            .disabled(manager.isBusy || appState.status != .idle)
            DSCardCaption(text: "Downloaded means the files are installed. Ready means the model has been loaded and prepared for cleanup.")

            if manager.isDownloading {
                DSCardCaption(text: s1MiniDownloadProgressText(manager: manager))
            }
            if let error = s1MiniActionError ?? manager.lastError {
                DSFieldMessage(text: error, tone: .error)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    .padding(.bottom, 10)
            }
            if manager.isModelDownloaded {
                DSDivider()
                DSInfoRow(label: "Remove the downloaded model files from this Mac.", labelColor: DS.Colors.textSecondary) {
                    Button(manager.isDeleting ? "Deleting…" : "Delete Model…") {
                        isConfirmingS1MiniDeletion = true
                    }
                    .buttonStyle(.dsDestructive)
                    .disabled(manager.isBusy || appState.isPreparingCleanupEngine)
                }
            }
            DSDivider()
            cardPadded {
                Text("Downloads a pinned, integrity-checked copy directly from Hugging Face. Once installed, transcript cleanup runs entirely on this Mac and does not send transcript text to a server. Apple Silicon uses Metal acceleration; Intel uses CPU inference and will be slower.")
                    .font(DS.Fonts.ui(12.5))
                    .lineSpacing(12.5 * 0.5 - 3)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Link(
                    "View the model and its license on Hugging Face",
                    destination: URL(string: "https://huggingface.co/superwhisper/s1-mini")!
                )
                .font(DS.Fonts.ui(12.5, .medium))
                .foregroundStyle(DS.Colors.accent)
            }
        }

        if settings.transcriptPostProcessingMode.supportedFeatures.contains(.s1MiniTrainedControls) {
            DSSection(overline: "Cleanup Controls") {
                if !settings.dictationContextAwarenessEnabled {
                    DSDetailRow(
                        label: "Styling",
                        caption: "Controls how casual or formal the normalized transcript should sound."
                    ) {
                        DSDropdown(
                            selection: $settings.s1MiniStyling,
                            options: S1MiniStyling.allCases,
                            title: \.displayName,
                            accessibilityName: "S1-mini styling"
                        )
                    }
                    DSDivider()
                }
                DSDetailRow(
                    label: "Structure",
                    caption: "Choose prose paragraphs or a list-oriented result."
                ) {
                    DSDropdown(
                        selection: $settings.s1MiniStructure,
                        options: S1MiniStructure.allCases,
                        title: \.displayName,
                        accessibilityName: "S1-mini structure"
                    )
                }
                DSDivider()
                DSDetailRow(
                    label: "Context",
                    caption: "Automatic uses email formatting for email destinations and general formatting elsewhere."
                ) {
                    DSDropdown(
                        selection: $settings.s1MiniContextSetting,
                        options: S1MiniContextSetting.allCases,
                        title: \.displayName,
                        accessibilityName: "S1-mini context"
                    )
                }
                DSDivider()
                DSCardCaption(text:
                    settings.dictationContextAwarenessEnabled
                        ? "Styling is selected by app category below. S1-mini uses only its fixed, trained controls—not an arbitrary prompt or custom vocabulary. Local filler-word removal still runs first."
                        : "S1-mini uses only these fixed, trained controls—not an arbitrary prompt or custom vocabulary. Local filler-word removal still runs first."
                )
            }
        }
    }

    private func s1MiniReadiness(manager: S1MiniModelManager) -> ModelReadiness {
        if manager.isDownloading { return .downloading(s1MiniVisibleDownloadProgress(manager: manager)) }
        if manager.isDeleting { return .deleting }
        if manager.isVerifying { return .verifying }
        return appState.cleanupReadiness
    }

    private func s1MiniVisibleDownloadProgress(manager: S1MiniModelManager) -> Double {
        min(1, manager.downloadProgress / S1MiniDownloadProgress.installationFraction)
    }

    private func s1MiniDownloadProgressText(manager: S1MiniModelManager) -> String {
        guard manager.downloadProgress < S1MiniDownloadProgress.installationFraction else {
            return "Verifying model integrity…"
        }

        let fraction = s1MiniVisibleDownloadProgress(manager: manager)
        let downloadedMiB = Int(Double(S1MiniModelSpec.byteCount) * fraction / 1_048_576)
        let totalMiB = Int(ceil(Double(S1MiniModelSpec.byteCount) / 1_048_576))
        return "\(Int(fraction * 100))% · \(downloadedMiB) of \(totalMiB) MB"
    }

    private func downloadS1MiniModel() {
        s1MiniActionError = nil
        Task {
            do {
                try await appState.s1MiniModelManager.downloadModel()
                await appState.prepareCleanupEngineIfNeeded()
            } catch {
                s1MiniActionError = error.localizedDescription
            }
        }
    }

    // MARK: - Ollama

    @ViewBuilder
    private func ollamaContent(settings: Settings) -> some View {
        @Bindable var settings = settings
        DSSection(overline: "Ollama") {
            if !ollamaCLIAvailability.isAvailable {
                ollamaInstallContent()
                DSDivider()
            }
            fieldRow(label: "Server URL") {
                DSTextField(
                    placeholder: OllamaPostProcessingService.defaultBaseURL,
                    text: Binding(
                        get: { settings.ollamaBaseURL },
                        set: { settings.ollamaBaseURL = $0 }
                    ),
                    accessibilityName: "Ollama server URL"
                )
            }
            DSDivider()
            fieldRow(label: "Model ID") {
                DSTextField(
                    placeholder: "Enter an installed model name",
                    text: Binding(
                        get: { settings.ollamaModel },
                        set: { settings.ollamaModel = $0 }
                    ),
                    accessibilityName: "Ollama model"
                )
            }
            DSDivider()
            cardPadded {
                HStack(alignment: .top, spacing: 12) {
                    ollamaStatusView(settings: settings)
                    Spacer(minLength: 12)
                    Button(isCheckingOllama ? "Checking…" : "Refresh Models") {
                        Task {
                            await refreshOllamaAvailability(settings: settings, debounce: false)
                        }
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(isCheckingOllama)
                }

                if let availability = ollamaAvailability, !availability.installedModels.isEmpty {
                    let installedModels = availability.installedModels

                    Text("Installed Models")
                        .font(DS.Fonts.ui(12, .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)

                    FlowLayout(spacing: 6) {
                        ForEach(installedModels, id: \.self) { (model: String) in
                            let isSelected = settings.ollamaModel == model
                            let isDeleting = appState.ollamaDeletingModel == model
                            let canDelete = ollamaCanDeleteModels
                            let isBusy = appState.ollamaDeletingModel != nil

                            DSChip(
                                text: model,
                                isSelected: isSelected,
                                onSelect: { settings.ollamaModel = model },
                                onRemove: canDelete && !isBusy ? { ollamaPendingDeletionModel = model } : nil
                            )
                            .disabled(isDeleting)
                        }
                    }
                }
            }
            if let error = appState.ollamaModelActionError {
                DSDivider()
                DSFieldMessage(text: error, tone: .error)
                    .padding(.vertical, 10)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
            }
            DSDivider()
            DSCardCaption(text: "Ollama is the provider; the Model ID above selects the cleanup model. Use an installed model trained to preserve names, numbers and meaning. The server URL determines where processing runs.")
        }

        if let capability = ollamaAvailability?.selectedModelReasoningCapability,
           capability.supportsReasoning {
            let canTurnOff = capability == .toggle
            let caption = canTurnOff
                ? "On preserves the model/server recommendation. Off can reduce wait time, but may affect corrections."
                : "This model cannot turn reasoning off. Its model/server recommendation is preserved."
            DSSection(overline: "Cleanup Reasoning") {
                DSDetailRow(label: "Allow reasoning", caption: caption) {
                    DSSwitch(
                        accessibilityName: "Allow Ollama cleanup reasoning",
                        isOn: Binding(
                            get: { !canTurnOff || settings.ollamaReasoningEnabled },
                            set: { settings.ollamaReasoningEnabled = $0 }
                        )
                    )
                    .disabled(!canTurnOff)
                }
            }
        }

        let supportedFeatures = settings.transcriptPostProcessingMode.supportedFeatures
        if supportedFeatures.contains(.customPrompt) {
            cleanupPromptSection(
                text: $settings.ollamaPostProcessingPrompt,
                label: "Ollama prompt",
                defaultPrompt: Settings.recommendedTranscriptCleanupPrompt
            )
        }

        if supportedFeatures.contains(.customVocabulary) {
            vocabularySection(
                settings: settings,
                footer: "These terms are sent to Ollama to preserve product names, names, and domain-specific wording during post-processing."
            )
        }
    }

    // MARK: - OpenRouter

    @ViewBuilder
    private func openRouterContent(settings: Settings) -> some View {
        @Bindable var settings = settings
        DSSection(overline: "OpenRouter") {
            fieldRow(label: "API key") {
                DSTextField(
                    placeholder: "Paste OpenRouter API key",
                    text: Binding(
                        get: { settings.openRouterAPIKey },
                        set: { settings.openRouterAPIKey = $0 }
                    ),
                    isSecure: true,
                    accessibilityName: "OpenRouter API key"
                )
            }
            if let error = settings.openRouterAPIKeyError {
                DSFieldMessage(text: error, tone: .error)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    .padding(.bottom, 10)
            }
            DSDivider()
            fieldRow(label: "API key variable (optional)") {
                DSTextField(
                    placeholder: OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable,
                    text: Binding(
                        get: { settings.openRouterAPIKeyEnvironmentVariable },
                        set: { settings.openRouterAPIKeyEnvironmentVariable = $0 }
                    ),
                    accessibilityName: "OpenRouter API key environment variable"
                )
            }
            DSDivider()
            fieldRow(label: "Model ID") {
                DSTextField(
                    placeholder: "openai/gpt-5-mini",
                    text: Binding(
                        get: { settings.openRouterModel },
                        set: { settings.openRouterModel = $0 }
                    ),
                    accessibilityName: "OpenRouter model"
                )
            }
            DSDivider()
            cardPadded {
                HStack(alignment: .top, spacing: 12) {
                    openRouterStatusView(settings: settings)
                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button(isCheckingOpenRouter ? "Checking…" : "Refresh Models") {
                            Task {
                                await refreshOpenRouterAvailability(settings: settings, debounce: false)
                            }
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(isCheckingOpenRouter)

                        Button("Browse Models") {
                            guard let url = URL(string: "https://openrouter.ai/models") else { return }
                            NSWorkspace.shared.open(url)
                        }
                        .buttonStyle(.dsSecondary)

                        if !settings.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear Stored Key") {
                                settings.openRouterAPIKey = ""
                            }
                            .buttonStyle(.dsDestructive)
                        }
                    }
                }
            }
            DSDivider()
            DSCardCaption(text: "Runs transcript cleanup through OpenRouter's cloud API. Paste a key directly to store it in Keychain, or leave the API key field blank and use the optional environment variable setting instead.")
        }

        if let availability = openRouterAvailability {
            openRouterModelSearchSection(settings: settings, availability: availability)
        }

        if let reasoning = OpenRouterPostProcessingService.reasoningCapabilities(
            for: currentOpenRouterModel(settings: settings), in: openRouterAvailability
        ), reasoning.canDisableReasoning || reasoning.mandatory == true {
            DSSection(overline: "Cleanup Reasoning") {
                DSDetailRow(
                    label: "Allow reasoning",
                    caption: reasoning.mandatory == true
                        ? "This model requires reasoning, so it cannot be turned off."
                        : "On preserves the provider's recommended reasoning setting and effort. Off can reduce wait time, but may affect corrections."
                ) {
                    DSSwitch(
                        accessibilityName: "Allow OpenRouter cleanup reasoning",
                        isOn: Binding(
                            get: { reasoning.mandatory == true || settings.openRouterReasoningEnabled },
                            set: { settings.openRouterReasoningEnabled = $0 }
                        )
                    )
                    .disabled(reasoning.mandatory == true)
                }
            }
        }

        let supportedFeatures = settings.transcriptPostProcessingMode.supportedFeatures
        if supportedFeatures.contains(.customPrompt) {
            cleanupPromptSection(
                text: $settings.openRouterPostProcessingPrompt,
                label: "OpenRouter prompt",
                defaultPrompt: Settings.recommendedTranscriptCleanupPrompt
            )
        }

        if supportedFeatures.contains(.customVocabulary) {
            vocabularySection(
                settings: settings,
                footer: "These terms are sent to OpenRouter to preserve product names, names, and domain-specific wording during post-processing."
            )
        }
    }

    // MARK: - OpenAI Compatible

    @ViewBuilder
    private func openAICompatibleContent(settings: Settings) -> some View {
        @Bindable var settings = settings
        DSSection(overline: "OpenAI Compatible") {
            fieldRow(label: "Server URL") {
                DSTextField(
                    placeholder: OpenAICompatiblePostProcessingService.defaultBaseURL,
                    text: Binding(
                        get: { settings.openAICompatibleBaseURL },
                        set: { settings.openAICompatibleBaseURL = $0 }
                    ),
                    accessibilityName: "OpenAI-compatible server URL"
                )
            }
            DSDivider()
            fieldRow(label: "API key (optional)") {
                DSTextField(
                    placeholder: "Leave blank for local servers without auth",
                    text: Binding(
                        get: { settings.openAICompatibleAPIKey },
                        set: { settings.openAICompatibleAPIKey = $0 }
                    ),
                    isSecure: true,
                    accessibilityName: "OpenAI-compatible API key"
                )
            }
            if let error = settings.openAICompatibleAPIKeyError {
                DSFieldMessage(text: error, tone: .error)
                    .padding(.horizontal, DS.Spacing.rowHorizontal)
                    .padding(.bottom, 10)
            }
            DSDivider()
            fieldRow(label: "Model ID") {
                DSTextField(
                    placeholder: "local-model",
                    text: Binding(
                        get: { settings.openAICompatibleModel },
                        set: { settings.openAICompatibleModel = $0 }
                    ),
                    accessibilityName: "OpenAI-compatible model"
                )
            }
            DSDivider()
            cardPadded {
                HStack(alignment: .top, spacing: 12) {
                    openAICompatibleStatusView(settings: settings)
                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        Button(isCheckingOpenAICompatible ? "Checking…" : "Refresh Models") {
                            Task {
                                await refreshOpenAICompatibleAvailability(settings: settings, debounce: false)
                            }
                        }
                        .buttonStyle(.dsSecondary)
                        .disabled(isCheckingOpenAICompatible)

                        if !settings.openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear Stored Key") {
                                settings.openAICompatibleAPIKey = ""
                            }
                            .buttonStyle(.dsDestructive)
                        }
                    }
                }

                if let availability = openAICompatibleAvailability, !availability.models.isEmpty {
                    Text("Available Models")
                        .font(DS.Fonts.ui(12, .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)

                    FlowLayout(spacing: 6) {
                        ForEach(availability.models, id: \.self) { model in
                            let isSelected = settings.openAICompatibleModel.caseInsensitiveCompare(model) == .orderedSame
                            DSChip(
                                text: model,
                                isSelected: isSelected,
                                onSelect: { settings.openAICompatibleModel = model }
                            )
                        }
                    }
                }
            }
            DSDivider()
            DSCardCaption(text: "Runs transcript cleanup through a local or self-hosted OpenAI-compatible chat completions server, such as LM Studio, llama.cpp, vLLM, or LocalAI. Use the base URL and model name reported by that server.")
        }

        let supportedFeatures = settings.transcriptPostProcessingMode.supportedFeatures
        if supportedFeatures.contains(.customPrompt) {
            cleanupPromptSection(
                text: $settings.openAICompatiblePostProcessingPrompt,
                label: "OpenAI-compatible prompt",
                defaultPrompt: Settings.recommendedTranscriptCleanupPrompt
            )
        }

        if supportedFeatures.contains(.customVocabulary) {
            vocabularySection(
                settings: settings,
                footer: "These terms are sent to the OpenAI-compatible server to preserve product names, names, and domain-specific wording during post-processing."
            )
        }
    }

    // MARK: - Ollama install prompt

    /// Shown as the first row of the Ollama section when the CLI is missing,
    /// so the blocker and the server fields it blocks stay together.
    @ViewBuilder
    private func ollamaInstallContent() -> some View {
        cardPadded {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(DS.Colors.accent)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Not installed")
                        .font(DS.Fonts.ui(13.5, .semibold))
                        .foregroundStyle(DS.Colors.ink)
                    Text("Local models · Free · Runs on this Mac")
                        .font(DS.Fonts.ui(12.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                }

                Spacer(minLength: 12)

                Button {
                    guard let url = URL(string: "https://ollama.com/download") else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Download Ollama", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.dsPrimary)
            }

            Text("Install Ollama to run your own cleanup model. Choose an installed model by its exact ID. You can also leave it uninstalled and point the server URL below at a remote Ollama server.")
                .font(DS.Fonts.ui(12.5))
                .lineSpacing(12.5 * 0.5 - 3)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Vocabulary

    @ViewBuilder
    private func vocabularySection(settings: Settings, footer: String) -> some View {
        @Bindable var settings = settings
        CustomVocabularySection(terms: $settings.customVocabulary, footer: footer)
    }

    // MARK: - OpenRouter helpers

    private func currentOpenRouterModel(settings: Settings) -> String {
        settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openRouterMatchingModels(
        settings: Settings,
        availability: OpenRouterPostProcessingService.Availability
    ) -> [OpenRouterModelMatch] {
        let query = currentOpenRouterModel(settings: settings)
        guard !query.isEmpty else { return [] }

        let catalogLookupQuery = OpenRouterPostProcessingService.catalogLookupModelID(for: query)
        let normalizedQuery = catalogLookupQuery.lowercased()
        let exactMatch = normalizedQuery

        return availability.models
            .filter { $0.id.lowercased().contains(normalizedQuery) }
            .sorted { lhs, rhs in
                let lhsExact = lhs.id.lowercased() == exactMatch
                let rhsExact = rhs.id.lowercased() == exactMatch
                if lhsExact != rhsExact {
                    return lhsExact && !rhsExact
                }

                let lhsPrefix = lhs.id.lowercased().hasPrefix(normalizedQuery)
                let rhsPrefix = rhs.id.lowercased().hasPrefix(normalizedQuery)
                if lhsPrefix != rhsPrefix {
                    return lhsPrefix && !rhsPrefix
                }

                if lhs.supportsStructuredOutputs != rhs.supportsStructuredOutputs {
                    return lhs.supportsStructuredOutputs && !rhs.supportsStructuredOutputs
                }

                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
            .prefix(12)
            .map {
                OpenRouterModelMatch(
                    id: $0.id,
                    supportsStructuredOutputs: $0.supportsStructuredOutputs,
                    supportsAudioInput: $0.supportsAudioInput
                )
            }
    }

    private func openRouterModelSearchEmptyState(settings: Settings) -> String {
        let query = currentOpenRouterModel(settings: settings)
        if query.isEmpty {
            return "Type part of a model id to filter the fetched OpenRouter catalog, or use Browse Models to pick one from openrouter.ai."
        }
        return "No fetched OpenRouter models matched \(query). Try a broader search term or browse the full model directory."
    }

    private func openRouterModelSearchFooter(
        availability: OpenRouterPostProcessingService.Availability
    ) -> String {
        let structuredCount = availability.models.filter(\.supportsStructuredOutputs).count
        let audioInputCount = availability.models.filter(\.supportsAudioInput).count
        return "Fetched \(availability.models.count) OpenRouter models. \(structuredCount) currently advertise structured output support and \(audioInputCount) advertise audio input support."
    }

    private func openRouterModelSearchSection(
        settings: Settings,
        availability: OpenRouterPostProcessingService.Availability
    ) -> some View {
        let matchingModels: [OpenRouterModelMatch] = openRouterMatchingModels(
            settings: settings,
            availability: availability
        )

        return DSSection(overline: "Model Search") {
            if matchingModels.isEmpty {
                DSCardCaption(text: openRouterModelSearchEmptyState(settings: settings))
            } else {
                cardPadded {
                    OpenRouterModelMatchesView(
                        models: matchingModels,
                        selectedModel: currentOpenRouterModel(settings: settings)
                    ) { modelID in
                        settings.openRouterModel = modelID
                    }
                }
            }
            DSDivider()
            DSCardCaption(text: openRouterModelSearchFooter(availability: availability))
        }
    }

    private var ollamaCanDeleteModels: Bool {
        ollamaCLIAvailability.isAvailable
    }

    // MARK: - Status views

    @ViewBuilder
    private func ollamaStatusView(settings: Settings) -> some View {
        if isCheckingOllama {
            DSLoadingMessage(text: "Checking Ollama…")
        } else if let message = ollamaStatusMessage {
            DSFieldMessage(text: message, tone: .error)
        } else if let availability = ollamaAvailability {
            if availability.installedModels.isEmpty {
                DSFieldMessage(text:
                    "Connected, but no Ollama models are installed yet.",
                    tone: .warning
                )
            } else if availability.selectedModel.isEmpty {
                DSFieldMessage(text:
                    "Connected. Choose an installed model below or enter one manually.",
                    tone: .success
                )
            } else if availability.selectedModelIsInstalled {
                DSFieldMessage(text:
                    "Connected. \(availability.resolvedSelectedModel ?? availability.selectedModel) is available.",
                    tone: .success
                )
            } else {
                DSFieldMessage(text:
                    "Connected, but \(availability.selectedModel) is not installed on this Ollama server.",
                    tone: .warning
                )
            }
        } else {
            DSFieldMessage(text:
                "Enter your Ollama server URL to check connectivity.",
                tone: .info
            )
        }
    }

    @ViewBuilder
    private func openRouterStatusView(settings: Settings) -> some View {
        let apiKeyStatus = OpenRouterPostProcessingService.apiKeyStatus(
            apiKey: settings.openRouterAPIKey,
            apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
        )
        let selectedModel = currentOpenRouterModel(settings: settings)
        let resolvedModel = OpenRouterPostProcessingService.matchingAvailableModel(
            for: selectedModel,
            in: openRouterAvailability
        )

        if isCheckingOpenRouter {
            DSLoadingMessage(text: "Checking OpenRouter…")
        } else if let message = openRouterStatusMessage {
            DSFieldMessage(text: message, tone: .error)
        } else if case .missing = apiKeyStatus.source {
            DSFieldMessage(text:
                "No OpenRouter API key is configured yet. Paste one above or set \(apiKeyStatus.environmentVariableName) in the app environment.",
                tone: .warning
            )
        } else if let resolvedModel {
            DSFieldMessage(text:
                openRouterAvailableModelStatusMessage(
                    selectedModel: selectedModel,
                    resolvedModel: resolvedModel,
                    apiKeyStatus: apiKeyStatus
                ),
                tone: resolvedModel.supportsStructuredOutputs ? .success : .warning
            )
        } else if !selectedModel.isEmpty {
            DSFieldMessage(text:
                "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(selectedModel) was not found in the latest OpenRouter model refresh.",
                tone: .warning
            )
        } else if openRouterAvailability != nil {
            DSFieldMessage(text:
                "\(openRouterCredentialSourceMessage(apiKeyStatus)) Enter a model id above or search the fetched catalog below.",
                tone: .success
            )
        } else {
            DSFieldMessage(text:
                "Refresh models to validate your OpenRouter setup and search the available catalog.",
                tone: .info
            )
        }
    }

    private func openRouterAvailableModelStatusMessage(
        selectedModel: String,
        resolvedModel model: OpenRouterPostProcessingService.Model,
        apiKeyStatus: OpenRouterPostProcessingService.APIKeyStatus
    ) -> String {
        let selectedCatalogLookupModel = OpenRouterPostProcessingService.catalogLookupModelID(for: selectedModel)
        let usesDynamicVariant = !selectedModel.isEmpty
            && selectedModel.caseInsensitiveCompare(model.id) != .orderedSame
            && selectedCatalogLookupModel.caseInsensitiveCompare(model.id) == .orderedSame
        let modelReference: String

        if usesDynamicVariant {
            modelReference = "\(selectedModel) is valid on OpenRouter and uses the \(model.id) catalog entry"
        } else {
            modelReference = "\(model.id) is available on OpenRouter"
        }

        if model.supportsStructuredOutputs {
            if model.supportsAudioInput {
                return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), which advertises both structured output and audio input support."
            }
            return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), which advertises structured output support."
        }
        if model.supportsAudioInput {
            return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), which advertises audio input support, but it does not advertise structured outputs. Dictate Anywhere will fall back to prompt-based JSON parsing if needed."
        }
        return "\(openRouterCredentialSourceMessage(apiKeyStatus)) \(modelReference), but it does not advertise structured outputs. Dictate Anywhere will fall back to prompt-based JSON parsing if needed."
    }

    private func openRouterCredentialSourceMessage(
        _ apiKeyStatus: OpenRouterPostProcessingService.APIKeyStatus
    ) -> String {
        switch apiKeyStatus.source {
        case .storedKey:
            return "OpenRouter API key is stored securely in Keychain."
        case .inlineValue:
            return "OpenRouter API key was pasted directly into the environment variable field."
        case .environmentVariable:
            return "OpenRouter API key was loaded from \(apiKeyStatus.environmentVariableName)."
        case .missing:
            return "No OpenRouter API key is configured."
        }
    }

    @ViewBuilder
    private func openAICompatibleStatusView(settings: Settings) -> some View {
        let selectedModel = settings.openAICompatibleModel.trimmingCharacters(in: .whitespacesAndNewlines)

        if isCheckingOpenAICompatible {
            DSLoadingMessage(text: "Checking server…")
        } else if let message = openAICompatibleStatusMessage {
            DSFieldMessage(text: message, tone: .error)
        } else if let availability = openAICompatibleAvailability {
            if availability.models.isEmpty {
                DSFieldMessage(text:
                    "Connected, but the server did not report any models.",
                    tone: .warning
                )
            } else if selectedModel.isEmpty {
                DSFieldMessage(text:
                    "Connected. Choose a model below or enter one manually.",
                    tone: .success
                )
            } else if availability.selectedModelIsAvailable {
                DSFieldMessage(text:
                    "Connected. \(selectedModel) is available.",
                    tone: .success
                )
            } else {
                DSFieldMessage(text:
                    "Connected, but \(selectedModel) was not listed by this server.",
                    tone: .warning
                )
            }
        } else {
            DSFieldMessage(text:
                "Enter a server URL and refresh models to check connectivity.",
                tone: .info
            )
        }
    }

    // MARK: - Availability refresh

    static func providerTaskID(settings: Settings, ollamaModelActionsRevision: Int) -> String {
        [
            settings.transcriptPostProcessingMode.rawValue,
            settings.ollamaBaseURL,
            settings.ollamaModel,
            String(settings.openRouterCredentialsRevision),
            settings.openAICompatibleBaseURL,
            settings.openAICompatibleModel,
            String(settings.openAICompatibleCredentialsRevision),
            String(ollamaModelActionsRevision),
        ].joined(separator: "|")
    }

    private func refreshProviderAvailabilityIfNeeded(settings: Settings) async {
        switch settings.transcriptPostProcessingMode {
        case .ollama:
            resetOpenRouterAvailability()
            resetOpenAICompatibleAvailability()
            await refreshOllamaAvailability(settings: settings, debounce: true)
        case .openRouter:
            resetOllamaAvailability()
            resetOpenAICompatibleAvailability()
            await refreshOpenRouterAvailability(settings: settings, debounce: true)
        case .openAICompatible:
            resetOllamaAvailability()
            resetOpenRouterAvailability()
            await refreshOpenAICompatibleAvailability(settings: settings, debounce: true)
        case .none, .fluidAudioVocabulary, .appleIntelligence, .s1Mini:
            resetOllamaAvailability()
            resetOpenRouterAvailability()
            resetOpenAICompatibleAvailability()
        }
    }

    private func refreshOllamaAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .ollama else {
            resetOllamaAvailability()
            return
        }

        let checkID = UUID()
        ollamaCheckID = checkID
        isCheckingOllama = true
        defer {
            if ollamaCheckID == checkID {
                isCheckingOllama = false
                ollamaCheckID = nil
            }
        }

        if debounce {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }

        let baseURL = settings.ollamaBaseURL
        let model = settings.ollamaModel

        ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
        do {
            let availability = try await OllamaPostProcessingService.availability(
                baseURL: baseURL,
                selectedModel: model
            )
            guard !Task.isCancelled, ollamaCheckID == checkID else { return }
            ollamaAvailability = availability
            ollamaStatusMessage = nil
        } catch {
            guard !Task.isCancelled, ollamaCheckID == checkID else { return }
            ollamaAvailability = nil
            ollamaStatusMessage = error.localizedDescription
        }
    }

    private func refreshOpenRouterAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .openRouter else {
            resetOpenRouterAvailability()
            return
        }

        let checkID = UUID()
        openRouterCheckID = checkID
        isCheckingOpenRouter = true
        defer {
            if openRouterCheckID == checkID {
                isCheckingOpenRouter = false
                openRouterCheckID = nil
            }
        }

        if debounce {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }

        do {
            let availability = try await OpenRouterPostProcessingService.availability(
                apiKey: settings.openRouterAPIKey,
                apiKeyEnvironmentVariable: settings.openRouterAPIKeyEnvironmentVariable
            )
            guard !Task.isCancelled, openRouterCheckID == checkID else { return }
            openRouterAvailability = availability
            openRouterStatusMessage = nil
        } catch {
            guard !Task.isCancelled, openRouterCheckID == checkID else { return }
            openRouterAvailability = nil
            openRouterStatusMessage = error.localizedDescription
        }
    }

    private func refreshOpenAICompatibleAvailability(settings: Settings, debounce: Bool) async {
        guard settings.transcriptPostProcessingMode == .openAICompatible else {
            resetOpenAICompatibleAvailability()
            return
        }

        let checkID = UUID()
        openAICompatibleCheckID = checkID
        isCheckingOpenAICompatible = true
        defer {
            if openAICompatibleCheckID == checkID {
                isCheckingOpenAICompatible = false
                openAICompatibleCheckID = nil
            }
        }

        if debounce {
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
        }

        do {
            let availability = try await OpenAICompatiblePostProcessingService.availability(
                baseURL: settings.openAICompatibleBaseURL,
                apiKey: settings.openAICompatibleAPIKey,
                selectedModel: settings.openAICompatibleModel
            )
            guard !Task.isCancelled, openAICompatibleCheckID == checkID else { return }
            openAICompatibleAvailability = availability
            openAICompatibleStatusMessage = nil
        } catch {
            guard !Task.isCancelled, openAICompatibleCheckID == checkID else { return }
            openAICompatibleAvailability = nil
            openAICompatibleStatusMessage = error.localizedDescription
        }
    }

    private func resetOllamaAvailability() {
        ollamaCheckID = nil
        isCheckingOllama = false
        ollamaAvailability = nil
        ollamaCLIAvailability = OllamaPostProcessingService.cliAvailability()
        ollamaStatusMessage = nil
    }

    private func resetOpenRouterAvailability() {
        openRouterCheckID = nil
        isCheckingOpenRouter = false
        openRouterAvailability = nil
        openRouterStatusMessage = nil
    }

    private func resetOpenAICompatibleAvailability() {
        openAICompatibleCheckID = nil
        isCheckingOpenAICompatible = false
        openAICompatibleAvailability = nil
        openAICompatibleStatusMessage = nil
    }

}

private struct OpenRouterModelMatch: Identifiable, Hashable {
    let id: String
    let supportsStructuredOutputs: Bool
    let supportsAudioInput: Bool
}

private struct OpenRouterModelMatchesView: View {
    let models: [OpenRouterModelMatch]
    let selectedModel: String
    let onSelect: (String) -> Void

    var body: some View {
        SwiftUI.ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
            let isSelected = selectedModel.caseInsensitiveCompare(model.id) == .orderedSame

            if index > 0 {
                DSDivider()
            }
            Button {
                onSelect(model.id)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.id)
                            .font(DS.Fonts.ui(13))
                            .foregroundStyle(DS.Colors.ink)
                            .multilineTextAlignment(.leading)

                        if !model.supportsStructuredOutputs {
                            Text("Prompt-only fallback")
                                .font(DS.Fonts.ui(12))
                                .foregroundStyle(DS.Colors.textSecondary)
                        }

                        if model.supportsAudioInput {
                            Text("Audio input available")
                                .font(DS.Fonts.ui(12))
                                .foregroundStyle(DS.Colors.textSecondary)
                        }
                    }

                    Spacer(minLength: 12)

                    if isSelected {
                        Text("Selected")
                            .font(DS.Fonts.ui(12, .semibold))
                            .foregroundStyle(DS.Colors.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(model.id)")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}

#if DEBUG
@MainActor
private struct AIPostProcessingViewPreviewHost: View {
    @State private var appState: AppState
    private let cliAvailability: OllamaPostProcessingService.CLIAvailability

    init(cliAvailability: OllamaPostProcessingService.CLIAvailability) {
        self.cliAvailability = cliAvailability

        let appState = AppState()
        appState.settings.transcriptPostProcessingMode = .ollama
        appState.settings.ollamaBaseURL = OllamaPostProcessingService.defaultBaseURL
        appState.settings.ollamaModel = ""
        appState.settings.ollamaPostProcessingPrompt = Settings.recommendedTranscriptCleanupPrompt
        appState.settings.customVocabulary = ["Dictate Anywhere", "Parakeet", "Ollama"]
        _appState = State(initialValue: appState)
    }

    var body: some View {
        NavigationStack {
            AIPostProcessingView(
                initialOllamaCLIAvailability: cliAvailability,
                shouldAutoRefreshProviderAvailability: false
            )
        }
        .environment(appState)
        .frame(width: 760, height: 920)
    }
}

#Preview("Ollama Not Installed") {
    AIPostProcessingViewPreviewHost(
        cliAvailability: .init(executablePath: nil)
    )
}
#endif
