import SwiftUI
import Combine

/// CRT + VHS effect overlay: scanlines, vignette, flicker, tracking glitch, color fringe.
struct CRTOverlayView: View {
    var showScanlines: Bool = true

    @State private var flickerOpacity: Double = 1.0
    @State private var trackingOffset: CGFloat = -200
    @State private var showTracking: Bool = false
    @State private var trackingTimer: Timer?
    let flickerTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Scanlines
            if showScanlines {
                ScanlineLayer()
                    .opacity(flickerOpacity)
            }

            // VHS tracking glitch line
            if showTracking {
                TrackingGlitchLine(yOffset: trackingOffset)
            }

            // Vignette (dark edges, simulates tube curvature)
            VignetteLayer()

            // Screen edge glow
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.04), lineWidth: 2)
        }
        .allowsHitTesting(false)
        .onReceive(flickerTimer) { _ in
            let roll = Double.random(in: 0...1)
            if roll > 0.95 {
                withAnimation(.easeInOut(duration: 0.03)) {
                    flickerOpacity = Double.random(in: 0.80...0.90)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.easeInOut(duration: 0.03)) {
                        flickerOpacity = 1.0
                    }
                }
            }
        }
        .onAppear {
            scheduleNextGlitch()
        }
        .onDisappear {
            trackingTimer?.invalidate()
        }
    }

    private func scheduleNextGlitch() {
        let delay = Double.random(in: 6...15)
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in
                let roll = Double.random(in: 0...1)
                if roll > 0.7 {
                    triggerGlitch()
                }
                scheduleNextGlitch()
            }
        }
    }

    private func triggerGlitch() {
        let duration = Double.random(in: 0.5...1.5)
        let travel = CGFloat.random(in: 150...400)
        trackingOffset = CGFloat.random(in: -200...200)
        showTracking = true
        withAnimation(.linear(duration: duration)) {
            trackingOffset += travel
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            showTracking = false
        }
    }
}

// MARK: - Scanline layer

private struct ScanlineLayer: View {
    var body: some View {
        Canvas { context, size in
            // Horizontal scanlines every 3px
            let spacing: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.black.opacity(0.12)), lineWidth: 1.5)
                y += spacing
            }
        }
    }
}

// MARK: - Vignette layer

private struct VignetteLayer: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Corner shadows (heavier than edges)
                RadialGradient(
                    gradient: Gradient(colors: [.clear, .clear, .black.opacity(0.7)]),
                    center: .center,
                    startRadius: min(w, h) * 0.3,
                    endRadius: max(w, h) * 0.7
                )

                // Top/bottom edge darkening
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.5), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: h * 0.08)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: h * 0.08)
                }

                // Left/right edge darkening
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.4), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.06)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.4)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.06)
                }
            }
        }
    }
}

// MARK: - VHS tracking glitch line

private struct TrackingGlitchLine: View {
    let yOffset: CGFloat

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Thin bright distortion band
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.08),
                                .white.opacity(0.15),
                                .white.opacity(0.08),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 12)

                // Thicker warped band beneath
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.03),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 30)
            }
            .offset(y: geo.size.height * 0.5 + yOffset)
        }
    }
}
