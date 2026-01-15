import Foundation

/// Represents the WhisperKit model used for transcription
struct WhisperModel: Identifiable, Equatable {
    let id: String
    let size: String
    let sizeBytes: Int64

    /// The variant name used by WhisperKit
    var whisperKitVariant: String {
        id
    }

    static func == (lhs: WhisperModel, rhs: WhisperModel) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Default Model

extension WhisperModel {
    /// The default (and only) model used by the app
    static let defaultModel = WhisperModel(
        id: "distil-whisper_distil-large-v3",
        size: "594 MB",
        sizeBytes: 594_000_000
    )
}
