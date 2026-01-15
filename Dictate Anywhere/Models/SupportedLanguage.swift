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
        case .spanish: return "Español"
        case .french: return "Français"
        case .italian: return "Italiano"
        case .portuguese: return "Português"
        case .romanian: return "Română"
        case .polish: return "Polski"
        case .czech: return "Čeština"
        case .slovak: return "Slovenčina"
        case .slovenian: return "Slovenščina"
        case .croatian: return "Hrvatski"
        case .bulgarian: return "Български"
        case .ukrainian: return "Українська"
        case .russian: return "Русский"
        case .latvian: return "Latviešu"
        case .lithuanian: return "Lietuvių"
        case .estonian: return "Eesti"
        case .hungarian: return "Magyar"
        case .finnish: return "Suomi"
        case .greek: return "Ελληνικά"
        }
    }

    /// Flag emoji for visual identification.
    var flag: String {
        switch self {
        case .english: return "🇬🇧"
        case .german: return "🇩🇪"
        case .dutch: return "🇳🇱"
        case .swedish: return "🇸🇪"
        case .danish: return "🇩🇰"
        case .norwegian: return "🇳🇴"
        case .spanish: return "🇪🇸"
        case .french: return "🇫🇷"
        case .italian: return "🇮🇹"
        case .portuguese: return "🇵🇹"
        case .romanian: return "🇷🇴"
        case .polish: return "🇵🇱"
        case .czech: return "🇨🇿"
        case .slovak: return "🇸🇰"
        case .slovenian: return "🇸🇮"
        case .croatian: return "🇭🇷"
        case .bulgarian: return "🇧🇬"
        case .ukrainian: return "🇺🇦"
        case .russian: return "🇷🇺"
        case .latvian: return "🇱🇻"
        case .lithuanian: return "🇱🇹"
        case .estonian: return "🇪🇪"
        case .hungarian: return "🇭🇺"
        case .finnish: return "🇫🇮"
        case .greek: return "🇬🇷"
        }
    }

    /// Combined display for UI: flag + display name
    var displayWithFlag: String {
        "\(flag) \(displayName)"
    }
}
