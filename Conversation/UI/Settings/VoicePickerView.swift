import AVFoundation
import SwiftUI

struct VoicePickerView: View {
    let language: Locale.Language
    @ObservedObject var speechOutput: SpeechOutputService

    private var voices: [AVSpeechSynthesisVoice] {
        speechOutput.availableVoices(for: language)
    }

    var body: some View {
        if voices.isEmpty {
            HStack {
                Text(language.displayName)
                Spacer()
                Text("No voice installed").foregroundStyle(.secondary)
            }
        } else {
            Picker(language.displayName, selection: binding) {
                ForEach(voices, id: \.identifier) { voice in
                    Text(voice.name).tag(voice.identifier)
                }
            }
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { speechOutput.voiceOverrides[language.minimalIdentifier] ?? voices.first?.identifier ?? "" },
            set: { speechOutput.voiceOverrides[language.minimalIdentifier] = $0 }
        )
    }
}
