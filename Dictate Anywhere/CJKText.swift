//
//  CJKText.swift
//  Dictate Anywhere
//
//  Shared helpers for CJK-aware text handling (spacing, punctuation).
//

import Foundation

enum CJKText {
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

    /// CJK punctuation that must never receive a space before it.
    static let cjkAttachedLeadingPunctuation: Set<UInt32> =
        cjkTerminalPunctuation.union(cjkClosingPunctuation).union([0x2026])

    static func startsWithCJK(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return isCJK(first)
    }

    /// True when the last non-closing-punctuation scalar is a Han ideograph.
    static func endsWithCJK(_ text: String) -> Bool {
        let asciiClosers: Set<UInt32> = [34, 39, 41, 93, 125, 0x2019, 0x201D]
        for scalar in text.unicodeScalars.reversed() {
            if asciiClosers.contains(scalar.value) || cjkClosingPunctuation.contains(scalar.value) {
                continue
            }
            return isCJK(scalar)
        }
        return false
    }
}
