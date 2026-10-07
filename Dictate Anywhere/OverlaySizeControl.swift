import SwiftUI

struct OverlaySizeControl: View {
    @Bindable var settings: Settings

    var body: some View {
        DSDetailRow(label: "Preview size", caption: "More room and larger text for easier reading.") {
            VStack(spacing: 4) {
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

                HStack(spacing: 0) {
                    ForEach(OverlaySize.allCases, id: \.self) { size in
                        Text(size.displayName)
                            .font(DS.Fonts.ui(11.5, settings.overlaySize == size ? .semibold : .regular))
                            .foregroundStyle(settings.overlaySize == size ? DS.Colors.ink : DS.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: size == .compact ? .leading : size == .large ? .trailing : .center)
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(width: 220)
        }
    }
}
