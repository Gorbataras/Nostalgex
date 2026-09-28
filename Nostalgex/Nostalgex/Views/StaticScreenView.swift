import SwiftUI
import Combine
import AVFoundation

/// Retro TV static/snow animation shown during channel transitions.
///
/// Intensity is deliberately restrained: the snow reads as a faint tuning haze over
/// black rather than a wall of noise, and it *settles* — after a beat it dims further so
/// a long transcode wait isn't seconds of aggressive churn. Callers fade it in/out via
/// `.transition(.opacity)` so it never hard-cuts.
struct StaticScreenView: View {
    /// Whether to play the white-noise tuning sound. Off by default so the loading state
    /// shown on every transcode channel-flip stays silent (visual-only).
    var audioEnabled: Bool = false
    /// Optional channel tag shown next to "TUNING" (e.g. "CH 42").
    var channelLabel: String? = nil
    @State private var seed: UInt64 = 0
    /// Flips true shortly after appear so the snow eases down to a calm resting level.
    @State private var settled = false
    @State private var noisePlayer: AVAudioPlayer?
    // Slightly slower churn than before — calmer, and lighter on the render loop.
    let timer = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black

            Canvas { context, size in
                let blockSize: CGFloat = 4
                let cols = Int(size.width / blockSize)
                let rows = Int(size.height / blockSize)

                var rng = seed
                for row in 0..<rows {
                    for col in 0..<cols {
                        rng = rng &* 6364136223846793005 &+ 1442695040888963407
                        let brightness = Double((rng >> 33) % 256) / 255.0
                        let rect = CGRect(
                            x: CGFloat(col) * blockSize,
                            y: CGFloat(row) * blockSize,
                            width: blockSize,
                            height: blockSize
                        )
                        context.fill(
                            Path(rect),
                            with: .color(white: brightness, opacity: 0.45)
                        )
                    }
                }
            }
            // Start faint, then settle even fainter so black dominates on long waits.
            .opacity(settled ? 0.14 : 0.32)
            .animation(.easeInOut(duration: 0.7), value: settled)

            Text(channelLabel.map { "TUNING · \($0)" } ?? "TUNING")
                .font(.custom("DMMono-Medium", size: 26))
                .foregroundStyle(.white.opacity(0.42))
        }
        .onReceive(timer) { _ in
            seed &+= 1
        }
        .onAppear {
            if audioEnabled { startStaticNoise() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                settled = true
            }
        }
        .onDisappear {
            noisePlayer?.stop()
        }
    }

    private func startStaticNoise() {
        // Generate white noise as raw PCM audio
        let sampleRate: Double = 22050
        let duration: Double = 2.0
        let sampleCount = Int(sampleRate * duration)

        var samples = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            samples[i] = Int16.random(in: Int16.min...Int16.max)
        }

        // Build WAV file in memory
        let dataSize = UInt32(sampleCount * 2)
        var wav = Data()

        // RIFF header
        wav.append(contentsOf: [UInt8]("RIFF".utf8))
        var fileSize = UInt32(36 + dataSize).littleEndian
        wav.append(Data(bytes: &fileSize, count: 4))
        wav.append(contentsOf: [UInt8]("WAVE".utf8))

        // fmt chunk
        wav.append(contentsOf: [UInt8]("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        wav.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian // PCM
        wav.append(Data(bytes: &audioFormat, count: 2))
        var channels = UInt16(1).littleEndian
        wav.append(Data(bytes: &channels, count: 2))
        var rate = UInt32(UInt32(sampleRate)).littleEndian
        wav.append(Data(bytes: &rate, count: 4))
        var byteRate = UInt32(UInt32(sampleRate) * 2).littleEndian
        wav.append(Data(bytes: &byteRate, count: 4))
        var blockAlign = UInt16(2).littleEndian
        wav.append(Data(bytes: &blockAlign, count: 2))
        var bitsPerSample = UInt16(16).littleEndian
        wav.append(Data(bytes: &bitsPerSample, count: 2))

        // data chunk
        wav.append(contentsOf: [UInt8]("data".utf8))
        var dSize = dataSize.littleEndian
        wav.append(Data(bytes: &dSize, count: 4))
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }

        do {
            let player = try AVAudioPlayer(data: wav)
            player.numberOfLoops = -1 // loop forever
            player.volume = 0.1
            player.play()
            noisePlayer = player
        } catch {
            print("[Plex90] Static noise audio failed: \(error)")
        }
    }
}
