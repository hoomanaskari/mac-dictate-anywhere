import XCTest
@testable import Dictate_Anywhere_Dev

final class HotkeyTests: XCTestCase {

    // MARK: - Display name formatting

    func testDisplayNameModifierOnlyCombo() {
        let name = Settings.displayName(keyCode: nil, modifiers: [.control, .option, .command])
        XCTAssertEqual(name, "\u{2303}\u{2325}\u{2318}")
    }

    func testDisplayNameSideAwareModifiers() {
        let leftCommand = Settings.displayName(keyCode: nil, modifiers: [.command, .leftCommand])
        XCTAssertEqual(leftCommand, "L\u{2318}")

        let rightCommand = Settings.displayName(keyCode: nil, modifiers: [.command, .rightCommand])
        XCTAssertEqual(rightCommand, "R\u{2318}")
    }

    func testDisplayNameIncludesFunction() {
        let name = Settings.displayName(keyCode: nil, modifiers: [.function])
        XCTAssertEqual(name, "fn")
    }

    func testDisplayNameWithKeyIsNonEmpty() {
        let name = Settings.displayName(keyCode: 49, modifiers: [.command])
        XCTAssertTrue(name.hasPrefix("\u{2318}"))
        XCTAssertGreaterThan(name.count, 1)
    }

    // MARK: - Modifier normalization

    func testNormalizedModifiersInsertsGenericForSided() {
        let normalized = Settings.normalizedHotkeyModifiers([.leftCommand])
        XCTAssertTrue(normalized.contains(.command))
        XCTAssertTrue(normalized.contains(.leftCommand))
    }

    func testNormalizedModifiersKeepsGeneric() {
        let normalized = Settings.normalizedHotkeyModifiers([.shift])
        XCTAssertTrue(normalized.contains(.shift))
    }

    func testHotkeyModifiersFromCGFlags() {
        let flags: CGEventFlags = [.maskCommand, .maskShift]
        let modifiers = Settings.hotkeyModifiers(from: flags)
        XCTAssertTrue(modifiers.contains(.command))
        XCTAssertTrue(modifiers.contains(.shift))
        XCTAssertFalse(modifiers.contains(.control))
    }

    // MARK: - Keycap tokenizer

    func testTokenizerEmpty() {
        XCTAssertEqual(HotkeyKeycapTokenizer.tokens(from: ""), [])
    }

    func testTokenizerPlainModifiers() {
        XCTAssertEqual(
            HotkeyKeycapTokenizer.tokens(from: "\u{2303}\u{2325}\u{2318}"),
            ["\u{2303}", "\u{2325}", "\u{2318}"]
        )
    }

    func testTokenizerSidedModifiers() {
        XCTAssertEqual(
            HotkeyKeycapTokenizer.tokens(from: "L\u{2303}L\u{2325}L\u{2318}"),
            ["L \u{2303}", "L \u{2325}", "L \u{2318}"]
        )
    }

    func testTokenizerFunctionKey() {
        XCTAssertEqual(HotkeyKeycapTokenizer.tokens(from: "fn"), ["fn"])
        XCTAssertEqual(HotkeyKeycapTokenizer.tokens(from: "fn\u{2318}"), ["fn", "\u{2318}"])
    }

    func testTokenizerModifierPlusKey() {
        XCTAssertEqual(
            HotkeyKeycapTokenizer.tokens(from: "\u{2318}A"),
            ["\u{2318}", "A"]
        )
        XCTAssertEqual(
            HotkeyKeycapTokenizer.tokens(from: "R\u{2318}Space"),
            ["R \u{2318}", "Space"]
        )
    }

    func testTokenizerKeyOnly() {
        XCTAssertEqual(HotkeyKeycapTokenizer.tokens(from: "F5"), ["F5"])
    }

    // MARK: - HotkeyBinding

    func testDefaultBindingIsHoldToRecordModifierOnly() {
        let binding = HotkeyBinding.defaultBinding
        XCTAssertNil(binding.keyCode)
        XCTAssertTrue(binding.hasBinding)
        XCTAssertTrue(binding.modifiers.contains(.control))
        XCTAssertTrue(binding.modifiers.contains(.option))
        XCTAssertTrue(binding.modifiers.contains(.command))
    }

    func testHasBindingFalseWhenEmpty() {
        let binding = HotkeyBinding(
            id: UUID(),
            keyCode: nil,
            modifiersRawValue: 0,
            displayName: "",
            mode: .holdToRecord
        )
        XCTAssertFalse(binding.hasBinding)
    }

    // MARK: - Conflict detection

    func testInternalConflictDetectsDuplicates() {
        let modifiers = HotkeyModifiers([.control, .option, .command]).rawValue
        let a = HotkeyBinding(id: UUID(), keyCode: nil, modifiersRawValue: modifiers, displayName: "x", mode: .holdToRecord)
        let b = HotkeyBinding(id: UUID(), keyCode: nil, modifiersRawValue: modifiers, displayName: "x", mode: .handsFreeToggle)
        XCTAssertNotNil(ConflictDetector.internalConflict(for: a, in: [a, b]))
    }

    func testInternalConflictNilWhenUnique() {
        let a = HotkeyBinding(
            id: UUID(), keyCode: nil,
            modifiersRawValue: HotkeyModifiers([.control, .option]).rawValue,
            displayName: "a", mode: .holdToRecord
        )
        let b = HotkeyBinding(
            id: UUID(), keyCode: nil,
            modifiersRawValue: HotkeyModifiers([.command, .shift]).rawValue,
            displayName: "b", mode: .holdToRecord
        )
        XCTAssertNil(ConflictDetector.internalConflict(for: a, in: [a, b]))
    }

    func testInternalConflictNilForUnboundBinding() {
        let unbound = HotkeyBinding(id: UUID(), keyCode: nil, modifiersRawValue: 0, displayName: "", mode: .holdToRecord)
        XCTAssertNil(ConflictDetector.internalConflict(for: unbound, in: [unbound]))
    }

    func testSystemConflictForCommandQ() {
        // ⌘Q (keyCode 12) is a well-known system shortcut.
        let binding = HotkeyBinding(
            id: UUID(), keyCode: 12,
            modifiersRawValue: HotkeyModifiers([.command]).rawValue,
            displayName: "\u{2318}Q", mode: .holdToRecord
        )
        // Whether flagged or not must not crash; if flagged, message must be non-empty.
        if let message = ConflictDetector.systemConflict(for: binding) {
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: - HotkeyMode

    func testHotkeyModeDisplayNames() {
        XCTAssertEqual(HotkeyMode.holdToRecord.displayName, "Hold to Record")
        XCTAssertEqual(HotkeyMode.handsFreeToggle.displayName, "Tap to Toggle")
        XCTAssertEqual(HotkeyMode.allCases.count, 2)
    }
}
