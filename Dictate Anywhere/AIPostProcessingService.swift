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
        let instructions = """
            \(prompt)

            Output ONLY the processed text. Do not include any preamble, explanation, or commentary.
            """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        return response.content
    }
}
