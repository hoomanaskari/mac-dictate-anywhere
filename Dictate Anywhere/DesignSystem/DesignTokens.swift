import AppKit
import SwiftUI

/// Design tokens mirroring the variables defined in `design.pen`.
/// Atomic design level: foundation.
enum DS {
    // MARK: - Colors (design.pen variables)

    enum Colors {
        /// Single source: the asset catalog's AccentColor (Xcode-editable).
        /// Accent-deep/soft/panel-text keep the derived light variant and
        /// pair it with a fixed dark companion, so changing AccentColor
        /// still re-themes light mode. Dark companions are lightened for
        /// contrast on dark surfaces (e.g. destructive 2.8:1 → 5.1:1).
        ///
        /// Surface/text tokens are light/dark pairs: the light hex preserves
        /// the design.pen palette exactly, the dark hex is its warm-dark
        /// companion. They follow the system appearance automatically, so no
        /// call site needs a `@Environment(\.colorScheme)` branch.
        static let accent = Color("AccentColor", bundle: .main)
        static let accentDeep = Color(light: derivedAccent(saturation: 1.071, brightness: 0.883), dark: 0xE8834F)
        static let accentSoft = Color(light: derivedAccent(saturation: 0.192, fixedBrightness: 0.973), dark: 0x3A2620)
        static let bgCard = Color(light: 0xFFFFFF, dark: 0x292420)
        static let bgInset = Color(light: 0xF6F0E6, dark: 0x201B15)
        static let bgSidebar = Color(light: 0xF3ECDF, dark: 0x171310)
        static let bgWindow = Color(light: 0xFAF5EC, dark: 0x1E1A15)
        static let border = Color(light: 0xE8DFCF, dark: 0x3A332A)
        static let borderSoft = Color(light: 0xF1EADD, dark: 0x2E2822)
        static let ink = Color(light: 0x2B2620, dark: 0xF2EAE0)
        static let success = Color(light: 0x5E9E6F, dark: 0x7ABF8A)
        static let successSoft = Color(light: 0xE3EFE4, dark: 0x223528)
        static let textSecondary = Color(light: 0x8D8171, dark: 0xA79A8A)

        // Derived colors used by specific design components.
        static let successText = Color(light: 0x3D7A4C, dark: 0x8FD0A2)
        static let panelText = Color(light: derivedAccent(saturation: 0.967, brightness: 0.621), dark: 0xE8B48E)
        static let destructive = Color(light: 0xC0392B, dark: 0xE5735C)
        static let toggleOff = Color(light: 0xDED4C2, dark: 0x4A4238)
        static let sliderTrackRest = Color(light: 0xE9DFCC, dark: 0x3D362C)
        static let addButtonFill = Color(light: 0xF1E9DB, dark: 0x2C271F)
        static let overlayPreviewFill = Color(light: 0xF3ECDE, dark: 0x231E18)
        static let waveformPillFill = Color(hex: 0x2B2620)
        static let waveformBarInactive = Color(hex: 0x6E655A)
        static let keycapShadow = Color(light: 0xE0D5C0, dark: 0x000000)
        static let footerCardFill = Color(dynamicWhiteLightAlpha: 0.5, darkAlpha: 0.08)

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
    /// Fixed appearance: identical in light and dark mode. Reserved for
    /// colors that are intentionally constant (the always-dark overlay pill).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Creates a system-appearance-aware color from light/dark hex values.
    /// Resolves via an `NSColor` dynamic provider, so SwiftUI picks the
    /// right variant as the system appearance changes — no view code needed.
    init(light: UInt32, dark: UInt32, opacity: Double = 1) {
        self.init(nsColor: .dsDynamic(
            light: .dsHex(light, opacity: opacity),
            dark: .dsHex(dark, opacity: opacity)
        ))
    }

    /// Appearance-aware color with a computed light variant (e.g. an
    /// accent-derived color, preserving catalog re-theming) and a fixed
    /// dark hex companion.
    init(light: Color, dark: UInt32, darkOpacity: Double = 1) {
        self.init(nsColor: .dsDynamic(
            light: NSColor(light),
            dark: .dsHex(dark, opacity: darkOpacity)
        ))
    }

    /// Appearance-aware white overlay with per-appearance alpha, e.g. cards
    /// that float over the sidebar in both modes.
    init(dynamicWhiteLightAlpha lightAlpha: Double, darkAlpha: Double) {
        self.init(nsColor: .dsDynamic(
            light: NSColor(white: 1, alpha: lightAlpha),
            dark: NSColor(white: 1, alpha: darkAlpha)
        ))
    }
}

private extension NSColor {
    static func dsHex(_ hex: UInt32, opacity: Double = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(opacity)
        )
    }

    /// Dynamic color resolving `light` vs `dark` from the drawing appearance.
    static func dsDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
