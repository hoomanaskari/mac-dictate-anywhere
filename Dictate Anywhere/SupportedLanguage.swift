//
//  SupportedLanguage.swift
//  Dictate Anywhere
//
//  Defines the 25 European languages supported by FluidAudio's Parakeet model.
//

import Foundation

/// Languages supported by FluidAudio's Parakeet TDT model for transcription.
enum SupportedLanguage: String, CaseIterable, Identifiable, Codable {
    // Germanic languages
    case english = "en"
    case german = "de"
    case dutch = "nl"
    case swedish = "sv"
    case danish = "da"
    case norwegian = "no"

    // Romance languages
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt"
    case romanian = "ro"

    // Slavic languages
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case bulgarian = "bg"
    case ukrainian = "uk"
    case russian = "ru"

    // Baltic languages
    case latvian = "lv"
    case lithuanian = "lt"
    case estonian = "et"

    // Other European languages
    case hungarian = "hu"
    case finnish = "fi"
    case greek = "el"

    var id: String { rawValue }

    /// The English display name for this language.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "German"
        case .dutch: return "Dutch"
        case .swedish: return "Swedish"
        case .danish: return "Danish"
        case .norwegian: return "Norwegian"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .polish: return "Polish"
        case .czech: return "Czech"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .croatian: return "Croatian"
        case .bulgarian: return "Bulgarian"
        case .ukrainian: return "Ukrainian"
        case .russian: return "Russian"
        case .latvian: return "Latvian"
        case .lithuanian: return "Lithuanian"
        case .estonian: return "Estonian"
        case .hungarian: return "Hungarian"
        case .finnish: return "Finnish"
        case .greek: return "Greek"
        }
    }

    /// The native name of this language in its own script.
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        case .dutch: return "Nederlands"
        case .swedish: return "Svenska"
        case .danish: return "Dansk"
        case .norwegian: return "Norsk"
        case .spanish: return "Espa\u{00F1}ol"
        case .french: return "Fran\u{00E7}ais"
        case .italian: return "Italiano"
        case .portuguese: return "Portugu\u{00EA}s"
        case .romanian: return "Rom\u{00E2}n\u{0103}"
        case .polish: return "Polski"
        case .czech: return "\u{010C}e\u{0161}tina"
        case .slovak: return "Sloven\u{010D}ina"
        case .slovenian: return "Sloven\u{0161}\u{010D}ina"
        case .croatian: return "Hrvatski"
        case .bulgarian: return "\u{0411}\u{044A}\u{043B}\u{0433}\u{0430}\u{0440}\u{0441}\u{043A}\u{0438}"
        case .ukrainian: return "\u{0423}\u{043A}\u{0440}\u{0430}\u{0457}\u{043D}\u{0441}\u{044C}\u{043A}\u{0430}"
        case .russian: return "\u{0420}\u{0443}\u{0441}\u{0441}\u{043A}\u{0438}\u{0439}"
        case .latvian: return "Latvie\u{0161}u"
        case .lithuanian: return "Lietuvi\u{0173}"
        case .estonian: return "Eesti"
        case .hungarian: return "Magyar"
        case .finnish: return "Suomi"
        case .greek: return "\u{0395}\u{03BB}\u{03BB}\u{03B7}\u{03BD}\u{03B9}\u{03BA}\u{03AC}"
        }
    }

    /// Flag emoji for visual identification.
    var flag: String {
        switch self {
        case .english: return "\u{1F1EC}\u{1F1E7}"
        case .german: return "\u{1F1E9}\u{1F1EA}"
        case .dutch: return "\u{1F1F3}\u{1F1F1}"
        case .swedish: return "\u{1F1F8}\u{1F1EA}"
        case .danish: return "\u{1F1E9}\u{1F1F0}"
        case .norwegian: return "\u{1F1F3}\u{1F1F4}"
        case .spanish: return "\u{1F1EA}\u{1F1F8}"
        case .french: return "\u{1F1EB}\u{1F1F7}"
        case .italian: return "\u{1F1EE}\u{1F1F9}"
        case .portuguese: return "\u{1F1F5}\u{1F1F9}"
        case .romanian: return "\u{1F1F7}\u{1F1F4}"
        case .polish: return "\u{1F1F5}\u{1F1F1}"
        case .czech: return "\u{1F1E8}\u{1F1FF}"
        case .slovak: return "\u{1F1F8}\u{1F1F0}"
        case .slovenian: return "\u{1F1F8}\u{1F1EE}"
        case .croatian: return "\u{1F1ED}\u{1F1F7}"
        case .bulgarian: return "\u{1F1E7}\u{1F1EC}"
        case .ukrainian: return "\u{1F1FA}\u{1F1E6}"
        case .russian: return "\u{1F1F7}\u{1F1FA}"
        case .latvian: return "\u{1F1F1}\u{1F1FB}"
        case .lithuanian: return "\u{1F1F1}\u{1F1F9}"
        case .estonian: return "\u{1F1EA}\u{1F1EA}"
        case .hungarian: return "\u{1F1ED}\u{1F1FA}"
        case .finnish: return "\u{1F1EB}\u{1F1EE}"
        case .greek: return "\u{1F1EC}\u{1F1F7}"
        }
    }

    /// Combined display for UI: flag + display name
    var displayWithFlag: String {
        "\(flag) \(displayName)"
    }
}
