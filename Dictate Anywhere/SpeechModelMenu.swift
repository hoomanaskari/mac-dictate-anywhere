import SwiftUI

/// Language-aware catalog; export presets are configured after selecting a model.
struct SpeechModelMenu: View {
    @Binding var selection: ParakeetModelChoice
    let language: SupportedLanguage
    let isEnabled: Bool

    private var recommended: [ParakeetModelChoice] {
        ParakeetModelChoice.recommendedCatalogChoices(
            for: language, hasNeuralEngine: Hardware.canUseAppleNeuralEngine)
    }

    private var alternatives: [ParakeetModelChoice] {
        ParakeetModelChoice.compatibleCatalogChoices(
            for: language, hasNeuralEngine: Hardware.canUseAppleNeuralEngine
        ).filter { !recommended.contains($0) }
    }

    var body: some View {
        Menu {
            if !recommended.isEmpty {
                Section("Recommended for \(language.displayName)") {
                    ForEach(recommended, id: \.self) { option($0) }
                }
            }
            if !alternatives.isEmpty {
                Section("Alternatives") {
                    ForEach(alternatives, id: \.self) { option($0) }
                }
            }
        } label: {
            DSDropdownLabel(text: selection.displayName)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(!isEnabled || (recommended.isEmpty && alternatives.isEmpty))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel("Speech model")
        .accessibilityValue("\(selection.displayName), \(purpose(selection)), \(selection.sizeSummary)")
    }

    private func option(_ model: ParakeetModelChoice) -> some View {
        Button {
            selection = model.selectionPreservingPreset(selection)
        } label: {
            let title = "\(model.displayName) — \(purpose(model)) · \(model.sizeSummary)"
            if selection.catalogChoice == model {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func purpose(_ model: ParakeetModelChoice) -> String {
        model.hasLimitedLanguageCoverage(language)
            ? "Limited coverage for \(language.displayName)" : model.recommendationTitle
    }
}
