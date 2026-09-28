import Foundation

/// Update-emails QR codes and the one-time post-playback prompt.
///
/// The Apple TV never sees an email address. Both QR codes open the signup form on
/// nostalgex.app with UTM tags, and the website records which QR the signup came from.
/// Everything here is pure so the gating rules can be tested without a player.
enum SignupPrompt {
    /// Set the moment the prompt is shown (not when it is dismissed), so a crash or a
    /// force-quit while it is on screen can never bring it back.
    static let seenKey = "nostalgex_signup_prompt_seen"

    /// Wall-clock delay between the first successful playback and the prompt becoming
    /// eligible. Keeps it off the first minute of video.
    static let eligibilityDelay: TimeInterval = 75

    /// Short pause after the guide comes back on screen before the card appears, so it
    /// doesn't fight the guide re-focusing the live channel.
    static let guideSettleDelay: TimeInterval = 1.2

    /// Unattended prompt hides itself after this long (counts as dismissed).
    static let autoHideAfter: TimeInterval = 20

    /// Target of the QR for `placement`. `utm_content` matches the analytics placement
    /// wire value so the app-side "shown" count joins the web-side signup count.
    static func url(for placement: AnalyticsSignupPlacement) -> String {
        "https://www.nostalgex.app/?utm_source=appletv&utm_medium=app&utm_campaign=qr_signup&utm_content=\(placement.wireValue)#signup"
    }

    /// True only for a real (non-demo) install that has never seen the prompt and has
    /// had a successful playback at least `eligibilityDelay` ago.
    static func shouldShowSignupPrompt(isDemo: Bool, seen: Bool, playbackReady: Bool) -> Bool {
        !isDemo && !seen && playbackReady
    }

    static func hasBeenSeen(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: seenKey)
    }

    static func markSeen(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }

    /// DEBUG-only escape hatch so the card can be looked at on the simulator in demo
    /// mode: `-forceSignupPrompt` skips the demo/seen gate and shortens the delay.
    /// Release builds ignore it.
    static var isForcedForDebug: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-forceSignupPrompt")
        #else
        return false
        #endif
    }

    /// Automated harnesses that drive playback must not burn the one-time flag.
    @MainActor
    static var isSuppressedForAutomation: Bool {
        let args = ProcessInfo.processInfo.arguments
        return PlaybackSoak.isRequested
            || args.contains("-reproAppReviewFlow")
            || args.contains("-uiTestInstantAuth")
            || args.contains("-uiTestForceSettings")
    }
}
