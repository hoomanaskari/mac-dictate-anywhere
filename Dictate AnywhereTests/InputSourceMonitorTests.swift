import XCTest
@testable import Dictate_Anywhere_Dev

final class InputSourceMonitorTests: XCTestCase {
    // MARK: - deriveLanguage (pure)

    func testDeriveLanguageMatchesPrimarySubtag() {
        XCTAssertEqual(InputSourceMonitor.deriveLanguage(fromBCP47: ["zh-Hans"]), .chinese)
        XCTAssertEqual(InputSourceMonitor.deriveLanguage(fromBCP47: ["en-US"]), .english)
        XCTAssertEqual(InputSourceMonitor.deriveLanguage(fromBCP47: ["de"]), .german)
    }

    func testDeriveLanguageMapsNorwegianBokmal() {
        XCTAssertEqual(InputSourceMonitor.deriveLanguage(fromBCP47: ["nb"]), .norwegian)
    }

    func testDeriveLanguageReturnsNilForUnsupportedOrEmpty() {
        XCTAssertNil(InputSourceMonitor.deriveLanguage(fromBCP47: ["ko"]))
        XCTAssertNil(InputSourceMonitor.deriveLanguage(fromBCP47: []))
    }

    // MARK: - TIS queries (run against the real system in the test host)

    @MainActor
    func testCurrentInputSourceIDIsNonEmpty() {
        let id = InputSourceMonitor().currentInputSourceID()
        XCTAssertNotNil(id)
        XCTAssertFalse(id?.isEmpty ?? true)
    }

    @MainActor
    func testAvailableInputSourcesIncludesCurrent() {
        let monitor = InputSourceMonitor()
        guard let current = monitor.currentInputSourceID() else {
            return XCTFail("No current input source")
        }
        let sources = monitor.availableInputSources()
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(sources.contains { $0.id == current })
        XCTAssertTrue(sources.allSatisfy { !$0.localizedName.isEmpty })
    }
}
