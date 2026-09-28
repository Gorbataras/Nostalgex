import SwiftUI
import Combine

struct ChannelGuideView: View {
    @Environment(AppState.self) var appState
    @FocusState private var focusedChannelID: Int?

    let schedules: [Int: ChannelSchedule]
    let windowStart: Date
    var onFocusChanged: ((Int?) -> Void)? = nil

    // How many 30-min slots the user has scrolled forward (0-44 for 24-hour window)
    @State private var slotOffset: Int = 0
    @State private var suppressFocusScroll: Bool = false
    /// When focus last actually landed on a different channel. The wrap decision needs it
    /// because .onMoveCommand's ordering relative to the focus engine differs across tvOS
    /// builds: a "focus didn't change" snapshot alone cannot tell a press that arrived at
    /// the edge row (change fired milliseconds ago) from a press issued while already
    /// sitting there (change is stale). The first must land; only the second wraps.
    @State private var lastFocusMoveAt: Date = .distantPast

    @State private var showBundleSidebar: Bool = false

    private let channelColumnWidth: CGFloat = 220
    private let rowHeight: CGFloat = 80
    private let headerHeight: CGFloat = 60
    // 24-hour horizon, 30-min slots, 4 visible at a time → max scroll offset = 44.
    private let maxSlotOffset: Int = 44

