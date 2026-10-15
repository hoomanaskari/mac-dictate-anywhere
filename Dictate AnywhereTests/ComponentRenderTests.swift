import XCTest
import SwiftUI
@testable import Dictate_Anywhere

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
    func testLoadingMessageRenders() { assertRenders(DSLoadingMessage(text: "Checking server…")) }

    func testChipRenders() {
        assertRenders(DSChip(text: "um"))
        assertRenders(DSChip(text: "removable", onRemove: {}))
        assertRenders(DSChip(text: "selected", isSelected: true))
        assertRenders(DSChip(text: "selectable and removable", onSelect: {}, onRemove: {}))
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
        assertRenders(DSIconButton(systemImage: "trash", accessibilityLabel: "Delete") {})
        assertRenders(DSInsetButton(title: "Copy", systemImage: "doc.on.doc") {})
        assertRenders(DSAddButton(title: "Add another shortcut") {})
    }

    func testShortcutRecorderControlsStayOnOneLineWhenWidthIsConstrained() {
        let view = ShortcutRecorderView(
            accessibilityName: "Shortcut 1",
            displayName: "L\u{2303}L\u{2325}L\u{2318}",
            onRecord: { _, _, _ in },
            onClear: {}
        )
        .frame(width: 260, alignment: .trailing)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            return XCTFail("shortcut recorder failed to render")
        }

        XCTAssertLessThanOrEqual(image.size.height, 40, "keycaps and action buttons must remain single-line")
    }

    func testToggleRenders() {
        assertRenders(DSSwitch(accessibilityName: "Prewarm models at startup", isOn: .constant(true)))
        assertRenders(DSSwitch(accessibilityName: "Prewarm models at startup", isOn: .constant(false)))
    }

    func testSliderRenders() {
        assertRenders(DSSlider(value: .constant(0.5), label: "Volume"))
        assertRenders(DSSlider(value: .constant(0), label: "Volume"))
        assertRenders(DSSlider(value: .constant(1), label: "Volume"))
    }

    func testDropdownLabelRenders() {
        assertRenders(DSDropdownLabel(text: "Menu Bar Only"))
    }

    func testSearchAndTextFieldsRender() {
        assertRenders(DSSearchField(
            placeholder: "Search your dictations", text: .constant(""),
            accessibilityName: "Search transcript history"
        ))
        assertRenders(DSTextField(
            placeholder: "Add word…", text: .constant(""), accessibilityName: "Custom vocabulary word"
        ))
        assertRenders(DSTextField(
            placeholder: "API key", text: .constant("secret"), isSecure: true,
            accessibilityName: "API key"
        ))
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
        assertRenders(DSEmptyState(systemImage: "text.book.closed", title: "No words added yet"))
    }

    func testRowsRender() {
        assertRenders(DSInfoRow(label: "Languages", value: "English only"))
        assertRenders(DSInfoRow(label: "Launch at login") {
            DSSwitch(accessibilityName: "Launch at login", isOn: .constant(true))
        })
        assertRenders(DSDetailRow(label: "Variant", caption: "Streaming English dictation.") {
            DSDropdownLabel(text: "Nemotron Streaming (2240 ms)")
        })
        assertRenders(DSStackedRow(
            label: "Show text preview in overlay",
            caption: "When enabled, live transcription text appears next to the waveform.",
            isOn: .constant(false)
        ))
        assertRenders(DSCardCaption(text: "Local processing keeps text on your Mac."))
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

    // MARK: - Organisms

    func testAttentionBannerRenders() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: false,
            microphoneCanPrompt: false,
            accessibilityGranted: false,
            engineChoice: .parakeet,
            speechSetupNeeded: true,
            automationDenied: true
        )
        assertRenders(AttentionBanner(issues: issues, selectedID: .constant(nil)) { _ in }, width: 676)
    }
}
