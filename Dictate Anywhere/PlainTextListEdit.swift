import Foundation

/// A local, bounded replacement extending through affected literal ordinals.
/// Rich editors own their numbering and never use this path.
struct PlainTextListEdit {
    /// A verified snapshot can require an ordinary paste without a replacement.
    struct Preparation {
        let edit: PlainTextListEdit?
    }

    let range: NSRange
    let replacement: String
    let expectedValue: String
    let caretLocation: Int

    static func needsRenumbering(insertion: String, context: DictationContext) -> Bool {
        guard !context.isSecureField, !context.isContextExcluded,
              let list = context.listItemInsertion, !list.isEmptyStructuralItem,
              let marker = list.literalMarker, Int(marker.dropLast()) != nil else { return false }
        return insertion.contains(where: \.isNewline)
    }

    static func prepare(value: String, selection: NSRange, insertion: String,
                        context: DictationContext) -> Preparation? {
        let original = value as NSString
        guard needsRenumbering(insertion: insertion, context: context),
              original.length <= 100_000, selection.length == 0,
              selection.location >= 0, selection.location <= original.length,
              let before = context.textBeforeCursor, !before.isEmpty,
              let after = context.textAfterCursor, context.selectedText?.isEmpty != false,
              original.substring(to: selection.location).hasSuffix(before),
              original.substring(from: selection.location).hasPrefix(after),
              let list = context.listItemInsertion, let marker = list.literalMarker,
              let number = Int(marker.dropLast()), let delimiter = marker.last else { return nil }
        let tail = original.substring(from: selection.location) as NSString
        // The insertion point must be in an otherwise empty item.
        let lines = tail.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true else { return nil }
        let added = insertion.components(separatedBy: "\n").count - 1
        let pattern = #"^(\h*)([0-9]{1,4})([.)])(?=\h|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var expectedOrdinal = number + 1
        var offset = (lines.first! as NSString).length + 1
        var replacements: [(NSRange, String)] = []
        for line in lines.dropFirst() {
            let nsLine = line as NSString
            defer { offset += nsLine.length + 1 }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            // Preserve nested items and indented continuation lines verbatim.
            if indent.hasPrefix(list.literalIndent), indent.count > list.literalIndent.count { continue }
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                  nsLine.substring(with: match.range(at: 1)) == list.literalIndent,
                  nsLine.substring(with: match.range(at: 3)) == String(delimiter),
                  Int(nsLine.substring(with: match.range(at: 2))) == expectedOrdinal else { break }
            let digits = match.range(at: 2)
            replacements.append((NSRange(location: offset + digits.location, length: digits.length), String(expectedOrdinal + added)))
            expectedOrdinal += 1
        }
        guard let last = replacements.last else { return Preparation(edit: nil) }
        let tailLength = NSMaxRange(last.0)
        let updatedTail = NSMutableString(string: tail.substring(to: tailLength))
        for (range, replacement) in replacements.reversed() { updatedTail.replaceCharacters(in: range, with: replacement) }
        let range = NSRange(location: selection.location, length: tailLength)
        let replacement = insertion + (updatedTail as String)
        return Preparation(edit: Self(range: range, replacement: replacement,
                    expectedValue: original.replacingCharacters(in: range, with: replacement),
                    caretLocation: selection.location + (insertion as NSString).length))
    }
}
