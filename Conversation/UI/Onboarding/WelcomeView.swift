import SwiftUI

struct WelcomeView: View {
    let onContinue: () -> Void

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
            .padding(.bottom, 40)
        }
    }
}

#Preview {
    WelcomeView(onContinue: {})
}
