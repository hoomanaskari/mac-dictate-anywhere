import AppKit
import XCTest
@testable import Dictate_Anywhere

final class AttentionIssueTests: XCTestCase {
    func testPermissionWarningsWaitForInitialAsyncCheck() {
        let issues = AttentionIssue.pending(
            permissionsChecked: false,
            microphoneGranted: false,
            microphoneCanPrompt: false,
            accessibilityGranted: false,
            engineChoice: .parakeet,
            speechSetupNeeded: false,
            automationDenied: true
        )

        XCTAssertTrue(issues.isEmpty)
    }

    func testOnlyUnresolvedIssuesAppearInPriorityOrder() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: false,
            microphoneCanPrompt: false,
            accessibilityGranted: false,
            engineChoice: .parakeet,
            speechSetupNeeded: true,
            automationDenied: true
        )

        XCTAssertEqual(issues.map(\.id), [.microphone, .accessibility, .speechSetup, .automation])
        XCTAssertEqual(issues.first?.actionTitle, "Open Settings")
        XCTAssertTrue(issues.last?.isOptional == true)
    }

    func testFirstMicrophoneRequestUsesConsentButtonTitle() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: false,
            microphoneCanPrompt: true,
            accessibilityGranted: true,
            engineChoice: .appleSpeech,
            speechSetupNeeded: false,
            automationDenied: false
        )

        XCTAssertEqual(issues.first?.actionTitle, "Allow Microphone")
    }

    func testReadySetupDoesNotShowIssue() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: true,
            microphoneCanPrompt: false,
            accessibilityGranted: true,
            engineChoice: .appleSpeech,
            speechSetupNeeded: false,
            automationDenied: false
        )

        XCTAssertTrue(issues.isEmpty)
    }

    func testOptionalAutomationIssueAppearsOnlyAfterConfirmedDenial() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: true,
            microphoneCanPrompt: false,
            accessibilityGranted: true,
            engineChoice: .assemblyAI,
            speechSetupNeeded: false,
            automationDenied: true
        )

        XCTAssertEqual(issues.map(\.id), [.automation])
        XCTAssertEqual(PasteScriptOutcome.fromAppleScriptError(nil), .success)
        XCTAssertEqual(
            PasteScriptOutcome.fromAppleScriptError([NSAppleScript.errorNumber: -1743]),
            .automationDenied
        )
        XCTAssertEqual(
            PasteScriptOutcome.fromAppleScriptError([NSAppleScript.errorNumber: -1728]),
            .possiblyDispatched
        )
    }

    func testAppleSpeechAndAssemblyAISetupUseTheSharedCarousel() {
        for engine in [TranscriptionEngineChoice.appleSpeech, .assemblyAI] {
            let issues = AttentionIssue.pending(
                permissionsChecked: true,
                microphoneGranted: true,
                microphoneCanPrompt: false,
                accessibilityGranted: true,
                engineChoice: engine,
                speechSetupNeeded: true,
                automationDenied: false
            )

            XCTAssertEqual(issues.map(\.id), [.speechSetup])
            XCTAssertTrue(issues[0].message.contains(engine == .assemblyAI ? "API key" : "Apple Speech"))
        }
    }

    func testPreparationFailureDoesNotClaimTheModelIsMissing() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: true,
            microphoneCanPrompt: false,
            accessibilityGranted: true,
            engineChoice: .parakeet,
            speechSetupNeeded: true,
            automationDenied: false,
            speechPreparationFailed: true
        )

        XCTAssertEqual(issues.map(\.id), [.speechSetup])
        XCTAssertTrue(issues[0].message.contains("could not be prepared"))
    }

    func testRecoveryErrorJoinsCarouselAndKeepsItsDetails() {
        let message = "Could not continue. Your saved session is still available."
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: true,
            microphoneCanPrompt: false,
            accessibilityGranted: true,
            engineChoice: .parakeet,
            speechSetupNeeded: false,
            automationDenied: true,
            recoveryError: message
        )

        XCTAssertEqual(issues.map(\.id), [.recovery, .automation])
        XCTAssertEqual(issues[0].message, message)
        XCTAssertEqual(issues[0].actionTitle, "Dismiss")
    }

    func testRecordingFailureAppearsUnlessMicrophonePermissionAlreadyExplainsIt() {
        func issues(microphoneGranted: Bool, recoveryError: String? = nil) -> [AttentionIssue.ID] {
            AttentionIssue.pending(
                permissionsChecked: true,
                microphoneGranted: microphoneGranted,
                microphoneCanPrompt: false,
                accessibilityGranted: true,
                engineChoice: .parakeet,
                speechSetupNeeded: false,
                automationDenied: false,
                recoveryError: recoveryError,
                recordingError: "Failed to start recording: no microphone"
            ).map(\.id)
        }

        XCTAssertEqual(issues(microphoneGranted: true), [.recordingFailed])
        XCTAssertEqual(issues(microphoneGranted: false), [.microphone])
        XCTAssertEqual(
            issues(microphoneGranted: true, recoveryError: "Saved session is available"),
            [.recovery, .recordingFailed]
        )
    }

    func testCleanupWarningsJoinTheCarouselWithoutStacking() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: false,
            microphoneCanPrompt: false,
            accessibilityGranted: false,
            engineChoice: .appleSpeech,
            speechSetupNeeded: true,
            automationDenied: true,
            cleanupProblems: [.s1MiniLanguageUnsupported, .s1MiniNotDownloaded]
        )

        XCTAssertEqual(issues.map(\.id), [
            .microphone,
            .accessibility,
            .speechSetup,
            .cleanup(.s1MiniLanguageUnsupported),
            .cleanup(.s1MiniNotDownloaded),
            .automation
        ])
        XCTAssertTrue(issues[3].isOptional)
        XCTAssertTrue(issues[4].isOptional)
    }

    func testUnavailableAppleSpeechAndIntelligenceUseCarouselActions() {
        let issues = AttentionIssue.pending(
            permissionsChecked: true,
            microphoneGranted: true,
            microphoneCanPrompt: false,
            accessibilityGranted: true,
            engineChoice: .parakeet,
            speechSetupNeeded: true,
            automationDenied: false,
            legacyAppleSpeechMigrationPending: true,
            appleSpeechUnsupportedSelection: true,
            appleSpeechRequiresMacOS26: true,
            cleanupProblems: [.appleIntelligenceNotEnabled]
        )

        XCTAssertEqual(issues.map(\.id), [
            .speechSetup,
            .appleSpeechUnsupported,
            .cleanup(.appleIntelligenceNotEnabled)
        ])
        XCTAssertTrue(issues[0].message.contains("FluidAudio"))
        XCTAssertTrue(issues[1].message.contains("macOS 26"))
        XCTAssertEqual(issues[2].actionTitle, "Open Settings")
    }
}
