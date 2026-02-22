//
//  AIPostProcessingService.swift
//  Dictate Anywhere
//
//  On-device AI text processing via Apple's Foundation Models framework.
//

import FoundationModels

@available(macOS 26, *)
enum AIPostProcessingService {

    static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    static func process(text: String, prompt: String) async throws -> String {
        let session = LanguageModelSession()
        let response = try await session.respond(to: "\(prompt)\n\n\(text)")
        return response.content
    }
}