    var body: some View {
        GeometryReader { geo in
            let programsWidth = geo.size.width - channelColumnWidth

            // Derive the grid window and header labels from the same snapped `windowStart`
            // the schedules were built from. This avoids header/window drift after returning
            // from fullscreen (where the tuner view can pause timers).
            let visibleStart = windowStart.addingTimeInterval(TimeInterval(slotOffset * 1800))
            let visibleLabels = timeSlotLabels(from: visibleStart)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    // Header row
                    gridHeader(
                        labels: visibleLabels,
                        programsWidth: programsWidth
                    )

                    // Divider under header
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 1)

                    // Channel rows
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 0) {
                                if appState.channels.isEmpty {
                                    Text("NO CHANNELS AVAILABLE")
                                        .font(.custom("DMMono-Medium", size: 20))
                                        .foregroundStyle(.white.opacity(0.3))
                                        .frame(maxWidth: .infinity, minHeight: 200)
                                        .focusable()
                                }
                                ForEach(Array(appState.channels.enumerated()), id: \.element.id) { index, channel in
                                    Button {
                                        if appState.currentChannel?.id == channel.id {
                                            appState.isFullScreen = true
                                        } else {
                                            appState.selectChannel(channel, precomputedSchedule: schedules[channel.id])
                                        }
                                    } label: {
                                        EPGRow(
                                            channel: channel,
                                            schedule: schedules[channel.id],
                                            isFocused: focusedChannelID == channel.id,
                                            isEvenRow: index % 2 == 0,
                                            channelColumnWidth: channelColumnWidth,
                                            programsWidth: programsWidth,
                                            visibleWindowStart: visibleStart,
                                            rowHeight: rowHeight
                                        )
                                    }
                                    .buttonStyle(NoHighlightButtonStyle())
                                    .focused($focusedChannelID, equals: channel.id)
                                    .accessibilityLabel(
                                        appState.currentChannel?.id == channel.id
                                            ? "Channel \(channel.number), \(channel.name), live"
                                            : "Channel \(channel.number), \(channel.name)"
                                    )
                                    .id(channel.id)
                                    .onPlayPauseCommand {
                                        if appState.currentChannel?.id == channel.id {
                                            appState.isFullScreen = true
                                        } else {
                                            appState.selectChannel(channel, precomputedSchedule: schedules[channel.id])
                                        }
                                    }
                                }
                            }
                        }
                        .onChange(of: focusedChannelID) { _, newID in
                            lastFocusMoveAt = Date()
                            if !suppressFocusScroll, let id = newID {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                            onFocusChanged?(newID)
                        }
                        .onChange(of: appState.isFullScreen) { _, isFullScreen in
                            if !isFullScreen, let id = appState.currentChannel?.id {
                                // Suppress focus-driven scrolling while we anchor to live channel
                                suppressFocusScroll = true
                                focusedChannelID = id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    proxy.scrollTo(id, anchor: .center)
                                    suppressFocusScroll = false
                                }
                            }
                        }
                        .onChange(of: appState.currentChannel?.id) { _, newID in
                            // Keep the guide anchored to the live channel when it changes via a
                            // path that doesn't toggle fullscreen (mini-strip popup, swipe, move).
                            // Guard != focusedChannelID so selecting a row from the guide itself
                            // (which sets currentChannel to the already-focused id) is a no-op.
                            guard let id = newID, id != focusedChannelID else { return }
                            suppressFocusScroll = true
                            focusedChannelID = id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                proxy.scrollTo(id, anchor: .center)
                                suppressFocusScroll = false
                            }
                        }
                        .onAppear {
                            let targetID = appState.currentChannel?.id ?? appState.channels.first?.id
                            if let id = targetID {
                                focusedChannelID = id
                                // Explicit scroll in case focusedChannelID was already set
                                // (e.g., returning from Settings where the value didn't change)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        proxy.scrollTo(id, anchor: .center)
                                    }
                                }
                            }
                        }
                    }
                }

                // "Now" time indicator line
                let nowFraction = nowFractionInWindow(visibleStart: visibleStart)
                if nowFraction >= 0 && nowFraction <= 1 {
                    let nowX = channelColumnWidth + (nowFraction * (geo.size.width - channelColumnWidth))
                    Rectangle()
                        .fill(Color("BrandCyan"))
                        .frame(width: 2)
                        .offset(x: nowX)
                        .allowsHitTesting(false)
                }
            }
            .onMoveCommand { direction in
                switch direction {
                case .left:
                    if slotOffset > 0 {
                        slotOffset -= 1
                    } else if !showBundleSidebar {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showBundleSidebar = true
                        }
                    }
                case .right:
                    if showBundleSidebar {
                        withAnimation(.easeIn(duration: 0.15)) {
                            showBundleSidebar = false
                        }
                    } else if slotOffset < maxSlotOffset {
                        slotOffset += 1
                    }
                case .down:
                    // Wrap only when a press provably had nowhere to go, under EITHER
                    // event ordering. Two signals decide it after the engine settles:
                    // focus didn't change because of this press, AND the last real focus
                    // change is stale. The staleness test is what separates "just arrived
                    // at the bottom row" (change fired milliseconds ago; handler ordering
                    // may run after it) from "pressing down while sitting on it" — the
                    // first fix used the unchanged-snapshot alone and made arrival itself
                    // wrap, so the bottom channel could never be selected.
                    let beforeDown = focusedChannelID
                    let moveStampDown = lastFocusMoveAt
                    DispatchQueue.main.async {
                        guard lastFocusMoveAt == moveStampDown,
                              Date().timeIntervalSince(moveStampDown) > 0.15,
                              let id = beforeDown, focusedChannelID == id,
                              let idx = appState.channels.firstIndex(where: { $0.id == id }),
                              idx == appState.channels.count - 1,
                              let firstID = appState.channels.first?.id else { return }
                        focusedChannelID = firstID
                    }
                case .up:
                    let beforeUp = focusedChannelID
                    let moveStampUp = lastFocusMoveAt
                    DispatchQueue.main.async {
                        guard lastFocusMoveAt == moveStampUp,
                              Date().timeIntervalSince(moveStampUp) > 0.15,
                              let id = beforeUp, focusedChannelID == id,
                              let idx = appState.channels.firstIndex(where: { $0.id == id }),
                              idx == 0,
                              let lastID = appState.channels.last?.id else { return }
                        focusedChannelID = lastID
                    }
                default:
                    break
                }
            }
            .onPlayPauseCommand {
                if appState.currentChannel != nil {
                    appState.isFullScreen = true
                }
            }

            // Bundle jump sidebar
            if showBundleSidebar {
                BundleJumpSidebar(
                    targets: appState.bundleJumpTargets,
                    onSelect: { firstChannelID in
                        focusedChannelID = firstChannelID
                        withAnimation(.easeIn(duration: 0.15)) {
                            showBundleSidebar = false
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeIn(duration: 0.15)) {
                            showBundleSidebar = false
                        }
                    }
                )
                .transition(.move(edge: .leading))
                .zIndex(10)
            }
        }
        .background(Color(red: 0.05, green: 0.05, blue: 0.12))
    }

    // MARK: - Now indicator

    private func nowFractionInWindow(visibleStart: Date) -> CGFloat {
        let now = Date()
        let visibleDuration: TimeInterval = 7200 // 2 hours
        let elapsed = now.timeIntervalSince(visibleStart)
        return CGFloat(elapsed / visibleDuration)
    }

    // MARK: - Grid header

    private func timeSlotLabels(from visibleStart: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return (0..<4).map { i in
            formatter.string(from: visibleStart.addingTimeInterval(TimeInterval(i * 1800)))
        }
    }

    private func gridHeader(labels: [String], programsWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("CHANNEL")
                .font(.custom("DMMono-Medium", size: 18))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: channelColumnWidth, alignment: .leading)
                .padding(.leading, 12)

            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.custom("DMMono-Medium", size: 20))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .frame(width: programsWidth / 4, alignment: .leading)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.2))
                            .frame(width: 1)
                    }
            }
        }
        .frame(height: headerHeight)
        .background(Color(red: 0.04, green: 0.04, blue: 0.08))
    }
}

