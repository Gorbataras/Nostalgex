import XCTest
import SwiftUI
@testable import Nostalgex

@MainActor
final class MultiServerAndPlaybackTests: XCTestCase {

    private func makeItem(container: String?, video: String?, audio: String?) -> PlexMediaItem {
        PlexMediaItem(
            id: "1",
            title: "Test",
            artist: nil,
            episodeTitle: nil,
            seTag: nil,
            summary: "",
            year: 2000,
            originallyAvailableAt: nil,
            contentRating: nil,
            duration: 90,
            ratingKey: "1",
            partKey: "/library/parts/1/file.\(container ?? "bin")",
            container: container,
            videoCodec: video,
            audioCodec: audio,
            videoProfile: nil,
            bitrate: nil,
            genres: [],
            rating: 0,
            userRating: 0,
            type: .movie,
            thumb: nil,
            art: nil,
            viewCount: 0,
            addedAt: 0,
            studio: nil,
            tmdbID: nil,
            imdbID: nil,
            librarySource: .movie
        )
    }

    private func makeChannel(id: Int) -> Channel {
        Channel(
            id: id,
            number: id,
            name: "CH\(id)",
            color: .blue,
            category: nil,
            rules: nil,
            timeRestrictions: nil,
            minItems: 0,
            itemPool: []
        )
    }

    // MARK: - Container guard (Phase 1a)

    func testDirectPlay_skipsNonNativeContainerEvenWithSupportedCodecs() {
        let api = PlexAPIService(serverURL: "https://server", token: "tok")
        XCTAssertNil(api.buildDirectPlayURL(for: makeItem(container: "mkv", video: "h264", audio: "aac")),
                     "mkv must not direct play even with native codecs")
        XCTAssertNil(api.buildDirectPlayURL(for: makeItem(container: "avi", video: "h264", audio: "aac")))
    }

    func testDirectPlay_allowsNativeContainers() {
        let api = PlexAPIService(serverURL: "https://server", token: "tok")
        XCTAssertNotNil(api.buildDirectPlayURL(for: makeItem(container: "mp4", video: "h264", audio: "aac")))
        // HEVC direct play is hardware-dependent now: the Apple TV HD (and the simulator)
        // cannot decode it, and handing it the file produced a silent black screen. The
        // service must agree with the device's actual capability, whichever way it reports.
        let hevcAllowed = api.buildDirectPlayURL(for: makeItem(container: "mov", video: "hevc", audio: "ac3")) != nil
        XCTAssertEqual(hevcAllowed, CodecSupport.deviceSupportsHEVC)
    }

    func testDirectPlay_stillBlocksUnsupportedCodecs() {
        let api = PlexAPIService(serverURL: "https://server", token: "tok")
        XCTAssertNil(api.buildDirectPlayURL(for: makeItem(container: "mp4", video: "vc1", audio: "aac")))
        XCTAssertNil(api.buildDirectPlayURL(for: makeItem(container: "mp4", video: "h264", audio: "dts")))
    }

    // MARK: - Composite id (Phase 2d)

    func testCompositeID_prefixesWithServerWhenPresent() {
        XCTAssertEqual(PlexAPIService.compositeID(serverID: "", ratingKey: "12"), "12")
        XCTAssertEqual(PlexAPIService.compositeID(serverID: "srvA", ratingKey: "12"), "srvA:12")
    }

    // MARK: - Empty-state auto recovery (Phase 1c)

    func testAutoEnableBundlesWithContent_enablesOnlyBundlesWithQualifyingChannels() {
        let state = AppState()
        state.allChannels = [makeChannel(id: 10), makeChannel(id: 11)]
        state.bundles = [
            ChannelBundle(id: "has-content", name: "A", description: nil, channelIDs: [10], activeMonths: nil, enabled: false),
            ChannelBundle(id: "no-content", name: "B", description: nil, channelIDs: [999], activeMonths: nil, enabled: false),
        ]
        state.enabledBundleIDs = []

        let changed = state.autoEnableBundlesWithContent()

        XCTAssertTrue(changed)
        XCTAssertTrue(state.enabledBundleIDs.contains("has-content"))
        XCTAssertFalse(state.enabledBundleIDs.contains("no-content"))
    }

    func testAutoEnableBundlesWithContent_noopWhenNothingQualifies() {
        let state = AppState()
        state.allChannels = []
        state.bundles = [
            ChannelBundle(id: "x", name: "X", description: nil, channelIDs: [1], activeMonths: nil, enabled: false),
        ]
        state.enabledBundleIDs = []

        XCTAssertFalse(state.autoEnableBundlesWithContent())
        XCTAssertTrue(state.enabledBundleIDs.isEmpty)
    }
}
