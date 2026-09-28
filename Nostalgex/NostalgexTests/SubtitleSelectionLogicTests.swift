import XCTest
@testable import Nostalgex

/// Regression tests for fullscreen subtitle language resolution and track matching.
final class SubtitleSelectionLogicTests: XCTestCase {

    // MARK: - resolvedLanguageCode

    func testResolvedLanguage_explicitCode_passesThrough() {
        XCTAssertEqual(
            SubtitleSelectionLogic.resolvedLanguageCode(storedCode: "fr", locale: Locale(identifier: "en_US")),
            "fr"
        )
    }

    func testResolvedLanguage_system_followsLocaleGerman() {
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(
            SubtitleSelectionLogic.resolvedLanguageCode(storedCode: "__system__", locale: de),
            "de"
        )
    }

    func testResolvedLanguage_system_followsLocaleJapanese() {
        let ja = Locale(identifier: "ja_JP")
        XCTAssertEqual(
            SubtitleSelectionLogic.resolvedLanguageCode(storedCode: "__system__", locale: ja),
            "ja"
        )
    }

    // MARK: - languageTagForComparison

    func testLanguageTag_prefersExtendedTagLowercased() {
        XCTAssertEqual(
            SubtitleSelectionLogic.languageTagForComparison(extendedLanguageTag: "en-US", localeIdentifier: "fr_FR"),
            "en-us"
        )
    }

    func testLanguageTag_fallsBackToLocalePrimaryWhenNoExtended() {
        XCTAssertEqual(
            SubtitleSelectionLogic.languageTagForComparison(extendedLanguageTag: nil, localeIdentifier: "es_ES"),
            "es"
        )
    }

    func testLanguageTag_underscoreLocaleNormalized() {
        XCTAssertEqual(
            SubtitleSelectionLogic.languageTagForComparison(extendedLanguageTag: nil, localeIdentifier: "pt_BR"),
            "pt"
        )
    }

    // MARK: - preferredTrackIndex

    func testPreferredTrackIndex_exactPrimaryMatch() {
        let idx = SubtitleSelectionLogic.preferredTrackIndex(
            tags: [Optional("en"), Optional("es")],
            preferredLowercased: "en"
        )
        XCTAssertEqual(idx, 0)
    }

    func testPreferredTrackIndex_regionVariantMatch() {
        let idx = SubtitleSelectionLogic.preferredTrackIndex(
            tags: [Optional("es"), Optional("en-us")],
            preferredLowercased: "en"
        )
        XCTAssertEqual(idx, 1)
    }

    func testPreferredTrackIndex_fallbackToFirstWhenNoMatch() {
        let idx = SubtitleSelectionLogic.preferredTrackIndex(
            tags: [Optional("de"), Optional("fr")],
            preferredLowercased: "ja"
        )
        XCTAssertEqual(idx, 0)
    }

    func testPreferredTrackIndex_nilTags_fallbackZero() {
        let idx = SubtitleSelectionLogic.preferredTrackIndex(
            tags: [nil, Optional("fr")],
            preferredLowercased: "en"
        )
        XCTAssertEqual(idx, 0)
    }

    // MARK: - shouldAutoEnableSubtitles

    func testShouldAutoEnable_foreignOnlyAudio_true() {
        XCTAssertTrue(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [Optional("fr")],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_matchingTrackPresent_false() {
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [Optional("fr"), Optional("en")],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_regionVariantMatches_false() {
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [Optional("en-us")],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_emptyTags_false() {
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_nilTag_false() {
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [nil],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_undTag_false() {
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [Optional("und")],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_undMixedWithKnownForeign_false() {
        // Strict: any unknown tag means we can't be sure there's no match.
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [Optional("fr"), Optional("und")],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_caseInsensitive_false() {
        XCTAssertFalse(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [Optional("EN")],
            preferredAudioLowercased: "en"
        ))
    }

    func testShouldAutoEnable_multipleForeignTracks_true() {
        XCTAssertTrue(SubtitleSelectionLogic.shouldAutoEnableSubtitles(
            audioTags: [Optional("fr"), Optional("de"), Optional("ja")],
            preferredAudioLowercased: "en"
        ))
    }
}
