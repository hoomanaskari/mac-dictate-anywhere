import AppKit
import SwiftUI

/// Design tokens mirroring the variables defined in `design.pen`.
/// Atomic design level: foundation.
enum DS {
    // MARK: - Colors (design.pen variables)

    enum Colors {
        /// Single source: the asset catalog's AccentColor (Xcode-editable).
        /// The deep/soft/panel-text variants are derived from it at runtime,
        /// so changing AccentColor re-themes the entire app.
        static let accent = Color("AccentColor", bundle: .main)
        static let accentDeep = derivedAccent(saturation: 1.071, brightness: 0.883)
        static let accentSoft = derivedAccent(saturation: 0.192, fixedBrightness: 0.973)
        static let bgCard = Color(hex: 0xFFFFFF)
        static let bgInset = Color(hex: 0xF6F0E6)
        static let bgSidebar = Color(hex: 0xF3ECDF)
        static let bgWindow = Color(hex: 0xFAF5EC)
        static let border = Color(hex: 0xE8DFCF)
        static let borderSoft = Color(hex: 0xF1EADD)
        static let ink = Color(hex: 0x2B2620)
        static let success = Color(hex: 0x5E9E6F)
        static let successSoft = Color(hex: 0xE3EFE4)
        static let textSecondary = Color(hex: 0x8D8171)

        // Derived colors used by specific design components.
        static let successText = Color(hex: 0x3D7A4C)
        static let panelText = derivedAccent(saturation: 0.967, brightness: 0.621)
        static let destructive = Color(hex: 0xC0392B)
        static let toggleOff = Color(hex: 0xDED4C2)
        static let sliderTrackRest = Color(hex: 0xE9DFCC)
        static let addButtonFill = Color(hex: 0xF1E9DB)
        static let overlayPreviewFill = Color(hex: 0xF3ECDE)
        static let waveformPillFill = Color(hex: 0x2B2620)
        static let waveformBarInactive = Color(hex: 0x6E655A)
        static let keycapShadow = Color(hex: 0xE0D5C0)
        static let footerCardFill = Color.white.opacity(0.5)

        /// HSB of the catalog AccentColor, falling back to the design.pen
        /// value (#DE6A3B) if the asset can't be resolved.
        static var accentHSB: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
            let base = NSColor(named: "AccentColor") ?? NSColor(srgbRed: 0xDE / 255, green: 0x6A / 255, blue: 0x3B / 255, alpha: 1)
            guard let rgb = base.usingColorSpace(.sRGB) else { return (0.048, 0.734, 0.871) }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return (h, s, b)
        }

        /// Builds an accent variant by scaling saturation/brightness of the
        /// base accent. Multipliers reproduce the design.pen palette exactly
        /// when AccentColor is the default #DE6A3B.
        static func derivedAccent(
            saturation saturationScale: CGFloat,
            brightness brightnessScale: CGFloat = 1,
            fixedBrightness: CGFloat? = nil
        ) -> Color {
            let base = accentHSB
            return Color(
                hue: base.hue,
                saturation: min(base.saturation * saturationScale, 1),
                brightness: fixedBrightness ?? min(base.brightness * brightnessScale, 1)
            )
        }
    }

    // MARK: - Typography

    enum Fonts {
        static let displayFamily = "Fraunces"
        static let uiFamily = "Inter"

        /// Fraunces — used for headings and brand text.
        static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
            Font.custom(displayFamily, size: size).weight(weight)
        }

        /// Inter — used for all UI copy.
        static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            Font.custom(uiFamily, size: size).weight(weight)
        }
    }

    // MARK: - Radii

    enum Radius {
        static let card: CGFloat = 12
        static let control: CGFloat = 9
        static let small: CGFloat = 8
        static let panel: CGFloat = 10
        static let window: CGFloat = 14
        static let capsule: CGFloat = 999
    }

    // MARK: - Spacing

    enum Spacing {
        /// Vertical gap between page sections.
        static let section: CGFloat = 24
        /// Gap between an overline and its card.
        static let overlineToCard: CGFloat = 10
        /// Standard row padding: vertical.
        static let rowVertical: CGFloat = 13
        /// Standard row padding: horizontal.
        static let rowHorizontal: CGFloat = 16
        /// Content padding for pages: [top, trailing, bottom, leading] = [34, 44, 36, 44].
        static let contentTop: CGFloat = 34
        static let contentHorizontal: CGFloat = 44
        static let contentBottom: CGFloat = 36
    }

    // MARK: - Layout metrics

    enum Metrics {
        static let sidebarWidth: CGFloat = 264
        static let windowWidth: CGFloat = 1120
        static let windowHeight: CGFloat = 780
    }
}

extension Color {
    /// Creates a color from a 24-bit RGB hex value, e.g. `Color(hex: 0xDE6A3B)`.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