// MARK: - EPG Row (single channel)

private struct EPGRow: View {
    @Environment(AppState.self) var appState
    let channel: Channel
    let schedule: ChannelSchedule?
    let isFocused: Bool
    let isEvenRow: Bool
    let channelColumnWidth: CGFloat
    let programsWidth: CGFloat
    let visibleWindowStart: Date
    let rowHeight: CGFloat

    // 2-hour visible window
    private let visibleDuration: TimeInterval = 7200
    /// Background for alternating rows
    private var rowBackground: Color {
        if isFocused {
            // The focused row must read from the couch at a glance. A 15% tint of the
            // channel colour disappeared on a bright TV; a third-strength fill plus the
            // outline and glow below does not.
            return channel.color.opacity(0.32)
        }
        return isEvenRow
            ? Color.white.opacity(0.03)
            : Color.clear
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Colored left accent bar using channel color
                Rectangle()
                    .fill(isLive || isFocused ? channel.color : channel.color.opacity(0.4))
                    .frame(width: isLive || isFocused ? 8 : 4)

                // Channel column
                channelColumn

                // Vertical divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1)

                // Program blocks
                programBlocks
            }
            .frame(height: rowHeight)
            .background(rowBackground)
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(channel.color, lineWidth: 3)
                        .padding(2)
                        .shadow(color: channel.color.opacity(0.7), radius: 14)
                }
            }
            .zIndex(isFocused ? 1 : 0)

            // Row divider
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    // MARK: - Channel column

    private var isLive: Bool {
        appState.currentChannel?.id == channel.id
    }

    private var channelColumn: some View {
        HStack(alignment: .center, spacing: 0) {
            if isLive {
                liveBoltBadge
                    .padding(.trailing, 6)
                    .accessibilityHidden(true)
            }

            Text(String(format: "%d", channel.number))
                .font(.custom("DMMono-Medium", size: 20))
                .foregroundStyle(isFocused ? Color.white : channel.color)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 8)

            Text(channel.name.uppercased())
                .font(.custom("DMMono-Medium", size: 18))
                .foregroundStyle(isFocused ? Color.white : channel.color.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Every row's channel column must measure exactly channelColumnWidth. The live row
        // used a different leading pad and a differently-derived frame, leaving it 216pt
        // against 220pt elsewhere, so the tuned row's programs sat 4pt left of every other
        // row and of the now-line, which is positioned from a flat channelColumnWidth.
        .padding(.leading, isLive ? 8 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: channelColumnWidth - 4, alignment: .leading)
        .padding(.trailing, 4)
    }

    /// Compact tuned-in marker — only shown on the active channel row.
    private var liveBoltBadge: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black.opacity(0.95))
            .symbolRenderingMode(.monochrome)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .background(channel.color)
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    // MARK: - Program blocks

    private var programBlocks: some View {
        let now = Date()

        // Segments are cursor-derived, so gaps hold their true position, overlap cannot
        // widen the row, and the fractions can never sum past 1. The explicit .leading
        // alignments matter as much as the math: a fixed-width SwiftUI frame centers
        // overflowing content, which is what slid whole rows left and buried the current
        // program's title under the channel column.
        return HStack(spacing: 0) {
            if let schedule {
                let segments = ProgramRowLayout.segments(
                    intervals: schedule.entries.map { ($0.startTime, $0.endTime) },
                    windowStart: visibleWindowStart,
                    windowDuration: visibleDuration
                )
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .gap(let fraction):
                        Color.clear
                            .frame(width: fraction * programsWidth, height: rowHeight)
                    case .block(let index, let fraction):
                        let entry = schedule.entries[index]
                        let isPast = entry.endTime < now && !entry.isNowPlaying

                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 1)

                            Text(entryTitle(entry))
                                .font(.custom("DMMono-Medium", size: 20))
                                .foregroundStyle(
                                    entry.isNowPlaying || isFocused
                                        ? Color.white
                                        : isPast
                                            ? Color.white.opacity(0.5)
                                            : Color.white.opacity(0.85)
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 14)

                            Spacer(minLength: 0)
                        }
                        .frame(width: max(fraction * programsWidth, 1), height: rowHeight, alignment: .leading)
                        .clipped()
                        .background(
                            entry.isNowPlaying
                                ? channel.color.opacity(isFocused ? 0.55 : 0.25)
                                : isPast
                                    ? Color.white.opacity(0.02)
                                    : Color.clear
                        )
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: programsWidth, alignment: .leading)
        .clipped()
    }

    // MARK: - Helpers

    private func entryTitle(_ entry: ScheduleEntry) -> String {
        if entry.item.type == .episode {
            let parts = [entry.item.title, entry.item.episodeTitle]
                .compactMap { $0 }
            return parts.joined(separator: ": ")
        }
        if entry.item.isMusicVideo {
            return entry.item.musicDisplayLine
        }
        return entry.item.title
    }
}

