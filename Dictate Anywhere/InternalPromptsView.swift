//
//  InternalPromptsView.swift
//  Dictate Anywhere
//
//  Provider-specific prompt customization using the shared settings design system.
//

import SwiftUI

struct InternalPromptsView: View {
    @Environment(AppState.self) private var appState

    private let recognitionPrompts: [AssemblyAIInternalPrompt] = [
        .recognitionContext,
        .recognitionContextWithApp,
    ]
    private let cleanupPrompts: [AssemblyAIInternalPrompt] = [.baseCleanup]
    private let destinationPrompts: [AssemblyAIInternalPrompt] = [
        .email,
        .workMessaging,
        .personalMessaging,
        .other,
    ]
    private let stylePrompts: [AssemblyAIInternalPrompt] = [
        .formal,
        .neutral,
        .casual,
        .veryCasual,
        .excited,
        .original,
    ]
    private let fieldContextPrompts: [AssemblyAIInternalPrompt] = [
        .midSentence,
        .searchQuery,
    ]

    var body: some View {
        @Bindable var settings = appState.settings

        DSPage {
            DSSectionHeader(
                title: "Customize Internal Prompts",
                subtitle: settings.assemblyAIOutputMode == .polished
                    ? "Fine-tune the instructions AssemblyAI uses to recognize, clean, and format your dictation."
                    : "Fine-tune the context AssemblyAI uses to recognize your dictation."
            )

            DSHint(
                text: settings.assemblyAIOutputMode == .polished
                    ? "Recognition prompts are always used. Cleanup, destination, style, and field-context prompts apply to polished output. Insertion and privacy safeguards remain protected. Keep prompts concise: applicable preferences share a limited instruction budget and long prompts may be shortened."
                    : "Recognition context helps AssemblyAI identify words accurately. Keep prompts focused on the subject and terminology of your dictation."
            )

            if settings.assemblyAIOutputMode == .polished {
                DSSection(overline: "Cleanup") {
                    promptRows(cleanupPrompts, settings: settings)
                    DSDivider()
                    additionalInstructionsEditor(settings: settings)
                }

                promptSection(
                    overline: "Destination Type",
                    prompts: destinationPrompts,
                    settings: settings
                )

                promptSection(
                    overline: "Writing Style",
                    prompts: stylePrompts,
                    settings: settings
                )

                promptSection(
                    overline: "Field Context",
                    prompts: fieldContextPrompts,
                    settings: settings
                )
            }

            promptSection(
                overline: "Recognition Context",
                prompts: recognitionPrompts,
                settings: settings
            )

            DSHint(
                text: "Reset to Default is available only when Dictate Anywhere includes a built-in prompt. Empty prompts send no extra rule for that case."
            )
        }
    }

    private func promptSection(
        overline: String,
        prompts: [AssemblyAIInternalPrompt],
        settings: Settings
    ) -> some View {
        DSSection(overline: overline) {
            promptRows(prompts, settings: settings)
        }
    }

    @ViewBuilder
    private func promptRows(
        _ prompts: [AssemblyAIInternalPrompt],
        settings: Settings
    ) -> some View {
        ForEach(prompts) { prompt in
            promptEditor(prompt, settings: settings)
            if prompt != prompts.last {
                DSDivider()
            }
        }
    }

    private func promptEditor(
        _ prompt: AssemblyAIInternalPrompt,
        settings: Settings
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(DS.Fonts.ui(13.5, .medium))
                        .foregroundStyle(DS.Colors.ink)
                    Text(prompt.caption)
                        .font(DS.Fonts.ui(12.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if prompt.hasBuiltInDefault {
                    Button("Reset to Default") {
                        settings.resetAssemblyAIPrompt(prompt)
                    }
                    .buttonStyle(.dsSecondary)
                    .disabled(!settings.isAssemblyAIPromptCustomized(prompt))
                    .accessibilityLabel("Reset \(prompt.title) to Default")
                }
            }

            SettingsMultilineTextArea(
                text: Binding(
                    get: { settings.assemblyAIPrompt(prompt) },
                    set: { settings.setAssemblyAIPrompt($0, for: prompt) }
                ),
                label: prompt.title,
                placeholder: "No instructions will be sent.",
                minHeight: prompt.minimumEditorHeight
            )
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }

    private func additionalInstructionsEditor(settings: Settings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Additional instructions")
                        .font(DS.Fonts.ui(13.5, .medium))
                        .foregroundStyle(DS.Colors.ink)
                    Text("Your personal formatting or tone preferences, appended to every polished request.")
                        .font(DS.Fonts.ui(12.5))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsMultilineTextArea(
                text: Binding(
                    get: { settings.assemblyAIInstruction },
                    set: { settings.assemblyAIInstruction = String($0.prefix(4_000)) }
                ),
                label: "Additional instructions",
                placeholder: "For example: Keep responses concise and format action items as bullets."
            )
            Text("\(settings.assemblyAIInstruction.count) of 4,000 characters")
                .font(DS.Fonts.ui(11.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .accessibilityLabel("Additional instructions: \(settings.assemblyAIInstruction.count) of 4,000 characters")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, DS.Spacing.rowHorizontal)
    }
}

private extension AssemblyAIInternalPrompt {
    var title: String {
        switch self {
        case .recognitionContext: return "General recognition"
        case .recognitionContextWithApp: return "Recognition with app context"
        case .baseCleanup: return "Base cleanup"
        case .email: return "Email"
        case .workMessaging: return "Work messaging"
        case .personalMessaging: return "Personal messaging"
        case .other: return "Other writing"
        case .formal: return "Formal"
        case .neutral: return "Neutral"
        case .casual: return "Casual"
        case .veryCasual: return "Very Casual"
        case .excited: return "Excited"
        case .original: return "Original tone"
        case .midSentence: return "Mid-sentence insertion"
        case .searchQuery: return "Search field"
        }
    }

    var caption: String {
        switch self {
        case .recognitionContext:
            return "Used without remote app-detail sharing. Available placeholder: {category}."
        case .recognitionContextWithApp:
            return "Used when app-detail sharing is enabled. Available placeholders: {category} and {app}."
        case .baseCleanup:
            return "General cleanup preferences included in every polished request."
        case .email:
            return "Formatting added when the destination is classified as email."
        case .workMessaging:
            return "Formatting added for workplace chat and messaging apps."
        case .personalMessaging:
            return "Formatting added for personal chat and messaging apps."
        case .other:
            return "Extra formatting for destinations outside the recognized categories. Empty by default."
        case .formal, .neutral, .casual, .veryCasual, .excited, .original:
            return "Applied whenever this writing style is selected for the destination."
        case .midSentence:
            return "Protects capitalization and punctuation when inserting into an existing sentence."
        case .searchQuery:
            return "Keeps text concise when the focused field is recognized as search."
        }
    }

    var minimumEditorHeight: CGFloat {
        switch self {
        case .email: return 150
        case .midSentence, .searchQuery: return 110
        default: return 80
        }
    }
}
