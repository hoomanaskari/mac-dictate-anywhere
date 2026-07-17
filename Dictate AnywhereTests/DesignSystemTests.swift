import XCTest
import SwiftUI
@testable import Dictate_Anywhere_Dev

final class DesignSystemTests: XCTestCase {

    // MARK: - Color(hex:)

    private func components(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        let ns = NSColor(color).usingColorSpace(.sRGB)!
        return (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }

    func testColorHexDecodesChannels() {
        let c = components(Color(hex: 0xDE6A3B))
        XCTAssertEqual(c.r, Double(0xDE) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0x6A) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0x3B) / 255, accuracy: 0.001)
        XCTAssertEqual(c.a, 1, accuracy: 0.001)
    }

    func testColorHexOpacity() {
        let c = components(Color(hex: 0x000000, opacity: 0.5))
        XCTAssertEqual(c.a, 0.5, accuracy: 0.001)
    }

    func testColorHexBlackAndWhite() {
        let black = components(Color(hex: 0x000000))
        XCTAssertEqual(black.r + black.g + black.b, 0, accuracy: 0.001)
        let white = components(Color(hex: 0xFFFFFF))
        XCTAssertEqual(white.r + white.g + white.b, 3, accuracy: 0.001)
    }

    // MARK: - Token values match design.pen variables

    func testAccentToken() {
        let c = components(DS.Colors.accent)
        XCTAssertEqual(c.r, Double(0xDE) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0x6A) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0x3B) / 255, accuracy: 0.001)
    }

    func testAccentFollowsAssetCatalog() {
        // DS.Colors.accent must be the catalog color, not a hardcoded hex.
        let catalog = NSColor(named: "AccentColor")?.usingColorSpace(.sRGB)
        XCTAssertNotNil(catalog)
        let c = components(DS.Colors.accent)
        XCTAssertEqual(c.r, catalog!.redComponent, accuracy: 0.001)
        XCTAssertEqual(c.g, catalog!.greenComponent, accuracy: 0.001)
        XCTAssertEqual(c.b, catalog!.blueComponent, accuracy: 0.001)
    }

    /// The derived variants must reproduce the design.pen palette (within a
    /// small tolerance) while the catalog accent is the default #DE6A3B.
    func testDerivedAccentVariantsMatchDesign() {
        let deep = components(DS.Colors.accentDeep)
        XCTAssertEqual(deep.r, Double(0xC4) / 255, accuracy: 0.04)
        XCTAssertEqual(deep.g, Double(0x55) / 255, accuracy: 0.04)
        XCTAssertEqual(deep.b, Double(0x2A) / 255, accuracy: 0.04)

        let soft = components(DS.Colors.accentSoft)
        XCTAssertEqual(soft.r, Double(0xF8) / 255, accuracy: 0.04)
        XCTAssertEqual(soft.g, Double(0xE5) / 255, accuracy: 0.04)
        XCTAssertEqual(soft.b, Double(0xD5) / 255, accuracy: 0.04)

        let panel = components(DS.Colors.panelText)
        XCTAssertEqual(panel.r, Double(0x8A) / 255, accuracy: 0.04)
        XCTAssertEqual(panel.g, Double(0x4A) / 255, accuracy: 0.04)
        XCTAssertEqual(panel.b, Double(0x28) / 255, accuracy: 0.04)
    }

    func testWindowBackgroundToken() {
        let c = components(DS.Colors.bgWindow)
        XCTAssertEqual(c.r, Double(0xFA) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0xF5) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0xEC) / 255, accuracy: 0.001)
    }

    func testSidebarBackgroundToken() {
        let c = components(DS.Colors.bgSidebar)
        XCTAssertEqual(c.r, Double(0xF3) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0xEC) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0xDF) / 255, accuracy: 0.001)
    }

    func testInkToken() {
        let c = components(DS.Colors.ink)
        XCTAssertEqual(c.r, Double(0x2B) / 255, accuracy: 0.001)
        XCTAssertEqual(c.g, Double(0x26) / 255, accuracy: 0.001)
        XCTAssertEqual(c.b, Double(0x20) / 255, accuracy: 0.001)
    }

    func testFontFamiliesMatchDesign() {
        XCTAssertEqual(DS.Fonts.displayFamily, "Fraunces")
        XCTAssertEqual(DS.Fonts.uiFamily, "Inter")
    }

    func testBundledFontsAreRegistered() {
        // ATSApplicationFontsPath = "." must register both families in the host app.
        XCTAssertNotNil(NSFont(name: "Fraunces", size: 16), "Fraunces font not registered")
        XCTAssertNotNil(NSFont(name: "Inter", size: 13), "Inter font not registered")
    }

    func testMetricsMatchDesign() {
        XCTAssertEqual(DS.Metrics.sidebarWidth, 264)
        XCTAssertEqual(DS.Metrics.windowWidth, 1120)
        XCTAssertEqual(DS.Metrics.windowHeight, 780)
        XCTAssertEqual(DS.Radius.card, 12)
        XCTAssertEqual(DS.Radius.control, 9)
        XCTAssertEqual(DS.Spacing.section, 24)
        XCTAssertEqual(DS.Spacing.contentHorizontal, 44)
    }

    // MARK: - Waveform pill

    func testWaveformPillBarsMatchDesign() {
        let bars = DSWaveformPill.bars
        XCTAssertEqual(bars.count, 14)
        XCTAssertEqual(bars.filter(\.isActive).count, 6)
        // Design: bars 4–9 are the accent bars.
        for (index, bar) in bars.enumerated() {
            XCTAssertEqual(bar.isActive, (4...9).contains(index), "bar \(index)")
        }
        XCTAssertEqual(bars.map(\.height), [8, 14, 20, 12, 24, 17, 10, 22, 15, 26, 12, 18, 9, 14])
    }

    // MARK: - History filtering & date format

    private func entry(_ text: String) -> TranscriptHistoryEntry {
        TranscriptHistoryEntry(id: UUID(), text: text, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testHistoryFilterEmptyQueryReturnsAll() {
        let entries = [entry("alpha"), entry("beta")]
        XCTAssertEqual(TranscriptHistoryView.filteredEntries(entries, searchText: "").count, 2)
        XCTAssertEqual(TranscriptHistoryView.filteredEntries(entries, searchText: "   ").count, 2)
    }

    func testHistoryFilterIsCaseInsensitive() {
        let entries = [entry("Hello World"), entry("other")]
        let filtered = TranscriptHistoryView.filteredEntries(entries, searchText: "hello")
        XCTAssertEqual(filtered.map(\.text), ["Hello World"])
    }

    func testHistoryFilterNoMatches() {
        let entries = [entry("alpha")]
        XCTAssertTrue(TranscriptHistoryView.filteredEntries(entries, searchText: "zzz").isEmpty)
    }

    func testHistoryDateFormatMatchesDesign() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 15
        components.hour = 17; components.minute = 54
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!

        let formatter = TranscriptHistoryView.dateFormatter
        let original = formatter.locale
        formatter.locale = Locale(identifier: "en_US_POSIX")
        defer { formatter.locale = original }

        XCTAssertEqual(formatter.string(from: date), "Jul 15, 2026 · 5:54 PM")
    }

    // MARK: - Comparable.clamped

    func testClamped() {
        XCTAssertEqual(5.clamped(to: 0...10), 5)
        XCTAssertEqual((-1).clamped(to: 0...10), 0)
        XCTAssertEqual(11.clamped(to: 0...10), 10)
        XCTAssertEqual(0.75.clamped(to: 0.0...1.0), 0.75, accuracy: 0.0001)
    }
}
