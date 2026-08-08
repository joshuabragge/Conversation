import SwiftUI

struct ConversationView: View {
    let pair: LanguagePair

    @EnvironmentObject private var translationService: TranslationService
    @StateObject private var audioSession: AudioSessionManager
    @StateObject private var controller: ConversationLoopController
    @State private var showSettings = false

    init(pair: LanguagePair) {
        self.pair = pair
        let session = AudioSessionManager()
        _audioSession = StateObject(wrappedValue: session)
        _controller = StateObject(wrappedValue: ConversationLoopController(audioSession: session, languagePair: pair))
    }

    private var isRunning: Bool { controller.state != .idle }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HeadphoneIndicatorView(isConnected: audioSession.isHeadphonesConnected)

                LanguageChipView(pair: pair, selection: $controller.manualOverride)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if controller.history.isEmpty {
                            Text(isRunning ? "Say something, in either language…" : "Tap start to begin.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        }
                        // Newest first, so the most recent exchange is
                        // immediately visible without scrolling — the
                        // whole point of a hands-free walking app is not
                        // needing to dig through the screen to see what
                        // was just said.
                        ForEach(controller.history.reversed()) { turn in
                            TranscriptBubbleView(turn: turn)
                        }
                    }
                    .padding()
                }

                StatusBannerView(state: controller.state)

                Spacer(minLength: 0)

                Button {
                    isRunning ? controller.stop() : controller.start()
                } label: {
                    VStack(spacing: 8) {
                        Circle()
                            .fill(isRunning ? Color.red : Color.accentColor)
                            .frame(width: 88, height: 88)
                            .overlay {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.white)
                            }
                        Text(isRunning ? "Stop" : "Start listening")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 24)
            }
            .padding(.horizontal)
            .navigationTitle("\(pair.first.displayName) ⇄ \(pair.second.displayName)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(pair: pair, controller: controller)
            }
            .onAppear {
                controller.configure(translationService: translationService)
            }
        }
    }
}

#Preview {
    ConversationView(pair: LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de")))
        .environmentObject(TranslationService())
}
