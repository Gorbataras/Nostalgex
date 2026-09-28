import Foundation
import AVFoundation

/// A user-facing descriptor for one audio track exposed by the current player item.
/// `id` is the option's index within its `AVMediaSelectionGroup` — stable for the
/// lifetime of that item, and the value passed back to `AppState.selectAudioTrack(id:)`.
struct AudioTrackDescriptor: Identifiable, Equatable {
    let id: Int
    let displayName: String
    let languageTag: String?
}

/// Builds `AudioTrackDescriptor`s from an audible media-selection group. The pure
/// `buildDescriptors(from:)` core is split out from the AVFoundation adapter so it can
/// be unit-tested without constructing real `AVMediaSelectionOption`s.
enum AudioTrackDescriptorBuilder {

    /// AVFoundation adapter — the only place that touches `AVMediaSelectionOption`.
    static func build(from group: AVMediaSelectionGroup) -> [AudioTrackDescriptor] {
        let tuples: [(displayName: String, ext: String?, locale: String?)] = group.options.map { opt in
            let ext: String?
            if #available(tvOS 16.0, iOS 16.0, macOS 13.0, watchOS 9.0, *) {
                ext = opt.extendedLanguageTag
            } else {
                ext = nil
            }
            return (displayName: opt.displayName, ext: ext, locale: opt.locale?.identifier)
        }
        return buildDescriptors(from: tuples)
    }

    /// Pure, testable core. `displayName` falls back to the uppercased language tag,
    /// then to `"Track N"`, so a track is never rendered with an empty label.
    static func buildDescriptors(
        from options: [(displayName: String, ext: String?, locale: String?)]
    ) -> [AudioTrackDescriptor] {
        options.enumerated().map { index, opt in
            let tag = SubtitleSelectionLogic.languageTagForComparison(
                extendedLanguageTag: opt.ext,
                localeIdentifier: opt.locale
            )
            let trimmed = opt.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if !trimmed.isEmpty {
                name = trimmed
            } else if let tag, !tag.isEmpty {
                name = tag.uppercased()
            } else {
                name = "Track \(index + 1)"
            }
            return AudioTrackDescriptor(id: index, displayName: name, languageTag: tag)
        }
    }
}

/// One row in the Now Playing panel's program column — the controls that act on the
/// program playing right now. Headers are part of the list so the column's whole order
/// is decided in one testable place instead of being spread through the view body.
enum NowPlayingProgramRow: String, Hashable, CaseIterable {
    case captionsHeader
    case captions
    case subtitleLanguage
    case autoSubtitles
    case audioHeader
    case audioTracks
    case audioLanguage
    case openInPlex
}

/// Decides which optional rows the Now Playing panel offers for the current program.
enum NowPlayingPanelLayout {

    /// Program-column rows, in display order.
    ///
    /// The subtitle preferences only appear when the program exposes real subtitle tracks,
    /// and the audio-language preference only when there is more than one audio track,
    /// because otherwise they are settings whose effect the user cannot see or hear from
    /// a panel laid over the video. Both stay reachable from the settings page.
    ///
    /// The captions rows are unconditional: the CC row is where panel focus first lands,
    /// so it has to exist for every program.
    static func programRows(
        hasSubtitleTracks: Bool,
        audioTrackCount: Int,
        canOpenInPlex: Bool = false
    ) -> [NowPlayingProgramRow] {
        var rows: [NowPlayingProgramRow] = [.captionsHeader, .captions]
        if hasSubtitleTracks {
            rows.append(.subtitleLanguage)
            rows.append(.autoSubtitles)
        }
        rows.append(.audioHeader)
        rows.append(.audioTracks)
        if audioTrackCount > 1 {
            rows.append(.audioLanguage)
        }
        // Last, deliberately: it leaves the app, so it should never sit between the user
        // and the settings they came for.
        if canOpenInPlex {
            rows.append(.openInPlex)
        }
        return rows
    }
}

/// Pure sleep-timer math + presentation. No timers, no side effects — the `Timer`
/// lifecycle lives in `AppState`; this only computes remaining time and labels.
enum SleepTimerLogic {

    /// Canonical minute presets offered in the panel (OFF is a separate view concept).
    static let presets: [Int] = [15, 30, 60]

    /// The minute rows the panel should actually render, given whatever timer is armed.
    ///
    /// The offered set can shrink between builds, but a timer that is already counting
    /// down still needs a row to render its countdown in. Fold a running-but-no-longer-
    /// offered duration back into the list, in order, so it stays visible until it fires
    /// or the user cancels it. Only the choices on offer shrink, never a running timer.
    static func offeredMinutes(armed: Int?) -> [Int] {
        guard let armed, armed > 0, !presets.contains(armed) else { return presets }
        return (presets + [armed]).sorted()
    }

    /// Seconds left until `endDate`, clamped at 0. `nil` when the timer is off.
    static func remaining(from endDate: Date?, now: Date) -> TimeInterval? {
        guard let endDate else { return nil }
        return max(0, endDate.timeIntervalSince(now))
    }

    /// True only when an armed timer has reached or passed its end date.
    static func isExpired(endDate: Date?, now: Date) -> Bool {
        guard let endDate else { return false }
        return now >= endDate
    }

    /// Preset label, e.g. `"30 MIN"`, `"1 HR"`, `"1 HR 30 MIN"`.
    static func label(minutes: Int) -> String {
        guard minutes > 0 else { return "OFF" }
        let hours = minutes / 60
        let mins = minutes % 60
        switch (hours, mins) {
        case (0, _):
            return "\(mins) MIN"
        case (_, 0):
            return "\(hours) HR"
        default:
            return "\(hours) HR \(mins) MIN"
        }
    }

    /// Countdown for the armed state, `"m:ss"` (or `"h:mm:ss"` past an hour).
    static func countdownLabel(remaining: TimeInterval) -> String {
        let total = Int(remaining.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
