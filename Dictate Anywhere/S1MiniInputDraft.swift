/// Proposes request-local transcript continuations. Only verifier-approved tokens
/// become output; short matches propose smaller blocks to bound rejected work.
nonisolated struct S1MiniInputDraft {
    /// Propose sentence capitals only for styles that request them; the model input stays raw.
    static func proposalSource(_ text: String, styling: S1MiniStyling) -> String {
        switch styling {
        case .casual, .semiCasual: text
        case .semiFormal, .formal: sentenceCasedSource(text)
        }
    }

    /// Keep every other character intact; the verifier decides whether each proposal is valid.
    private static func sentenceCasedSource(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var capitalize = true
        for index in text.indices {
            let character = text[index]
            if capitalize && character.isLetter {
                result.append(contentsOf: String(character).uppercased())
                capitalize = false
            } else {
                result.append(character)
                if character.isNumber { capitalize = false }
            }
            let next = text.index(after: index)
            if character.isNewline || ((character == "." || character == "!" || character == "?")
                && (next == text.endIndex || text[next].isWhitespace)) {
                capitalize = true
            }
        }
        return result
    }

    private let tokens: [Int]
    private let positions: [Int: [Int]]
    private var suffix: [Int] = []
    private var cursor = 0

    init(tokens: [Int]) {
        self.tokens = tokens
        var positions: [Int: [Int]] = [:]
        for index in tokens.indices.dropLast() {
            positions[tokens[index], default: []].append(index)
        }
        self.positions = positions
    }

    mutating func didEmit(_ token: Int) {
        suffix.append(token)
        if suffix.count > 4 { suffix.removeFirst() }
    }

    mutating func propose(maximumTokens: Int) -> [Int] {
        guard maximumTokens > 0, let last = suffix.last,
              let candidates = positions[last] else { return [] }
        for width in stride(from: suffix.count, through: 1, by: -1) {
            var earlier: Int?
            for position in candidates {
                let end = position + 1
                guard end >= width,
                      tokens[(end - width)..<end].elementsEqual(suffix.suffix(width)) else { continue }
                if end >= cursor {
                    cursor = end
                    return continuation(after: end, matchLength: width, maximumTokens: maximumTokens)
                }
                if earlier == nil { earlier = end }
            }
            if let earlier {
                cursor = earlier
                return continuation(after: earlier, matchLength: width, maximumTokens: maximumTokens)
            }
        }
        return []
    }

    private func continuation(after end: Int, matchLength: Int, maximumTokens: Int) -> [Int] {
        let count = matchLength == 1 ? min(maximumTokens, 4) : maximumTokens
        return Array(tokens[end..<min(tokens.count, end + count)])
    }
}
