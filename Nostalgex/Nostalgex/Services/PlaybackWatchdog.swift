import Foundation

/// Decides when a load that has not produced picture should be given up on.
///
/// Judged by whether the playhead moved, not by AVPlayer's buffer flags: `isPlaybackBufferEmpty`
/// reads true on perfectly healthy HLS streams between segments, and `rate == 0` alone missed
/// the stream that reported "playing" while nothing ever decoded. A playhead that advances is
/// the only thing that means frames are reaching the screen.
enum PlaybackWatchdog {
    /// Fifteen seconds is plenty for a direct play or a remux. A 4K source the server has to
    /// re-encode needs a transcoder spun up, a seek, and a first segment; on a Mac mini that
    /// can take half a minute, and giving up earlier turned slow starts into skipped films.
    /// Width as well as height: a 2.39:1 UHD frame is 3840 wide and only 1606 tall.
    static func deadlineSeconds(isDirectPlay: Bool, videoWidth: Int?, videoHeight: Int?) -> Int {
        if isDirectPlay { return 15 }
        let uhd = (videoHeight ?? 0) >= 2000 || (videoWidth ?? 0) >= 3000
        return uhd ? 40 : 20
    }

    /// Seconds between the two playhead samples taken just before the deadline.
    static let progressWindowSeconds = 2

    /// The playhead has to move this much across the window to count as alive. Deliberately
    /// low: the watchdog exists for streams that never produce a frame, not slow ones, and a
    /// stream that is buffering for most of the window but decoded anything at all is alive.
    static let minimumProgressSeconds = 0.25

    /// Skip when the player never reached ready, or reached it and the playhead still did not
    /// move across the sample window.
    static func shouldSkip(reachedReady: Bool, progressedSeconds: Double) -> Bool {
        guard reachedReady else { return true }
        guard progressedSeconds.isFinite else { return true }
        return progressedSeconds < minimumProgressSeconds
    }

    /// A moving playhead with no decoded frame is audio over a black picture: the server
    /// copied video the device is not decoding. That is a failure, not a pass.
    static func hasPicture(reachedReady: Bool, progressedSeconds: Double, decodedFrame: Bool) -> Bool {
        guard !shouldSkip(reachedReady: reachedReady, progressedSeconds: progressedSeconds) else { return false }
        return decodedFrame
    }

    /// An HLS transcode the server started at `requested` seconds reports a clock that either
    /// starts near zero (the server rebased the timeline) or near the offset (copyts kept the
    /// source timestamps). The first needs the offset added to every position report.
    static func hlsBaseOffset(requested: Int, observedStart: Double) -> Double {
        guard requested > 0, observedStart.isFinite else { return 0 }
        return observedStart < 2 ? Double(requested) : 0
    }
}
