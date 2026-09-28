import Foundation

/// The one-time "get update emails" prompt.
///
/// Rules, in order:
/// 1. Armed by the first successful playback of a real (non-demo) session.
/// 2. Becomes eligible `SignupPrompt.eligibilityDelay` later, so it never lands on the
///    first minute of video.
/// 3. Only ever appears in the guide, never over the full-screen player, so it can't
///    take focus away from a program someone is watching.
/// 4. The seen flag is written the moment it appears. Once per install, full stop.
extension AppState {

    /// Called from the single playback-ready funnel. Cheap no-op after the first call.
    func armSignupPromptIfNeeded() {
        guard signupEligibilityTimer == nil, !signupPromptEligible, !signupPromptVisible else { return }
        guard !SignupPrompt.isSuppressedForAutomation else { return }
        let forced = SignupPrompt.isForcedForDebug
        guard forced || SignupPrompt.shouldShowSignupPrompt(
            isDemo: isDemoMode,
            seen: SignupPrompt.hasBeenSeen(),
            playbackReady: true
        ) else { return }

        let delay = forced ? 3 : SignupPrompt.eligibilityDelay
        signupEligibilityTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.signupEligibilityTimer = nil
                self.signupPromptEligible = true
            }
        }
    }

    /// Show the card if everything still lines up. The guide calls this once it has
    /// settled on screen; the checks are repeated here because demo mode, the seen flag,
    /// or full screen can all have changed while the timer was running.
    ///
    /// Returns true when the card was shown by this call.
    @discardableResult
    func presentSignupPromptIfReady(defaults: UserDefaults = .standard) -> Bool {
        guard !signupPromptVisible, !isFullScreen else { return false }
        let forced = SignupPrompt.isForcedForDebug
        guard forced || SignupPrompt.shouldShowSignupPrompt(
            isDemo: isDemoMode,
            seen: SignupPrompt.hasBeenSeen(defaults),
            playbackReady: signupPromptEligible
        ) else { return false }

        SignupPrompt.markSeen(defaults)
        signupPromptEligible = false
        signupPromptVisible = true
        if !isDemoMode {
            Analytics.track(.signupQRShown(placement: .postPlayback, backend: analyticsBackend))
        }

        signupAutoHideTimer?.invalidate()
        signupAutoHideTimer = Timer.scheduledTimer(withTimeInterval: SignupPrompt.autoHideAfter, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.dismissSignupPrompt(method: .timeout) }
        }
        return true
    }

    func dismissSignupPrompt(method: AnalyticsSignupDismissMethod) {
        signupAutoHideTimer?.invalidate()
        signupAutoHideTimer = nil
        guard signupPromptVisible else { return }
        signupPromptVisible = false
        if !isDemoMode {
            Analytics.track(.signupPromptDismissed(method: method))
        }
    }

    /// Disconnect / demo entry: drop anything pending without sending a dismissal.
    /// The seen flag is left alone on purpose.
    func resetSignupPrompt() {
        signupEligibilityTimer?.invalidate()
        signupEligibilityTimer = nil
        signupAutoHideTimer?.invalidate()
        signupAutoHideTimer = nil
        signupPromptEligible = false
        signupPromptVisible = false
    }
}
