import Foundation

/// Result of resolving how to play a Jellyfin item. `playSessionId` is nil when we fell
/// back to a hand-built URL (no PlaybackInfo handshake), in which case there is no
/// server-tracked transcode session to stop.
struct PlaybackResolution: Sendable {
    let url: URL
    let playSessionId: String?
    let isDirectPlay: Bool
}

extension JellyfinPlaybackResolver {
    /// Jellyfin and Emby start an HLS transcode at StartTimeTicks (100ns units). Seeking the
    /// client into a transcode that began at zero never completes, so the offset goes here.
    static func addingStartTime(to url: URL, offsetSeconds: Int) -> URL {
        guard offsetSeconds > 0, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = (c.queryItems ?? []).filter { $0.name != "StartTimeTicks" }
        items.append(.init(name: "StartTimeTicks", value: String(Int64(offsetSeconds) * 10_000_000)))
        c.queryItems = items
        return c.url ?? url
    }
}

/// Device profile we send to Jellyfin's PlaybackInfo endpoint. It tells the server exactly
/// what this Apple TV can play so the server makes the right direct-play / remux / transcode
/// decision instead of us guessing. The two load-bearing rules:
///   • HEVC is only an acceptable codec when the device can hardware-decode it.
///   • Transcoding always targets fMP4 HLS (`Container: "mp4"`), never MPEG-TS — AVPlayer
///     cannot render HEVC from a TS segment (the original black-screen bug).
/// Subtitles: with no SubtitleProfiles the server's only option is to burn the user's
/// default subtitle into the picture, where our CC toggle can't reach it. Offering WebVTT
/// over HLS makes text subtitles arrive as legible renditions AVPlayer can switch.
struct JellyfinDeviceProfile: Encodable, Sendable {
    let MaxStreamingBitrate: Int
    let MaxStaticBitrate: Int
    let DirectPlayProfiles: [DirectPlayProfile]
    let TranscodingProfiles: [TranscodingProfile]
    let SubtitleProfiles: [SubtitleProfile]

    struct SubtitleProfile: Encodable, Sendable {
        let Format: String
        let Method: String
    }

    struct DirectPlayProfile: Encodable, Sendable {
        let Container: String
        let mediaType: String
        let VideoCodec: String?
        let AudioCodec: String?

        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec
            case mediaType = "Type"
        }
    }

    struct TranscodingProfile: Encodable, Sendable {
        let Container: String
        let mediaType: String
        let VideoCodec: String
        let AudioCodec: String
        let Context: String
        let MaxAudioChannels: String
        let protocolName: String

        enum CodingKeys: String, CodingKey {
            case Container, VideoCodec, AudioCodec, Context, MaxAudioChannels
            case mediaType = "Type"
            case protocolName = "Protocol"
        }
    }
}

enum JellyfinPlaybackResolver {
    /// Codecs AVPlayer can decode. HEVC is gated separately on hardware support.
    private static let audioCodecs = "aac,ac3,eac3,mp3"

    static func deviceProfile(supportsHEVC: Bool) -> JellyfinDeviceProfile {
        let videoCodecs = supportsHEVC ? "h264,hevc" : "h264"
        return JellyfinDeviceProfile(
            MaxStreamingBitrate: StreamQuality.current.maxBitrateBps,
            MaxStaticBitrate: StreamQuality.current.maxBitrateBps,
            DirectPlayProfiles: [
                // Containers AVPlayer can open as a raw file. NB: NOT mkv — AVPlayer cannot
                // demux Matroska no matter the codec, so mkv must always go through the
                // transcoding profile (which remuxes to fMP4 when the codec is compatible).
                .init(Container: "mp4,m4v,mov", mediaType: "Video", VideoCodec: videoCodecs, AudioCodec: audioCodecs),
            ],
            TranscodingProfiles: [
                // fMP4 HLS, h264 (+hevc when capable), audio forced into AVPlayer-friendly codecs.
                .init(Container: "mp4", mediaType: "Video", VideoCodec: videoCodecs, AudioCodec: audioCodecs,
                      Context: "Streaming", MaxAudioChannels: "6", protocolName: "hls"),
            ],
            SubtitleProfiles: [
                .init(Format: "vtt", Method: "Hls"),
            ]
        )
    }

    /// Decoded shape of a PlaybackInfo response (capital-letter Jellyfin keys).
    struct PlaybackInfoResponse: Decodable, Sendable {
        let MediaSources: [PlaybackMediaSource]?
        let PlaySessionId: String?

