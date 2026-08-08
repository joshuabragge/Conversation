import AVFoundation
import Speech

/// Requests and reports on the two permissions the app needs before any
/// recognition can happen: microphone access and speech-recognition
/// authorization. Kept intentionally tiny in M1 — grows an `@Published`
/// status surface for the onboarding flow in M8.
enum PermissionsManager {
    /// Requests microphone permission, resuming on the main actor.
    static func requestMicrophonePermission() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        AppLog.info(.onboarding, "requestMicrophonePermission: granted=\(granted)")
        return granted
    }

    /// Requests on-device speech-recognition authorization.
    static func requestSpeechRecognitionPermission() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        AppLog.info(.onboarding, "requestSpeechRecognitionPermission: granted=\(granted)")
        return granted
    }

    /// Requests both in sequence; both must be granted for recognition to work.
    static func requestAll() async -> Bool {
        let mic = await requestMicrophonePermission()
        let speech = await requestSpeechRecognitionPermission()
        return mic && speech
    }
}
