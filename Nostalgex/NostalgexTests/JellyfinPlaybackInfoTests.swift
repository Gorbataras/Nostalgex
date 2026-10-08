import XCTest
@testable import Nostalgex

/// Pure unit tests for the Jellyfin PlaybackInfo flow — DeviceProfile construction and the
/// response→URL selection. The live PlaybackInfo POST itself isn't tested (no network mock
/// infra, matching the existing JellyfinAPITests), but every pure piece around it is.
final class JellyfinPlaybackInfoTests: XCTestCase {

    private func decodeInfo(_ json: String) throws -> JellyfinPlaybackResolver.PlaybackInfoResponse {
        try JSONDecoder().decode(JellyfinPlaybackResolver.PlaybackInfoResponse.self, from: Data(json.utf8))
    }

    private func profileJSON(supportsHEVC: Bool) throws -> String {
        let data = try JSONEncoder().encode(JellyfinPlaybackResolver.deviceProfile(supportsHEVC: supportsHEVC))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - DeviceProfile

    func testDeviceProfileExcludesHEVCWhenUnsupported() throws {
        let json = try profileJSON(supportsHEVC: false)
        XCTAssertFalse(json.contains("hevc"), "HEVC must not be offered when the device can't decode it")
        XCTAssertTrue(json.contains("\"Protocol\":\"hls\""))
        // Transcode container is always fMP4, never MPEG-TS.
        XCTAssertTrue(json.contains("\"Container\":\"mp4\""))
        XCTAssertFalse(json.contains("\"Container\":\"ts\""))
    }

    func testDeviceProfileIncludesHEVCWhenSupported() throws {
        let json = try profileJSON(supportsHEVC: true)
        XCTAssertTrue(json.contains("hevc"))
        XCTAssertTrue(json.contains("h264"))
        XCTAssertTrue(json.contains("\"Container\":\"mp4\""))
    }

    func testDeviceProfileEncodesExpectedShape() throws {
        let json = try profileJSON(supportsHEVC: true)
        XCTAssertTrue(json.contains("DirectPlayProfiles"))
        XCTAssertTrue(json.contains("TranscodingProfiles"))
        XCTAssertTrue(json.contains("Streaming"))
    }

    // MARK: - resolve()

    func testResolveSelectsTranscodingUrlAndSession() throws {
        let info = try decodeInfo("""
        { "PlaySessionId": "PS123",
          "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        XCTAssertFalse(res.isDirectPlay)
        XCTAssertEqual(res.playSessionId, "PS123")
        XCTAssertTrue(res.url.absoluteString.hasPrefix("http://jelly.local:8096"))
        XCTAssertTrue(res.url.absoluteString.contains("/Videos/m1/master.m3u8"))
        XCTAssertTrue(res.url.absoluteString.contains("api_key=TKN"))
    }

    func testResolveAppendsApiKeyWhenMissing() throws {
        let info = try decodeInfo("""
        { "PlaySessionId": "PS1",
          "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        let occurrences = res.url.absoluteString.components(separatedBy: "api_key=").count - 1
        XCTAssertEqual(occurrences, 1, "api_key must be appended exactly once")
    }

    func testResolveDoesNotDuplicateApiKey() throws {
        let info = try decodeInfo("""
        { "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?api_key=TKN" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        let occurrences = res.url.absoluteString.components(separatedBy: "api_key=").count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testResolveFallsBackToDirectStream() throws {
        let info = try decodeInfo("""
        { "PlaySessionId": "PS9",
          "MediaSources": [ { "Id": "src1", "SupportsDirectPlay": true } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        XCTAssertTrue(res.isDirectPlay)
        XCTAssertTrue(res.url.absoluteString.contains("/Videos/m1/stream"))
        XCTAssertTrue(res.url.absoluteString.contains("Static=true"))
        XCTAssertEqual(res.playSessionId, "PS9")
    }

    func testResolveReturnsNilWhenNoPlayableSource() throws {
        let info = try decodeInfo("""
        { "MediaSources": [ { "Id": "src1", "SupportsDirectPlay": false, "SupportsTranscoding": false } ] }
        """)
        XCTAssertNil(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
    }

    func testResolvePicksMatchingMediaSourceId() throws {
        let info = try decodeInfo("""
        { "MediaSources": [
            { "Id": "other", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=other&api_key=TKN" },
            { "Id": "src1",  "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN" } ] }
        """)
        let res = try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            info, serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1"))
        XCTAssertTrue(res.url.absoluteString.contains("MediaSourceId=src1"))
    }

    // MARK: - Subtitles

    func testDeviceProfileOffersHlsWebVTTSubtitles() throws {
        let json = try profileJSON(supportsHEVC: true)
        XCTAssertTrue(json.contains("\"SubtitleProfiles\":[{\"Format\":\"vtt\",\"Method\":\"Hls\"}]"),
                      "without a subtitle profile Jellyfin can only burn subtitles into the picture")
    }

    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    private func resolveURL(_ json: String) throws -> URL {
        try XCTUnwrap(JellyfinPlaybackResolver.resolve(
            try decodeInfo(json), serverURL: "http://jelly.local:8096", apiKey: "TKN", itemId: "m1", mediaSourceId: "src1")).url
    }

    func testTextSubtitlesAreRequestedAsHlsRenditionsWhenServerPickedNone() throws {
        let url = try resolveURL("""
        { "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN",
            "MediaStreams": [ { "Index": 0, "Type": "Video" }, { "Index": 1, "Type": "Audio" },
                              { "Index": 2, "Type": "Subtitle", "IsTextSubtitleStream": true, "Language": "eng" } ] } ] }
        """)
        XCTAssertEqual(query(url)["SubtitleStreamIndex"], "2")
        XCTAssertEqual(query(url)["SubtitleMethod"], "Hls")
    }

    func testImageBurnInIsReplacedByATextRendition() throws {
        let url = try resolveURL("""
        { "MediaSources": [ { "Id": "src1", "DefaultSubtitleStreamIndex": 2,
            "TranscodingUrl": "/Videos/m1/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode&api_key=TKN",
            "MediaStreams": [ { "Index": 2, "Type": "Subtitle", "IsTextSubtitleStream": false },
                              { "Index": 3, "Type": "Subtitle", "IsTextSubtitleStream": true } ] } ] }
        """)
        XCTAssertEqual(query(url)["SubtitleStreamIndex"], "3")
        XCTAssertEqual(query(url)["SubtitleMethod"], "Hls")
        XCTAssertEqual(url.absoluteString.components(separatedBy: "SubtitleMethod=").count - 1, 1)
    }

    func testServersOwnTextPickIsKept() throws {
        let url = try resolveURL("""
        { "MediaSources": [ { "Id": "src1", "DefaultSubtitleStreamIndex": 4,
            "TranscodingUrl": "/Videos/m1/master.m3u8?SubtitleStreamIndex=4&SubtitleMethod=Encode&api_key=TKN",
            "MediaStreams": [ { "Index": 3, "Type": "Subtitle", "IsTextSubtitleStream": true },
                              { "Index": 4, "Type": "Subtitle", "IsTextSubtitleStream": true } ] } ] }
        """)
        XCTAssertEqual(query(url)["SubtitleStreamIndex"], "4")
        XCTAssertEqual(query(url)["SubtitleMethod"], "Hls")
    }

    func testImageOnlySubtitlesAreLeftAsTheServerChose() throws {
        let url = try resolveURL("""
        { "MediaSources": [ { "Id": "src1",
            "TranscodingUrl": "/Videos/m1/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode&api_key=TKN",
            "MediaStreams": [ { "Index": 2, "Type": "Subtitle", "IsTextSubtitleStream": false } ] } ] }
        """)
        XCTAssertEqual(query(url)["SubtitleStreamIndex"], "2")
        XCTAssertEqual(query(url)["SubtitleMethod"], "Encode")
    }

    func testNoSubtitleStreamsLeavesTheUrlAlone() throws {
        let url = try resolveURL("""
        { "MediaSources": [ { "Id": "src1", "TranscodingUrl": "/Videos/m1/master.m3u8?MediaSourceId=src1&api_key=TKN",
            "MediaStreams": [ { "Index": 0, "Type": "Video" } ] } ] }
        """)
        XCTAssertNil(query(url)["SubtitleStreamIndex"])
        XCTAssertNil(query(url)["SubtitleMethod"])
    }
}
