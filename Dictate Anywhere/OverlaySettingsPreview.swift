import SwiftUI

/// Uses the floating overlay itself so settings always show the shipped design.
struct OverlaySettingsPreview: View {
    let settings: Settings
    @State private var model = Self.makeSample()
    @State private var replay = 0
    @State private var isPlaying = false
    private static let sampleText = "A little more room for your train of thought, so a quick glance shows exactly what was heard."

    var body: some View {
        VStack(spacing: 14) {
            OverlayPill(model: model, settings: settings)
                // Reserve room for every preset so the slider stays put while resizing.
                .frame(height: OverlaySize.large.height)
                .environment(\.colorScheme, settings.overlayThemeMode.overlayColorScheme)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Example dictation preview")
            HStack(spacing: 16) {
                Text("Sample preview")
                    .foregroundStyle(DS.Colors.textSecondary)
                DSInsetButton(
                    title: isPlaying ? "Playing…" : "Replay sample",
                    systemImage: "play.fill",
                    action: replaySample
                )
                    .disabled(isPlaying)
                    .help("Replay a short example of dictation, processing, and completion")
            }
            .font(DS.Fonts.ui(12))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 24)
        .background(DS.Colors.overlayPreviewFill)
        .clipShape(.rect(topLeadingRadius: DS.Radius.card, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: DS.Radius.card))
        .task(id: replay) {
            guard replay > 0 else { return }
            await playSample()
        }
    }

    private func replaySample() {
        isPlaying = true
        replay += 1
    }

    private func playSample() async {
        isPlaying = true
        defer {
            isPlaying = false
            model.updateState(.listening)
            model.updateListening(level: 0, transcript: Self.sampleText)
        }
        model.updateState(.listening)
        let words = Self.sampleText.split(separator: " ")
        do {
            for tick in 0..<(words.count * 4) {
                try Task.checkCancellation()
                let count = min(words.count, tick / 4 + 1)
                let level = Float(0.12 + 0.55 * abs(sin(Double(tick) * 0.7)))
                model.updateListening(level: level, transcript: words.prefix(count).joined(separator: " "))
                try await Task.sleep(for: .milliseconds(70))
            }
            model.updateState(.processing)
            try await Task.sleep(for: .milliseconds(450))
            model.updateState(.success)
            try await Task.sleep(for: .milliseconds(700))
        } catch { return }
    }

    private static func makeSample() -> OverlayModel {
        let model = OverlayModel()
        model.updateListening(level: 0, transcript: sampleText)
        model.isVisible = true
        return model
    }
}
