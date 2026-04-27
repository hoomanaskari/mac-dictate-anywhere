//
//  VocabularyInput.swift
//  Dictate Anywhere
//
//  Shared custom vocabulary parsing and chip UI.
//

import SwiftUI

enum VocabularyInputParser {
    static func terms(from input: String, existingTerms: [String]) -> [String] {
        var seen = Set(existingTerms)
        var parsedTerms: [String] = []

        for rawTerm in input.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !seen.contains(term) else { continue }
            seen.insert(term)
            parsedTerms.append(term)
        }

        return parsedTerms
    }
}

struct VocabularyChip: View {
    let term: String
    var font: Font = .caption
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 4
    var backgroundColor = Color(nsColor: .quaternaryLabelColor)
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(term)")
        }
        .frame(maxWidth: 260)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background {
            Capsule()
                .fill(backgroundColor)
        }
        .clipShape(Capsule())
    }
}
