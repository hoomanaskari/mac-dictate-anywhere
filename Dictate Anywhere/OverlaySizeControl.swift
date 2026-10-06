import SwiftUI

struct OverlaySizeControl: View {
    @Bindable var settings: Settings

    var body: some View {
        DSDetailRow(label: "Preview size", caption: "More room and larger text for easier reading.") {
            VStack(alignment: .trailing, spacing: 6) {
                Text(settings.overlaySize.displayName)
                    .font(DS.Fonts.ui(12, .medium))
                    .foregroundStyle(DS.Colors.ink)
                Slider(
                    value: Binding(
                        get: { settings.overlaySize.sliderValue },
                        set: { settings.overlaySize = OverlaySize(sliderValue: $0) }
                    ),
                    in: 0...2,
                    step: 1
                )
                .tint(DS.Colors.accent)
                .accessibilityLabel("Preview size")
                .accessibilityValue(settings.overlaySize.displayName)
                .help("Compact, Comfortable, or Large")
            }
            .frame(width: 180)
        }
    }
}
