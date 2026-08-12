import AVFoundation
import SwiftUI
import UIKit

struct SettingsView: View {
    let pair: LanguagePair
    @ObservedObject var controller: ConversationLoopController
    // `controller.speechOutput` is a `let` on the controller, so
    // `$controller.speechOutput.rate` can't form a binding through it —
    // observe the same instance directly here instead.
    @ObservedObject private var speechOutput: SpeechOutputService
    @ObservedObject private var modelManager = WhisperModelManager.shared

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    // Bumped whenever the app returns to foreground, so the voice pickers
    // re-query AVSpeechSynthesisVoice.speechVoices() instead of showing
    // whatever was installed when Settings first appeared — tapping
    // "Manage voices in Settings" backgrounds this app while you actually
    // download one, and nothing else would otherwise tell SwiftUI the
    // system's voice list changed underneath it.
    @State private var voiceListRefreshToken = UUID()
    @AppStorage("com.joshuabragge.Conversation.vadSensitivity") private var vadSensitivityRaw = VADSensitivityPreset.medium.rawValue
    @State private var audioCuesEnabled = AudioCueService.isEnabled
    // Same UserDefaults keys as RecognitionConfig's computed properties —
    // @AppStorage gives a live two-way binding for free; RecognitionConfig
    // is what the rest of the app actually reads at call time.
    @AppStorage("com.joshuabragge.Conversation.languageIDRejectThreshold") private var languageIDRejectThreshold = 0.6
    @AppStorage("com.joshuabragge.Conversation.whisperModel") private var whisperModelRaw = WhisperModelOption.tiny.rawValue
    // Same keys as RecognitionConfig.vadSpeechThreshold/.vadMinSpeechDuration
    // — see that file for what these actually control.
    @AppStorage("com.joshuabragge.Conversation.vadSpeechThreshold") private var vadSpeechThreshold = 0.18
    @AppStorage("com.joshuabragge.Conversation.vadMinSpeechDuration") private var vadMinSpeechDuration = 0.15
    @State private var confirmDeleteAllModels = false
    #if DEBUG
    // Same key as RecognitionConfig.allowServerBasedRecognition — see its
    // doc comment for what this actually trades away, and why it's a
    // DEBUG-only diagnostic rather than a user-facing fallback option.
    @AppStorage("com.joshuabragge.Conversation.allowServerBasedRecognition") private var allowServerBasedRecognition = false
    #endif

    init(pair: LanguagePair, controller: ConversationLoopController) {
        self.pair = pair
        self.controller = controller
        self.speechOutput = controller.speechOutput
    }

    private var vadSensitivity: VADSensitivityPreset {
        VADSensitivityPreset(rawValue: vadSensitivityRaw) ?? .medium
    }

    /// Whether there's anything for "Delete downloaded models" to do —
    /// hides the button entirely rather than showing it disabled/no-op
    /// when only the always-present bundled `tiny` model is around.
    private var hasDeletableModels: Bool {
        WhisperModelOption.allCases.contains {
            !modelManager.isBundled($0) && modelManager.isDownloaded($0)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Languages") {
                    NavigationLink {
                        LanguagePairEditorView()
                    } label: {
                        HStack {
                            Text("Languages")
                            Spacer()
                            Text("\(pair.first.displayName) ⇄ \(pair.second.displayName)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Voices") {
                    ForEach(pair.languages, id: \.minimalIdentifier) { language in
                        VoicePickerView(language: language, speechOutput: speechOutput)
                    }
                    .id(voiceListRefreshToken)
                    HStack {
                        Text("Speaking rate")
                        Slider(value: $speechOutput.rate,
                               in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                    }
                    Text("Manage voices in Settings > Accessability > Read & Speak > Voices")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                }

                Section("Listening") {
                    Picker("Pause sensitivity", selection: $vadSensitivityRaw) {
                        ForEach(VADSensitivityPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }
                    Toggle("Ready chime", isOn: $audioCuesEnabled)
                }


                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Noise rejection: \(Int(vadSpeechThreshold * 100))%")
                        Slider(value: $vadSpeechThreshold, in: 0.05...0.5, step: 0.01)
                        Text("Raise this if loud non-speech sounds — traffic, wind, a dog bark — keep starting a turn. Lower it if quiet speech sometimes doesn't.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Minimum sound duration: \(String(format: "%.2f", vadMinSpeechDuration))s")
                        Slider(value: $vadMinSpeechDuration, in: 0.05...0.6, step: 0.05)
                        Text("Raise this to ignore brief loud sounds (a clap, a door slam) that don't sustain long enough to be real speech.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Language-detection sensitivity: \(Int(languageIDRejectThreshold * 100))%")
                        Slider(value: $languageIDRejectThreshold, in: 0.5...0.9, step: 0.05)
                        Text("Lower means fewer \"didn't catch that\" rejections, but a higher chance of guessing the wrong language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Detection Model", selection: $whisperModelRaw) {
                        ForEach(WhisperModelOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    ForEach(WhisperModelOption.allCases) { option in
                        WhisperModelRowView(model: option, manager: modelManager)
                    }
                    Text("Small and up are untested in this app — they're built for full transcription quality, not a quick language-ID pass, so they may be too slow to be worth using here. Try at your own pace; the default stays Tiny.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Swipe a downloaded model to delete just that one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hasDeletableModels {
                        Button("Delete Downloaded Models", role: .destructive) {
                            confirmDeleteAllModels = true
                        }
                    }
                } header: {
                    Text("Advanced (Experimental)")
                }

                Section("Debugging") {
                    NavigationLink("Debug Log") {
                        DebugLogView()
                    }
                    #if DEBUG
                    NavigationLink("Captures") {
                        CaptureListView()
                    }
                    Toggle("Allow server-based speech recognition", isOn: $allowServerBasedRecognition)
                    Text("Diagnostic only. **Sends your recorded speech to Apple's servers** instead of transcribing entirely on-device — leave this off unless you're specifically testing whether an empty transcript is caused by a missing offline recognition model for that language. Debug builds only; never shipped.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: vadSensitivityRaw) { _, newValue in
                if let preset = VADSensitivityPreset(rawValue: newValue) {
                    controller.setVADSensitivity(preset)
                }
            }
            .onChange(of: vadSpeechThreshold) { _, newValue in
                controller.setVADSpeechThreshold(newValue)
            }
            .onChange(of: vadMinSpeechDuration) { _, newValue in
                controller.setVADMinSpeechDuration(newValue)
            }
            .onChange(of: audioCuesEnabled) { _, newValue in
                AudioCueService.isEnabled = newValue
            }
            .onChange(of: whisperModelRaw) { _, _ in
                // Picking a different detection model here used to only
                // change which model the *next* conversation turn would
                // lazily download/load — see `ConversationLoopController.
                // prewarmLanguageModel`'s doc comment for the real device
                // log that showed this landing as dead air on the first
                // spoken turn instead. Kick that off now, in the
                // background, so it's already warm by the time there's a
                // turn to use it.
                controller.prewarmLanguageModel()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    voiceListRefreshToken = UUID()
                }
            }
            .confirmationDialog(
                "Delete every downloaded detection model? The bundled Tiny model stays either way — this just frees up storage, you can always redownload the rest later.",
                isPresented: $confirmDeleteAllModels, titleVisibility: .visible
            ) {
                Button("Delete Downloaded Models", role: .destructive) {
                    modelManager.deleteAllDownloaded()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

#Preview {
    let session = AudioSessionManager()
    let pair = LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de"))
    return SettingsView(pair: pair, controller: ConversationLoopController(audioSession: session, languagePair: pair))
}
