import XCTest
@testable import Dictate_Anywhere

@MainActor
final class PrivacyRegressionTests: XCTestCase {
    func testMissingDestinationNeverDispatchesPaste() async {
        var dispatched = false
        let result = await TextInserter.deliverToTarget(
            isTargetReady: { false },
            pasteScript: { dispatched = true; return .success },
            pasteEvent: { dispatched = true; return true }
        )
        XCTAssertEqual(result, .copiedOnly)
        XCTAssertFalse(dispatched)
    }

    func testFocusChangeDuringScriptPreventsKeyboardFallback() async {
        for failure in [PasteScriptOutcome.preDispatchFailed, .automationDenied] {
            var focused = true
            var fallback = false
            let result = await TextInserter.deliverToTarget(
                isTargetReady: { focused },
                pasteScript: { focused = false; return failure },
                pasteEvent: { fallback = true; return true }
            )
            XCTAssertEqual(result, .copiedOnly)
            XCTAssertFalse(fallback)
        }
    }

    func testScriptRejectingDestinationNeverFallsBackEvenIfFocusReturns() async {
        var fallback = false
        let result = await TextInserter.deliverToTarget(
            isTargetReady: { true }, pasteScript: { .targetUnavailable },
            pasteEvent: { fallback = true; return true }
        )
        XCTAssertEqual(result, .copiedOnly)
        XCTAssertFalse(fallback)
    }

    func testNativePasteUsesScriptOnlyAfterConfirmedPreDispatchFailure() async {
        for outcome in [PasteScriptOutcome.success, .possiblyDispatched, .targetUnavailable, .preDispatchFailed] {
            for hasPendingListEdit in [false, true] {
                var scriptCount = 0
                var keyboardCount = 0
                let result = await TextInserter.deliverToTarget(
                    isTargetReady: { true },
                    pasteScript: {
                        await TextInserter.pasteWithScriptFallback(
                            accessibilityOutcome: outcome,
                            hasPendingListEdit: hasPendingListEdit
                        ) {
                            scriptCount += 1
                            return .success
                        }
                    },
                    pasteEvent: { keyboardCount += 1; return true }
                )
                let shouldUseScript = outcome == .preDispatchFailed && !hasPendingListEdit
                XCTAssertEqual(scriptCount, shouldUseScript ? 1 : 0, "Native outcome: \(outcome)")
                XCTAssertEqual(keyboardCount, 0, "Native outcome: \(outcome)")
                XCTAssertEqual(result, outcome == .success || shouldUseScript ? .success : .copiedOnly)
            }
        }
    }

    func testListPasteProofRequiresSameFocusedElementAndExactRange() {
        let expected = CFRange(location: 24, length: 18)
        XCTAssertTrue(pasteTargetProofMatches(
            expected: expected,
            actual: expected,
            sameFocusedElement: true
        ))
        XCTAssertFalse(pasteTargetProofMatches(
            expected: expected,
            actual: CFRange(location: 24, length: 5),
            sameFocusedElement: true
        ))
        XCTAssertFalse(pasteTargetProofMatches(
            expected: expected,
            actual: expected,
            sameFocusedElement: false
        ))
    }

    func testSameDestinationSupportsFallbackAndSuccessfulScriptDoesNotDoublePaste() async {
        var pastes = 0
        let fallbackResult = await TextInserter.deliverToTarget(
            isTargetReady: { true }, pasteScript: { .preDispatchFailed },
            pasteEvent: { pastes += 1; return true }
        )
        XCTAssertEqual(fallbackResult, .success)
        XCTAssertEqual(pastes, 1)
        let scriptResult = await TextInserter.deliverToTarget(
            isTargetReady: { true }, pasteScript: { .success },
            pasteEvent: { pastes += 1; return true }
        )
        XCTAssertEqual(scriptResult, .success)
        XCTAssertEqual(pastes, 1)
    }

    func testLiteralEnvironmentFieldRoutesToSecureStorage() {
        var saved: String?
        let name = OpenRouterCredentialPreferences.environmentName(for: "  sk-or-test-fixture\n") { saved = $0 }
        XCTAssertEqual(saved, "sk-or-test-fixture")
        XCTAssertEqual(name, OpenRouterPostProcessingService.defaultAPIKeyEnvironmentVariable)
        saved = nil
        XCTAssertEqual(OpenRouterCredentialPreferences.environmentName(for: "CUSTOM_API_KEY") { saved = $0 }, "CUSTOM_API_KEY")
        XCTAssertNil(saved)
    }

    func testLegacyKeyIsOnlyRemovedAfterSuccessfulSecureWrite() {
        withDefaults { defaults in
            let key = "sk-or-legacy-fixture"
            defaults.set(key, forKey: OpenRouterCredentialPreferences.preferenceKey)
            let migrated = OpenRouterCredentialPreferences.migrate(defaults: defaults, storedKey: "") { value in
                XCTAssertEqual(value, key)
                XCTAssertEqual(defaults.string(forKey: OpenRouterCredentialPreferences.preferenceKey), key)
                return true
            }
            XCTAssertEqual(migrated.apiKey, key)
            XCTAssertNil(migrated.error)
            XCTAssertEqual(defaults.string(forKey: OpenRouterCredentialPreferences.preferenceKey), migrated.environmentName)
            XCTAssertFalse(OpenRouterCredentialPreferences.isKey(migrated.environmentName))
        }
    }

    func testExistingKeychainCredentialWinsAndScrubsStalePreference() {
        withDefaults { defaults in
            defaults.set("sk-or-obsolete-fixture", forKey: OpenRouterCredentialPreferences.preferenceKey)
            let migrated = OpenRouterCredentialPreferences.migrate(defaults: defaults, storedKey: "sk-or-current-fixture") { _ in
                XCTFail("Must not replace the current key"); return false
            }
            XCTAssertEqual(migrated.apiKey, "sk-or-current-fixture")
            XCTAssertNil(migrated.error)
            XCTAssertEqual(defaults.string(forKey: OpenRouterCredentialPreferences.preferenceKey), migrated.environmentName)
        }
    }

    func testKeychainFailureRetainsRecoverableCopyAndRetryScrubsIt() {
        withDefaults { defaults in
            let key = "sk-or-legacy-fixture"
            defaults.set(key, forKey: OpenRouterCredentialPreferences.preferenceKey)
            let failed = OpenRouterCredentialPreferences.migrate(defaults: defaults, storedKey: "") { _ in false }
            XCTAssertEqual(failed.apiKey, key)
            XCTAssertNotNil(failed.error)
            XCTAssertFalse(OpenRouterCredentialPreferences.isKey(failed.environmentName))
            XCTAssertEqual(defaults.string(forKey: OpenRouterCredentialPreferences.preferenceKey), key)
            let retried = OpenRouterCredentialPreferences.migrate(defaults: defaults, storedKey: "") { _ in true }
            XCTAssertNil(retried.error)
            XCTAssertEqual(defaults.string(forKey: OpenRouterCredentialPreferences.preferenceKey), retried.environmentName)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "PrivacyRegressionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
