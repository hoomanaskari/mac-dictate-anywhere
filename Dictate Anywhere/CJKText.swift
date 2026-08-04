//
//  CJKText.swift
//  Dictate Anywhere
//
//  Shared helpers for CJK-aware text handling (spacing, punctuation).
//

import Foundation

/// `nonisolated` because the target defaults to `MainActor` isolation
/// (`SWIFT_DEFAULT_ACTOR_ISOLATION`) and these are pure text predicates with no
/// state: the chunk-seam join runs off the main actor, and isolating them there
/// only produces Swift 6 warnings at every such call site.
nonisolated enum CJKText {
    /// Han ideograph ranges (BMP unified + extension A + compatibility).
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF,      // CJK Unified Ideographs
             0x3400...0x4DBF,      // Extension A
             0xF900...0xFAFF,      // Compatibility Ideographs
             0x20000...0x2EBEF:    // Extensions B–F (SIP)
            return true
        default:
            return false
        }
    }

    /// Fullwidth/CJK sentence-terminal and clause punctuation.
    static let cjkTerminalPunctuation: Set<UInt32> = [
        0x3002, // 。
        0xFF01, // ！
        0xFF1F, // ？
        0xFF0C, // ，
        0x3001, // 、
        0xFF1B, // ；
        0xFF1A, // ：
    ]

    /// CJK closing brackets/quotes that may trail terminal punctuation.
    static let cjkClosingPunctuation: Set<UInt32> = [
        0x300D, // 」
        0x300F, // 』
        0xFF09, // ）
        0x3011, // 】
        0x3009, // 〉
        0x300B, // 》
    ]

    /// CJK opening brackets/quotes.
    ///
    /// These are *not* members of `cjkAttachedLeadingPunctuation`: closing and
    /// terminal punctuation belong to the text on their left and so never take
    /// a space before them, but an opener belongs to the text on its **right**.
    /// Whether a space belongs in front of one therefore depends on the left
    /// side — none inside CJK ("他说「你好」"), a normal one after Latin
    /// ("he said 「你好」").
    static let cjkOpeningPunctuation: Set<UInt32> = [
        0x300C, // 「
        0x300E, // 『
        0xFF08, // （
        0x3010, // 【
        0x3008, // 〈
        0x300A, // 《
    ]

    /// CJK punctuation that must never receive a space before it.
    static let cjkAttachedLeadingPunctuation: Set<UInt32> =
        cjkTerminalPunctuation.union(cjkClosingPunctuation).union([0x2026])

    /// Trailing scalars `endsWithCJK` looks past before judging the content.
    ///
    /// Openers are included even though they are absent from
    /// `cjkAttachedLeadingPunctuation`: the two sets answer different
    /// questions. Here the question is "is the text to the left CJK?", and a
    /// chunk truncated straight after an opener ("他说「") still is — skipping
    /// the bracket reaches 说 and keeps the next chunk attached ("他说「你好"),
    /// whereas stopping on the bracket would inject a space after it.
    static let endsWithCJKSkippedTrailingScalars: Set<UInt32> =
        cjkAttachedLeadingPunctuation
        .union(cjkOpeningPunctuation)
        .union([34, 39, 41, 93, 125, 0x2019, 0x201D])  // ASCII/Latin closers

    static func startsWithCJK(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return isCJK(first)
    }

    /// True when the last non-trailing-punctuation scalar is a Han ideograph.
    ///
    /// Skips CJK terminal punctuation (。！？，、；：), closing brackets/quotes
    /// and opening brackets/quotes — a chunk transcript ending in "…好。" or in
    /// "…说「" is still CJK content for spacing purposes (ASR's ITN commonly
    /// closes a truncated chunk with a fullwidth period even mid-utterance).
    /// See `endsWithCJKSkippedTrailingScalars`.
    static func endsWithCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.reversed() {
            if endsWithCJKSkippedTrailingScalars.contains(scalar.value) { continue }
            return isCJK(scalar)
        }
        return false
    }
}
