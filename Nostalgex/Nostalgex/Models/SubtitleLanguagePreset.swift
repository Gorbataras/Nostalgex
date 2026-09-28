import Foundation

/// The language list offered by every language picker in the app. Despite the name it
/// backs both the subtitle and the audio preference — they share one vocabulary so a
/// household that picks "GERMAN" gets the same code on both settings.
///
/// Lives here rather than next to the settings page because the in-player Now Playing
/// panel offers the same two settings mid-playback and must show identical labels.
struct SubtitleLanguagePreset: Identifiable, Hashable {
    let id: String
    let code: String
    let label: String

    /// Sentinel meaning "follow the Apple TV's own language" rather than a fixed choice.
    static let systemCode = "__system__"

    static let all: [SubtitleLanguagePreset] = [
        .init(id: "system", code: systemCode, label: "MATCH APPLE TV LANGUAGE"),
        .init(id: "en", code: "en", label: "ENGLISH"),
        .init(id: "es", code: "es", label: "SPANISH"),
        .init(id: "fr", code: "fr", label: "FRENCH"),
        .init(id: "de", code: "de", label: "GERMAN"),
        .init(id: "it", code: "it", label: "ITALIAN"),
        .init(id: "ptBR", code: "pt-BR", label: "PORTUGUESE (BRAZIL)"),
        .init(id: "ja", code: "ja", label: "JAPANESE"),
        .init(id: "ko", code: "ko", label: "KOREAN"),
        .init(id: "zhHans", code: "zh-Hans", label: "CHINESE (SIMPLIFIED)"),
        .init(id: "zhHant", code: "zh-Hant", label: "CHINESE (TRADITIONAL)"),
        .init(id: "ru", code: "ru", label: "RUSSIAN"),
        .init(id: "ar", code: "ar", label: "ARABIC"),
        .init(id: "nl", code: "nl", label: "DUTCH"),
        .init(id: "pl", code: "pl", label: "POLISH"),
        .init(id: "sv", code: "sv", label: "SWEDISH"),
    ]

    static func displayLabel(for code: String) -> String {
        all.first { $0.code == code }?.label ?? code.uppercased()
    }

    /// Compact form for a row that already spends most of its width on the setting's
    /// title, i.e. the in-player panel. "MATCH APPLE TV LANGUAGE" does not fit there;
    /// the full label is still what the picker itself shows.
    static func shortLabel(for code: String) -> String {
        code == systemCode ? "SYSTEM" : code.uppercased()
    }
}
