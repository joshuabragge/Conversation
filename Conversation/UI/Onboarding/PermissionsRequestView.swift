import SwiftUI

struct PermissionsRequestView: View {
    let onContinue: () -> Void

    @State private var isRequesting = false
    @State private var deniedMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Microphone & Speech Recognition")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("""
            Conversation needs your microphone to hear you, and on-device \
            speech recognition to transcribe what you say — nothing leaves \
            your phone.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)

            if let deniedMessage {
                Text(deniedMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button {
                isRequesting = true
                Task {
                    let granted = await PermissionsManager.requestAll()
                    isRequesting = false
                    if granted {
                        onContinue()
                    } else {
                        deniedMessage = "Permission denied — enable Microphone and Speech Recognition for Conversation in Settings, then come back."
                    }
                }
            } label: {
                if isRequesting {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Allow & Continue").font(.headline).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequesting)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }
}

#Preview {
    PermissionsRequestView(onContinue: {})
}
