import Foundation

/// Pure subtitle preference logic shared by playback (`AppState`) and unit tests.
enum SubtitleSelectionLogic {

    /// Maps stored settings (`__system__` → device locale primary language).
    static func resolvedLanguageCode(storedCode: String, locale: Locale) -> String {
        if storedCode == "__system__" {
            if #available(tvOS 16.0, iOS 16.0, macOS 13.0, watchOS 9.0, *) {
                return locale.language.languageCode?.identifier ?? "en"
            }
            return localeLanguageFallback(locale)
        }
        return storedCode
    }

    private static func localeLanguageFallback(_ locale: Locale) -> String {
        let raw = locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if let idx = raw.firstIndex(of: "-") {
            return String(raw[..<idx])
        }
        return raw.isEmpty ? "en" : raw
    }

    /// Builds a comparable language tag from AVFoundation option metadata (matches previous AppState behavior).
    /// Three-letter tags are folded to their two-letter form: Jellyfin and Emby label HLS
    /// renditions with the ISO 639-2 code from the file ("eng"), while the settings store "en".
    static func languageTagForComparison(extendedLanguageTag: String?, localeIdentifier: String?) -> String? {
        if let ext = extendedLanguageTag, !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return twoLetterPrimary(ext.lowercased())
        }
        guard let lid = localeIdentifier else { return nil }
        let raw = lid.replacingOccurrences(of: "_", with: "-").lowercased()
        if let idx = raw.firstIndex(of: "-") {
            return twoLetterPrimary(String(raw[..<idx]))
        }
        return raw.isEmpty ? nil : twoLetterPrimary(raw)
    }

    /// ISO 639-2 (both the /T and /B spellings) → 639-1, for the languages the pickers offer.
    private static let iso639_2to1: [String: String] = [
        "eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
        "ita": "it", "por": "pt", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh",
        "rus": "ru", "ara": "ar", "nld": "nl", "dut": "nl", "pol": "pl", "swe": "sv",
    ]

    private static func twoLetterPrimary(_ tag: String) -> String {
        let parts = tag.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let primary = parts.first, let mapped = iso639_2to1[String(primary)] else { return tag }
        return parts.count > 1 ? mapped + "-" + parts[1] : mapped
    }

    /// True when foreign-audio auto-subtitles should kick in: every audio track's language is
    /// KNOWN and none match the preferred audio language. Any unknown/empty/`und` tag disables
    /// the feature entirely — we can't be sure there is no match, so never guess.
    static func shouldAutoEnableSubtitles(audioTags: [String?], preferredAudioLowercased: String) -> Bool {
        guard !audioTags.isEmpty else { return false }
        for tag in audioTags {
            guard let t = tag?.lowercased(), !t.isEmpty, t != "und" else { return false }
            if t == preferredAudioLowercased || t.hasPrefix(preferredAudioLowercased + "-") { return false }
        }
        return true
    }

    /// Index of the best option for `preferredLowercased` (BCP‑47 primary or full tag); falls back to `0`.
    static func preferredTrackIndex(tags: [String?], preferredLowercased: String) -> Int {
        let want = preferredLowercased
        if let idx = tags.firstIndex(where: { tag in
            guard let t = tag?.lowercased() else { return false }
            return t == want || t.hasPrefix(want + "-")
        }) {
            return idx
        }
        return 0
    }
}
