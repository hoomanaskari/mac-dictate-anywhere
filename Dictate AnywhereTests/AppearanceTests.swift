import XCTest
import SwiftUI
@testable import Dictate_Anywhere

/// Readability and bundled-font integration, without freezing cosmetic design values.
final class AppearanceTests: XCTestCase {
    private func components(_ color: Color, appearance: NSAppearance.Name) -> (r: Double, g: Double, b: Double, a: Double) {
        let drawingAppearance = NSAppearance(named: appearance) ?? NSAppearance.currentDrawing()
        var result = (r: 0.0, g: 0.0, b: 0.0, a: 0.0)
        drawingAppearance.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            result = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
        }
        return result
    }

    private func relativeLuminance(_ c: (r: Double, g: Double, b: Double, a: Double)) -> Double {
        let linearize = { (v: Double) in v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
    }

    private func contrastRatio(_ foreground: Color, _ background: Color, appearance: NSAppearance.Name) -> Double {
        let l1 = relativeLuminance(components(foreground, appearance: appearance))
        let l2 = relativeLuminance(components(background, appearance: appearance))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testDarkBodyTextContrastMeetsAA() {
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.ink, DS.Colors.bgWindow, appearance: .darkAqua), 7)
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.ink, DS.Colors.bgCard, appearance: .darkAqua), 7)
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.textSecondary, DS.Colors.bgCard, appearance: .darkAqua), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.textSecondary, DS.Colors.bgWindow, appearance: .darkAqua), 4.5)
    }

    func testDarkTintedPairContrastMeetsAA() {
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.panelText, DS.Colors.accentSoft, appearance: .darkAqua), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.successText, DS.Colors.successSoft, appearance: .darkAqua), 4.5)
    }

    func testDarkAccentContrastMeetsAA() {
        // Accents lightened for dark surfaces: destructive was 2.8:1 reused.
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.destructive, DS.Colors.bgCard, appearance: .darkAqua), 4.5)
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.accentDeep, DS.Colors.bgCard, appearance: .darkAqua), 3)
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.success, DS.Colors.bgCard, appearance: .darkAqua), 3)
    }

    func testLightBodyTextContrastBaseline() {
        // Locks the shipped light palette: body text is AAA-comfortable;
        // secondary copy sits at large-text/UI contrast (light hexes frozen).
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.ink, DS.Colors.bgWindow, appearance: .aqua), 7)
        XCTAssertGreaterThanOrEqual(contrastRatio(DS.Colors.textSecondary, DS.Colors.bgCard, appearance: .aqua), 3)
    }

    func testPreviewPalettesStayReadableInBothThemes() {
        for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let palette = OverlayPalette(scheme: scheme)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.text, palette.surface, appearance: appearance), 7)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.secondaryText, palette.surface, appearance: appearance), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.accent, palette.surface, appearance: appearance), 3)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.success, palette.surface, appearance: appearance), 3)
        }
    }

    func testBundledFontsAreRegistered() {
        // ATSApplicationFontsPath = "." must register both families in the host app.
        XCTAssertNotNil(NSFont(name: "Fraunces", size: 16), "Fraunces font not registered")
        XCTAssertNotNil(NSFont(name: "Inter", size: 13), "Inter font not registered")
    }
}
