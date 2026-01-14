import Foundation
import SwiftUI

/// Category of model based on speed/accuracy tradeoff
enum ModelCategory: String, CaseIterable {
    case fast           // Fastest, basic accuracy
    case balanced       // Good balance
    case accurate       // Better accuracy
    case best           // Highest accuracy
    case fastAccurate   // Distilled - fast and accurate

    var displayName: String {
        switch self {
        case .fast: return "Fastest"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        case .best: return "Best"
        case .fastAccurate: return "Fast + Accurate"
        }
    }

    var icon: String {
        switch self {
        case .fast: return "bolt.fill"
        case .balanced: return "scalemass.fill"
        case .accurate: return "target"
        case .best: return "star.fill"
        case .fastAccurate: return "flame.fill"
        }
    }

    var color: Color {
        switch self {
        case .fast: return .yellow
        case .balanced: return .blue
        case .accurate: return .purple
        case .best: return .orange
        case .fastAccurate: return .orange
        }
    }
}

/// Represents a WhisperKit model that can be downloaded and used
struct WhisperModel: Identifiable, Equatable {
    let id: String              // e.g., "openai_whisper-base"
    let displayName: String     // e.g., "Base"
    let size: String            // e.g., "74 MB"
    let sizeBytes: Int64        // For comparison
    let category: ModelCategory
    let isEnglishOnly: Bool
    let description: String

    /// The variant name used by WhisperKit (without "openai_whisper-" prefix for standard models)
    var whisperKitVariant: String {
        // WhisperKit uses short names like "base", "small", etc.
        if id.hasPrefix("openai_whisper-") {
            return String(id.dropFirst("openai_whisper-".count))
        } else if id.hasPrefix("distil-whisper_") {
            // Distil models use the full ID
            return id
        }
        return id
    }

    static func == (lhs: WhisperModel, rhs: WhisperModel) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Available Models

extension WhisperModel {
    /// All available WhisperKit models
    static let allModels: [WhisperModel] = [
        // Tiny models - Fastest
        WhisperModel(
            id: "openai_whisper-tiny",
            displayName: "Tiny",
            size: "39 MB",
            sizeBytes: 39_000_000,
            category: .fast,
            isEnglishOnly: false,
            description: "Fastest transcription, basic accuracy. Great for quick notes."
        ),
        WhisperModel(
            id: "openai_whisper-tiny.en",
            displayName: "Tiny (English)",
            size: "39 MB",
            sizeBytes: 39_000_000,
            category: .fast,
            isEnglishOnly: true,
            description: "English-only version, slightly faster and more accurate for English."
        ),

        // Base models - Balanced
        WhisperModel(
            id: "openai_whisper-base",
            displayName: "Base",
            size: "74 MB",
            sizeBytes: 74_000_000,
            category: .balanced,
            isEnglishOnly: false,
            description: "Good balance of speed and accuracy. Recommended for most users."
        ),
        WhisperModel(
            id: "openai_whisper-base.en",
            displayName: "Base (English)",
            size: "74 MB",
            sizeBytes: 74_000_000,
            category: .balanced,
            isEnglishOnly: true,
            description: "English-only version with improved accuracy for English speech."
        ),

        // Small models - Accurate
        WhisperModel(
            id: "openai_whisper-small",
            displayName: "Small",
            size: "244 MB",
            sizeBytes: 244_000_000,
            category: .accurate,
            isEnglishOnly: false,
            description: "Better accuracy for complex speech and accents."
        ),
        WhisperModel(
            id: "openai_whisper-small.en",
            displayName: "Small (English)",
            size: "217 MB",
            sizeBytes: 217_000_000,
            category: .accurate,
            isEnglishOnly: true,
            description: "English-optimized with excellent accuracy."
        ),

        // Medium model - Accurate
        WhisperModel(
            id: "openai_whisper-medium",
            displayName: "Medium",
            size: "769 MB",
            sizeBytes: 769_000_000,
            category: .accurate,
            isEnglishOnly: false,
            description: "High accuracy for professional transcription needs."
        ),

        // Large model - Best
        WhisperModel(
            id: "openai_whisper-large-v3",
            displayName: "Large v3",
            size: "1.5 GB",
            sizeBytes: 1_500_000_000,
            category: .best,
            isEnglishOnly: false,
            description: "Highest accuracy available. Best for critical transcriptions."
        ),

        // Distil model - Fast + Accurate
        WhisperModel(
            id: "distil-whisper_distil-large-v3",
            displayName: "Distil Large",
            size: "594 MB",
            sizeBytes: 594_000_000,
            category: .fastAccurate,
            isEnglishOnly: false,
            description: "Distilled model with great speed/accuracy balance."
        ),
    ]

    /// Find a model by its ID
    static func find(byId id: String) -> WhisperModel? {
        allModels.first { $0.id == id }
    }

    /// Find a model by its WhisperKit variant name
    static func find(byVariant variant: String) -> WhisperModel? {
        allModels.first { $0.whisperKitVariant == variant }
    }
}
