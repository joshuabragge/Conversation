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

    init(pair: LanguagePair, controller: ConversationLoopController) {
        self.pair = pair
        self.controller = controller
        self.speechOutput = controller.speechOutput
    }

    private var vadSensitivity: VADSensitivityPreset {
        VADSensitivityPreset(rawValue: vadSensitivityRaw) ?? .medium
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
                } header: {
                    Text("Advanced (Experimental)")
                }

                Section("Debugging") {
                    NavigationLink("Debug Log") {
                        DebugLogView()
                    }
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
            .onChange(of: audioCuesEnabled) { _, newValue in
                AudioCueService.isEnabled = newValue
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    voiceListRefreshToken = UUID()
                }
            }
        }
    }
}

#Preview {
    let session = AudioSessionManager()
    let pair = LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de"))
    return SettingsView(pair: pair, controller: ConversationLoopController(audioSession: session, languagePair: pair))
}
