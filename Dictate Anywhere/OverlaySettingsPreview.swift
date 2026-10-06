import SwiftUI

/// Uses the floating overlay itself so settings always show the shipped design.
struct OverlaySettingsPreview: View {
    let settings: Settings
    @State private var model = Self.makeSample()

    var body: some View {
        VStack(spacing: 14) {
            OverlayContent(model: model, settings: settings)
                .environment(\.colorScheme, settings.overlayThemeMode.overlayColorScheme)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Example dictation preview")
            Text(settings.showTextPreview ? "Your words, as you speak" : "Just your voice, in motion")
                .font(DS.Fonts.ui(12))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
        .background(DS.Colors.overlayPreviewFill)
    }

    private static func makeSample() -> OverlayModel {
        let model = OverlayModel()
        model.updateListening(level: 0.35, transcript: "A little more room for your train of thought.")
        model.isVisible = true
        return model
    }
}