        struct PlaybackMediaSource: Decodable, Sendable {
            let Id: String?
            let SupportsDirectPlay: Bool?
            let SupportsDirectStream: Bool?
            let SupportsTranscoding: Bool?
            let TranscodingUrl: String?
            let DefaultSubtitleStreamIndex: Int?
            let MediaStreams: [MediaStream]?
        }

        struct MediaStream: Decodable, Sendable {
            let Index: Int?
            let streamType: String?
            let IsTextSubtitleStream: Bool?

            enum CodingKeys: String, CodingKey {
                case Index, IsTextSubtitleStream
                case streamType = "Type"
            }
        }
    }

    /// Jellyfin only lists subtitle renditions in the HLS master playlist when the URL names
    /// a subtitle stream with `SubtitleMethod=Hls`, and then it lists every text subtitle the
    /// source has. So whenever the source has any, point the URL at one: the server's own
    /// pick if it is text, else the first text stream. That also replaces a burn-in of an
    /// image subtitle (`SubtitleMethod=Encode`), which our CC toggle could never turn off.
    /// Sources with only image subtitles (PGS, VobSub) are left as the server chose — burning
    /// in is the only way AVPlayer can show those at all.
    static func addingHlsSubtitles(to url: URL, source: PlaybackInfoResponse.PlaybackMediaSource) -> URL {
        let textIndexes = (source.MediaStreams ?? [])
            .filter { $0.streamType == "Subtitle" && $0.IsTextSubtitleStream == true }
            .compactMap(\.Index)
        guard !textIndexes.isEmpty, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = c.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let current = value("SubtitleStreamIndex").flatMap(Int.init)
        if let current, textIndexes.contains(current), value("SubtitleMethod")?.lowercased() == "hls" {
            return url
        }
        let pick = [current, source.DefaultSubtitleStreamIndex]
            .compactMap { $0 }
            .first { textIndexes.contains($0) } ?? textIndexes[0]
        items.removeAll {
            $0.name.caseInsensitiveCompare("SubtitleStreamIndex") == .orderedSame
                || $0.name.caseInsensitiveCompare("SubtitleMethod") == .orderedSame
        }
        items.append(.init(name: "SubtitleStreamIndex", value: String(pick)))
        items.append(.init(name: "SubtitleMethod", value: "Hls"))
        c.queryItems = items
        return c.url ?? url
    }

    /// Pure selection of the playback URL from a decoded PlaybackInfo. No networking — unit
    /// testable. Returns nil only when there is genuinely no playable source (transcoding
    /// disabled and not directly playable), which the caller maps to a `.error` state.
    static func resolve(
        _ info: PlaybackInfoResponse,
        serverURL: String,
        apiKey: String,
        itemId: String,
        mediaSourceId: String?
    ) -> PlaybackResolution? {
        let sources = info.MediaSources ?? []
        let source = sources.first(where: { $0.Id == mediaSourceId }) ?? sources.first

        // 1) Server handed us a transcode/remux URL — use it verbatim (it carries the right
        //    session + params). Only ensure api_key is present for the segment requests.
        if let relative = source?.TranscodingUrl, !relative.isEmpty {
            if let url = makeURL(serverURL: serverURL, relativeOrAbsolute: relative, apiKey: apiKey) {
                let withSubs = source.map { addingHlsSubtitles(to: url, source: $0) } ?? url
                return PlaybackResolution(url: withSubs, playSessionId: info.PlaySessionId, isDirectPlay: false)
            }
        }

        // 2) No transcode URL but the source is directly playable — static stream.
        if source?.SupportsDirectPlay == true {
            guard var c = URLComponents(string: "\(serverURL)/Videos/\(itemId)/stream") else { return nil }
            c.queryItems = [
                .init(name: "Static", value: "true"),
                .init(name: "MediaSourceId", value: source?.Id ?? mediaSourceId ?? itemId),
                .init(name: "api_key", value: apiKey),
            ]
            if let url = c.url {
                return PlaybackResolution(url: url, playSessionId: info.PlaySessionId, isDirectPlay: true)
            }
        }

        // 3) Nothing playable (e.g. transcoding disabled server-side).
        return nil
    }

    /// Builds an absolute URL from Jellyfin's (usually server-relative) TranscodingUrl,
    /// guaranteeing a single `api_key` query item.
    private static func makeURL(serverURL: String, relativeOrAbsolute: String, apiKey: String) -> URL? {
        let absolute = relativeOrAbsolute.hasPrefix("http") ? relativeOrAbsolute : serverURL + relativeOrAbsolute
        guard var c = URLComponents(string: absolute) else { return nil }
        var items = c.queryItems ?? []
        if !items.contains(where: { $0.name == "api_key" }) {
            items.append(.init(name: "api_key", value: apiKey))
        }
        c.queryItems = items
        return c.url
    }
}
