import SwiftUI

/// One-time "get update emails" card shown in the guide after the first real playback.
/// The QR and copy are decorative; GOT IT is the only focusable thing on it.
struct SignupPromptCard: View {
    var onDismiss: (AnalyticsSignupDismissMethod) -> Void

    @FocusState private var buttonFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            QRCodeView(url: SignupPrompt.url(for: .postPlayback))
                .frame(width: 150, height: 150)
                .padding(10)
                .background(Color.white)
                .cornerRadius(8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("GET UPDATE EMAILS")
                        .font(.custom("DMMono-Medium", size: 24))
                        .foregroundStyle(Color(hex: "#00C4FF"))
                    Text("Scan to hear when new channels ship")
                        .font(.custom("DMMono-Regular", size: 19))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("nostalgex.app")
                        .font(.custom("DMMono-Regular", size: 19))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .allowsHitTesting(false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Get update emails. Scan the QR code with your phone to sign up at nostalgex.app")

                Button {
                    onDismiss(.button)
                } label: {
                    Text("GOT IT")
                        .font(.custom("DMMono-Medium", size: 20))
                        .foregroundStyle(buttonFocused ? .black : .white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(buttonFocused ? Color(hex: "#FFE500") : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(NoHighlightButtonStyle())
                .focused($buttonFocused)
                .accessibilityIdentifier("signupPromptGotIt")
                .padding(.top, 6)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.05, green: 0.05, blue: 0.07).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .focusSection()
        .onAppear { buttonFocused = true }
        .onExitCommand { onDismiss(.back) }
    }
}
