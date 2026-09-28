import Foundation

/// Detects a disc-stacked movie inside a Jellyfin/Emby item's MediaSources.
///
/// Servers group "Titanic part 1" + "Titanic part 2" rips into one movie with multiple
/// MediaSources — but multiple sources ALSO mean alternate versions (a 1080p and a 4K of
/// the same film). Treating versions as parts would play the same movie twice back to
/// back, so sources only count as a stack when every one of them carries an explicit
/// part marker (part 2, pt. 2, cd2, disc 2) with distinct numbers. Anything else falls
/// through to the existing best-version pick.
enum MultiPartStack {

    struct Part: Equatable {
        let id: String
        let ordinal: Int
        let runTimeTicks: Int64?
    }

    struct Stack: Equatable {
        let parts: [Part]
        /// Sum across parts, nil when any part doesn't report a runtime — a partial sum
        /// would schedule a slot shorter than the movie.
        let totalRunTimeTicks: Int64?
    }

    private static let marker = try! NSRegularExpression(
        // Word boundary keeps "Department 2" from matching "part"; the ordinal cap at two
        // digits keeps years and resolutions ("2160") out.
        pattern: #"\b(?:part|pt\.?|cd|disc|disk)[\s._-]*([0-9]{1,2})\b"#,
        options: [.caseInsensitive]
    )

    static func detect(sources: [(id: String?, name: String?, runTimeTicks: Int64?)]) -> Stack? {
        guard sources.count >= 2 else { return nil }

        var parts: [Part] = []
        for source in sources {
            guard let id = source.id,
                  let name = source.name,
                  let ordinal = lastMarkerOrdinal(in: name) else { return nil }
            parts.append(Part(id: id, ordinal: ordinal, runTimeTicks: source.runTimeTicks))
        }

        // Duplicate ordinals mean two files claim the same disc — more likely versions of
        // one part than a coherent stack, so refuse rather than guess an order.
        guard Set(parts.map(\.ordinal)).count == parts.count else { return nil }

        let ordered = parts.sorted { $0.ordinal < $1.ordinal }
        let ticks = ordered.map(\.runTimeTicks)
        let total = ticks.allSatisfy { $0 != nil } ? ticks.compactMap { $0 }.reduce(0, +) : nil
        return Stack(parts: ordered, totalRunTimeTicks: total)
    }

    /// The LAST marker in the name decides: "Part II - The Return part 2.mkv" is disc 2.
    private static func lastMarkerOrdinal(in name: String) -> Int? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = marker.matches(in: name, options: [], range: range).last,
              let group = Range(match.range(at: 1), in: name) else { return nil }
        return Int(name[group])
    }
}
