import XCTest
import SwiftUI
@testable import Dictate_Anywhere_Dev

/// Smoke tests: every design-system component must render to a real image
/// without crashing. Catches broken layouts, missing assets, and invalid styles.
@MainActor
final class ComponentRenderTests: XCTestCase {

    private func assertRenders<V: View>(_ view: V, width: CGFloat = 480, file: StaticString = #filePath, line: UInt = #line) {
        let renderer = ImageRenderer(content: view.frame(width: width).padding())
        renderer.scale = 2
        XCTAssertNotNil(renderer.nsImage, "component failed to render", file: file, line: line)
        if let image = renderer.nsImage {
            XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
            XCTAssertGreaterThan(image.size.height, 0, file: file, line: line)
        }
    }

    // MARK: - Atoms

    func testOverlineRenders() { assertRenders(DSOverline(text: "Startup")) }
    func testDividerRenders() { assertRenders(DSDivider()) }
    func testHintRenders() { assertRenders(DSHint(text: "Helpful hint text for the user.")) }
    func testPanelRenders() { assertRenders(DSPanel(text: "Informational panel message body.", icon: "keyboard")) }

    func testChipRenders() {
        assertRenders(DSChip(text: "um"))
        assertRenders(DSChip(text: "removable", onRemove: {}))
        assertRenders(DSChip(text: "selected", isSelected: true))
    }

    func testStatusPillRenders() {
        assertRenders(DSStatusPill(text: "Ready"))
        assertRenders(DSStatusPill(
            text: "Not downloaded",
            dotColor: DS.Colors.textSecondary,
            textColor: DS.Colors.textSecondary,
            fill: DS.Colors.bgInset
        ))
    }

    func testKeycapRenders() {
        assertRenders(DSKeycap(text: "\u{2318}"))
        assertRenders(DSKeycapGroup(displayName: "L\u{2303}L\u{2325}L\u{2318}"))
    }

    func testButtonsRender() {
        assertRenders(Button("Change") {}.buttonStyle(.dsPrimary))
        assertRenders(Button("Clear") {}.buttonStyle(.dsSecondary))
        assertRenders(Button("Delete Model…") {}.buttonStyle(.dsDestructive))
        assertRenders(DSIconButton(systemImage: "trash") {})
        assertRenders(DSInsetButton(title: "Copy", systemImage: "doc.on.doc") {})
        assertRenders(DSAddButton(title: "Add another shortcut") {})
    }

    func testToggleRenders() {
        assertRenders(Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.dsSwitch))
        assertRenders(Toggle("", isOn: .constant(false)).labelsHidden().toggleStyle(.dsSwitch))
    }

    func testSliderRenders() {
        assertRenders(DSSlider(value: .constant(0.5)))
        assertRenders(DSSlider(value: .constant(0)))
        assertRenders(DSSlider(value: .constant(1)))
    }

    func testDropdownLabelRenders() {
        assertRenders(DSDropdownLabel(text: "Menu Bar Only"))
    }

    func testSearchAndTextFieldsRender() {
        assertRenders(DSSearchField(placeholder: "Search your dictations", text: .constant("")))
        assertRenders(DSTextField(placeholder: "Add word…", text: .constant("")))
        assertRenders(DSTextField(placeholder: "API key", text: .constant("secret"), isSecure: true))
    }

    // MARK: - Molecules

    func testCardAndSectionRender() {
        assertRenders(DSCard { Text("Card content").padding() })
        assertRenders(DSSection(overline: "Audio") {
            DSInfoRow(label: "Microphone", value: "System Default")
        })
    }

    func testSectionHeaderRenders() {
        assertRenders(DSSectionHeader(title: "General", subtitle: "How Dictate Anywhere starts, sounds, and listens."))
    }

    func testRowsRender() {
        assertRenders(DSInfoRow(label: "Languages", value: "English only"))
        assertRenders(DSInfoRow(label: "Launch at login") {
            Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.dsSwitch)
        })
        assertRenders(DSDetailRow(label: "Variant", caption: "Streaming English dictation.") {
            DSDropdownLabel(text: "Nemotron Streaming (2240 ms)")
        })
        assertRenders(DSStackedRow(
            label: "Show text preview in overlay",
            caption: "When enabled, live transcription text appears next to the waveform.",
            isOn: .constant(false)
        ))
    }

    func testBrandComponentsRender() {
        assertRenders(DSBrandMark(size: 36))
        assertRenders(DSBrandMark(size: 76))
        assertRenders(DSBrand())
        assertRenders(DSFooterCard(
            statusText: "Ready to dictate",
            statusColor: DS.Colors.success,
            versionText: "Version 2.3.1"
        ))
    }

    func testNavItemRenders() {
        assertRenders(DSNavItem(title: "Speech Model", systemImage: "cpu", isSelected: true) {})
        assertRenders(DSNavItem(title: "History", systemImage: "clock.arrow.circlepath", isSelected: false) {})
    }

    func testWaveformPillRenders() {
        assertRenders(DSWaveformPill())
    }

    // MARK: - Organisms

    func testWarningBannerRenders() {
        assertRenders(WarningBanner(message: "A speech model is required.", buttonTitle: "Set Up") {})
    }
}
