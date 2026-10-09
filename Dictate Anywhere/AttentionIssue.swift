import Foundation

/// Actionable setup problems shown in the single main-window banner.
/// The order is deliberate: dictation blockers precede optional improvements.
struct AttentionIssue: Identifiable, Equatable {
    enum CleanupProblem: Hashable {
        case fluidAudioVocabularyUnavailable
        case appleIntelligenceRequiresMacOS26
        case appleIntelligenceDeviceIneligible
        case appleIntelligenceNotEnabled
        case appleIntelligenceUnavailable
        case s1MiniLanguageUnsupported
        case s1MiniNotDownloaded
        case ollamaModelMissing
        case openRouterKeyMissing
        case openRouterModelMissing
        case openAICompatibleModelMissing
    }

    enum ID: Hashable {
        case microphone
        case accessibility
        case speechSetup
        case recovery
        case recordingFailed
        case appleSpeechUnsupported
        case cleanup(CleanupProblem)
        case automation
    }

    let id: ID
    let title: String
    let message: String
    let actionTitle: String
    let isOptional: Bool

    static func pending(
        permissionsChecked: Bool,
        microphoneGranted: Bool,
        microphoneCanPrompt: Bool,
        accessibilityGranted: Bool,
        engineChoice: TranscriptionEngineChoice,
        speechSetupNeeded: Bool,
        automationDenied: Bool,
        speechPreparationFailed: Bool = false,
        recoveryError: String? = nil,
        recordingError: String? = nil,
        legacyAppleSpeechMigrationPending: Bool = false,
        appleSpeechUnsupportedSelection: Bool = false,
        appleSpeechRequiresMacOS26: Bool = false,
        cleanupProblems: [CleanupProblem] = []
    ) -> [AttentionIssue] {
        var issues: [AttentionIssue] = []

        if permissionsChecked && !microphoneGranted {
            issues.append(AttentionIssue(
                id: .microphone,
                title: "Microphone access needed",
                message: "Allow microphone access to start dictating.",
                actionTitle: microphoneCanPrompt ? "Allow Microphone" : "Open Settings",
                isOptional: false
            ))
        }

        if permissionsChecked && !accessibilityGranted {
            issues.append(AttentionIssue(
                id: .accessibility,
                title: "Accessibility access needed",
                message: "Allow Accessibility for shortcuts and pasting.",
                actionTitle: "Open Settings",
                isOptional: false
            ))
        }

        if speechSetupNeeded {
            let message: String
            switch engineChoice {
            case .appleSpeech:
                message = speechPreparationFailed
                    ? "Apple Speech could not be prepared. Review Speech Model settings."
                    : "Set up Apple Speech to start dictating."
            case .assemblyAI:
                message = "Add an AssemblyAI API key to start dictating."
            case .parakeet:
                if speechPreparationFailed {
                    message = "The speech model could not be prepared. Review Speech Model settings."
                } else if legacyAppleSpeechMigrationPending {
                    message = "Apple Speech is unavailable here. Download a FluidAudio model to keep dictating."
                } else {
                    message = "Download a speech model to start dictating."
                }
            }
            issues.append(AttentionIssue(
                id: .speechSetup,
                title: "Dictation setup needed",
                message: message,
                actionTitle: "Set Up",
                isOptional: false
            ))
        }

        if let recoveryError, !recoveryError.isEmpty {
            issues.append(AttentionIssue(
                id: .recovery,
                title: "Dictation recovery needs attention",
                message: recoveryError,
                actionTitle: "Dismiss",
                isOptional: false
            ))
        }

        if let recordingError, !recordingError.isEmpty, microphoneGranted {
            issues.append(AttentionIssue(
                id: .recordingFailed,
                title: "Recording could not start",
                message: recordingError,
                actionTitle: "Dismiss",
                isOptional: false
            ))
        }

        if appleSpeechUnsupportedSelection {
            issues.append(AttentionIssue(
                id: .appleSpeechUnsupported,
                title: "Apple Speech is unavailable",
                message: appleSpeechRequiresMacOS26
                    ? "Apple Speech requires macOS 26 or later. Choose another speech engine."
                    : "Apple Speech is unavailable on this Mac. Choose another speech engine.",
                actionTitle: "Dismiss",
                isOptional: true
            ))
        }

        for problem in cleanupProblems {
            issues.append(cleanupIssue(problem))
        }

        if permissionsChecked && automationDenied {
            issues.append(AttentionIssue(
                id: .automation,
                title: "System Events access is off",
                message: "Allow System Events for AppleScript paste. Keyboard paste still works.",
                actionTitle: "Open Settings",
                isOptional: true
            ))
        }

        return issues
    }

    private static func cleanupIssue(_ problem: CleanupProblem) -> AttentionIssue {
        let message: String
        switch problem {
        case .fluidAudioVocabularyUnavailable:
            message = "Vocabulary correction needs Parakeet v2, v3, 110M, Ultra, or Nemotron 3.5. Choose a compatible model on the Speech Model page."
        case .appleIntelligenceRequiresMacOS26:
            message = "Apple Intelligence cleanup requires macOS 26 or later. Choose another method."
        case .appleIntelligenceDeviceIneligible:
            message = "Apple Intelligence is unavailable on this Mac. Choose another cleanup method."
        case .appleIntelligenceNotEnabled:
            message = "Enable Apple Intelligence in System Settings to use it for cleanup."
        case .appleIntelligenceUnavailable:
            message = "Apple Intelligence is unavailable right now. Try again or choose another method."
        case .s1MiniLanguageUnsupported:
            message = "S1-mini cleans up English only. Other languages are pasted without S1-mini cleanup."
        case .s1MiniNotDownloaded:
            message = "Download S1-mini to use local transcript cleanup."
        case .ollamaModelMissing:
            message = "Choose an Ollama model to use transcript cleanup."
        case .openRouterKeyMissing:
            message = "Add an OpenRouter API key to use transcript cleanup."
        case .openRouterModelMissing:
            message = "Choose an OpenRouter model to use transcript cleanup."
        case .openAICompatibleModelMissing:
            message = "Choose a model on your OpenAI-compatible server to use transcript cleanup."
        }
        let actionTitle: String
        switch problem {
        case .fluidAudioVocabularyUnavailable: actionTitle = "Open Speech Model"
        case .appleIntelligenceNotEnabled: actionTitle = "Open Settings"
        default: actionTitle = "View Setup"
        }
        return AttentionIssue(
            id: .cleanup(problem),
            title: "Transcript cleanup needs attention",
            message: message,
            actionTitle: actionTitle,
            isOptional: true
        )
    }
}
