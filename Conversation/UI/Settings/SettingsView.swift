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

    @Environment(\.dismiss) private var dismiss
    @AppStorage("com.joshuabragge.Conversation.vadSensitivity") private var vadSensitivityRaw = VADSensitivityPreset.medium.rawValue
    @State private var audioCuesEnabled = AudioCueService.isEnabled

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
                    LanguagePairEditView()
                }

                Section("Voices") {
                    ForEach(pair.languages, id: \.minimalIdentifier) { language in
                        VoicePickerView(language: language, speechOutput: speechOutput)
                    }
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
        }
    }
}

#Preview {
    let session = AudioSessionManager()
    let pair = LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de"))
    return SettingsView(pair: pair, controller: ConversationLoopController(audioSession: session, languagePair: pair))
}