// MARK: - Bundle Jump Sidebar

private struct BundleJumpSidebar: View {
    let targets: [(bundleID: String, bundleName: String, firstChannelID: Int, channelColor: Color)]
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void
    @FocusState private var focusedIndex: Int?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Text("PACKAGES")
                    .font(.custom("DMMono-Medium", size: 18))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 2) {
                            ForEach(Array(targets.enumerated()), id: \.element.bundleID) { index, target in
                                let isFocused = focusedIndex == index

                                Button {
                                    onSelect(target.firstChannelID)
                                } label: {
                                    HStack(spacing: 12) {
                                        Rectangle()
                                            .fill(target.channelColor)
                                            .frame(width: 4)

                                        Text(target.bundleName)
                                            .font(.custom("DMMono-Medium", size: 18))
                                            .foregroundStyle(isFocused ? .white : .white.opacity(0.75))
                                            .lineLimit(1)

                                        Spacer()
                                    }
                                    .padding(.vertical, 14)
                                    .background(isFocused ? target.channelColor.opacity(0.15) : .clear)
                                }
                                .buttonStyle(NoHighlightButtonStyle())
                                .focused($focusedIndex, equals: index)
                                .id(index)
                            }
                        }
                    }
                    .onChange(of: focusedIndex) { _, newIndex in
                        if let idx = newIndex {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 260)
            .background(Color(red: 0.03, green: 0.03, blue: 0.08).opacity(0.95))

            // Divider
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            Spacer()
        }
        .onAppear {
            focusedIndex = 0
        }
        .onExitCommand {
            onDismiss()
        }
    }
}
