import SwiftUI

struct ConversationView: View {
    let pair: LanguagePair

    @EnvironmentObject private var translationService: TranslationService
    @StateObject private var audioSession: AudioSessionManager
    @StateObject private var controller: ConversationLoopController
    @State private var showSettings = false
    @State private var showHistory = false

    init(pair: LanguagePair) {
        self.pair = pair
        let session = AudioSessionManager()
        _audioSession = StateObject(wrappedValue: session)
        _controller = StateObject(wrappedValue: ConversationLoopController(audioSession: session, languagePair: pair))
    }

    private var isRunning: Bool { controller.state != .idle }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .leading) {
                mainContent

                if showHistory {
                    // Tapping outside the drawer dismisses it, same as any
                    // standard nav-drawer pattern.
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { showHistory = false }

                    ChatHistoryDrawerView(isPresented: $showHistory)
                        .frame(width: 300)
                        .frame(maxHeight: .infinity)
                        .background(.background)
                        .ignoresSafeArea(edges: .horizontal)
/*                        .ignoresSafeArea(edges: .vertical)*/
                        .transition(.move(edge: .leading))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showHistory)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Widerhall")
                        .font(.headline)
                }
            }
            /*.navigationTitle("\(pair.first.displayName) ⇄ \(pair.second.displayName)")*/
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                if showHistory != true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(pair: pair, controller: controller)
            }
            .onAppear {
                controller.configure(translationService: translationService)
            }
            .onChange(of: pair) { _, newPair in
                // `pair` can now change without this whole view being torn
                // down and recreated — Settings' LanguagePairEditorView
                // updates AppState.languagePair in place (no more full
                // onboarding restart), and SwiftUI preserves this view's
                // @StateObject-backed controller across that re-render
                // since its identity doesn't change. Push the new pair
                // into the live controller explicitly, or it'd keep using
                // whichever pair it was originally constructed with.
                AppLog.info(.conversation, "ConversationView: language pair changed to \(newPair.first.minimalIdentifier)/\(newPair.second.minimalIdentifier)")
                let wasRunning = controller.state != .idle
                if wasRunning { controller.stop() }
                controller.updateLanguagePair(newPair)
                if wasRunning { controller.start() }
            }
        }
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            Spacer()
            HStack {
                Spacer()
                LanguageChipView(pair: pair, selection: $controller.manualOverride)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    /*if controller.history.isEmpty {
                        Text(isRunning ? "Say something, in either language…" : "Tap start to begin.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }*/
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
                            /*Image(systemName: isRunning ? "waveform" : "waveform")
                                .font(.system(size: 48))
                                .foregroundStyle(.white)*/
                                if isRunning {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.white)
                                        .symbolEffect(.pulse)
                                }
                                else {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.white)
                                }


                        }
                    HeadphoneIndicatorView(isConnected: audioSession.isHeadphonesConnected)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }
}



#Preview {
    ConversationView(pair: LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de")))
        .environmentObject(TranslationService())
}
