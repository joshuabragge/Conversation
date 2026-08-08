import SwiftUI

struct WelcomeView: View {
    let onContinue: () -> Void

    @State private var showDebugLog = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Conversation")
                .font(.largeTitle.bold())
            Text("""
            Put in your headphones, pick two languages, and just talk. \
            Conversation figures out which language you're speaking, \
            translates it, and speaks the translation back — hands-free, \
            entirely on-device.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)
            Spacer()
            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)

            // Reachable here specifically (not just from Settings) because
            // onboarding problems need to be capturable before the user
            // can reach the conversation screen and its Settings sheet.
            Button("Debug Log") { showDebugLog = true }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .sheet(isPresented: $showDebugLog) {
            DebugLogView()
        }
    }
}

#Preview {
    WelcomeView(onContinue: {})
}
