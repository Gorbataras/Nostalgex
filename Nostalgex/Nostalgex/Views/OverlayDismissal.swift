import SwiftUI

// MARK: - Leaving an overlay by moving off its edge
//
// Every overlay opens with a direction (Down for the Now Playing panel, Up for the mini
// guide, Left for the package sidebar), and before this the only way back out was Back.
// Pressing the opposite direction did nothing, which is how viewers ended up stuck in a
// menu with no idea how to close it.
//
// These edges are invisible focus targets rather than `onMoveCommand` handlers. A move
// handler on an ancestor of the overlay's buttons sits in the press path for every
// direction, and that is exactly what froze the Now Playing panel once already (see the
// note on the bare-playback input overlay in PlayerView). Letting the focus engine walk
// onto an edge and closing when it arrives never touches the presses the buttons need.

/// An invisible full-width strip that closes its overlay when focus lands on it.
///
/// It stays unfocusable for a moment after it appears or is re-enabled: the overlay's own
/// `onAppear` places focus on its first real control, and without the delay the focus
/// engine's initial pass could pick the edge (it is the top- or bottom-most thing on
/// screen) and close the overlay as it opened.
struct FocusExitEdge: View {
    var isEnabled: Bool = true
    let onReach: () -> Void

    @State private var isArmed = false
    @FocusState private var isFocused: Bool

    /// How long the edge waits before it can take focus.
    static let armDelay: UInt64 = 400_000_000

    var body: some View {
        // Not `Color.clear`: a view that draws nothing can be skipped by the focus
        // engine. One percent black over the overlay's own dark gradient is invisible.
        Color.black.opacity(0.01)
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .focusable(isArmed && isEnabled)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { onReach() }
            }
            // Re-armed from scratch each time it is switched back on, for the same
            // reason: the controls that reappear with it get the first claim on focus.
            .task(id: isEnabled) {
                isArmed = false
                guard isEnabled else { return }
                try? await Task.sleep(nanoseconds: Self.armDelay)
                if !Task.isCancelled { isArmed = true }
            }
            .accessibilityHidden(true)
    }
}

/// The small caption telling a viewer how to get out of an overlay.
struct OverlayCloseHint: View {
    /// The swipe that closes the overlay, alongside Back.
    let swipe: String

    var body: some View {
        Text("PRESS BACK OR SWIPE \(swipe) TO CLOSE")
            .font(.custom("DMMono-Regular", size: 16))
            .foregroundStyle(.white.opacity(0.5))
            .tracking(1)
            .lineLimit(1)
            .accessibilityHidden(true)
    }
}
