import SwiftUI

/// Distinguishes packaged models from acoustic correction and custom providers.
struct CleanupMethodMenu: View {
    @Binding var selection: TranscriptPostProcessingMode
    let offersVocabulary: Bool

    var body: some View {
        Menu {
            Section("On this Mac") {
                option(.none)
                option(.s1Mini)
                option(.appleIntelligence)
            }
            if offersVocabulary {
                Section("Recognition correction") { option(.fluidAudioVocabulary) }
            }
            Section("Custom model") {
                option(.ollama)
                option(.openRouter)
                option(.openAICompatible)
            }
        } label: {
            DSDropdownLabel(text: title(selection))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Transcript processing method")
        .accessibilityValue(title(selection))
    }

    private func title(_ mode: TranscriptPostProcessingMode) -> String {
        switch mode {
        case .none: return "Off"
        case .s1Mini: return "S1-mini — English"
        case .appleIntelligence: return "Apple Intelligence"
        case .fluidAudioVocabulary: return "Vocabulary correction only"
        case .ollama: return "Custom: Ollama"
        case .openRouter: return "Custom: OpenRouter"
        case .openAICompatible: return "Custom: OpenAI-compatible"
        }
    }

    private func option(_ mode: TranscriptPostProcessingMode) -> some View {
        Button { selection = mode } label: {
            if mode == selection {
                Label(title(mode), systemImage: "checkmark")
            } else {
                Text(title(mode))
            }
        }
    }
}
