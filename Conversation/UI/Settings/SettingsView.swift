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
                    Link("Manage voices in Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                        .font(.footnote)
                }

                Section("Listening") {
                    Picker("Pause sensitivity", selection: $vadSensitivityRaw) {
                        ForEach(VADSensitivityPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset.rawValue)
                        }
                    }
                    Text("How long a pause has to last before Conversation treats your turn as finished.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Sound") {
                    Toggle("Earcons (processing / done / didn't catch that)", isOn: $audioCuesEnabled)
                }

                Section {
                    ForEach(WhisperModelOption.allCases) { option in
                        WhisperModelRowView(model: option, manager: modelManager)
                    }
                } header: {
                    Text("Language-Detection Models")
                } footer: {
                    Text("Tiny ships with the app, so language-detection needs no network even on a brand new install. Base is an optional download, cached once and used fully offline after that — download it ahead of time here instead of waiting for it to be needed mid-conversation.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Language-detection sensitivity: \(Int(languageIDRejectThreshold * 100))%")
                        Slider(value: $languageIDRejectThreshold, in: 0.5...0.9, step: 0.05)
                        Text("Lower means fewer \"didn't catch that\" rejections, but a higher chance of guessing the wrong language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Language-ID model", selection: $whisperModelRaw) {
                        ForEach(WhisperModelOption.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                } header: {
                    Text("Advanced (Experimental)")
                } footer: {
                    Text("These affect how reliably Conversation tells your two languages apart. A bigger model is likely more accurate but slower and bigger to download — worth A/B testing. Model changes take effect the next time the app loads it (e.g. next launch), not immediately — download it above ahead of time so the switch is instant.")
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
