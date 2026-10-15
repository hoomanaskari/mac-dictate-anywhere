import XCTest
import SwiftUI
@testable import Dictate_Anywhere

/// Guards preview and control readability without freezing cosmetic design values.
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

    func testPreviewPalettesStayReadableInBothThemes() {
        for (scheme, appearance) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let palette = OverlayPalette(scheme: scheme)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.text, palette.surface, appearance: appearance), 7)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.secondaryText, palette.surface, appearance: appearance), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.accent, palette.surface, appearance: appearance), 3)
            XCTAssertGreaterThanOrEqual(contrastRatio(palette.success, palette.surface, appearance: appearance), 3)
        }
    }

    func testFilledControlLabelsMeetAAInBothThemes() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertGreaterThanOrEqual(
                contrastRatio(DS.Colors.onAccent, DS.Colors.accentDeep, appearance: appearance),
                4.5,
                "Filled action buttons and selected chips need readable labels"
            )
        }
    }

}
