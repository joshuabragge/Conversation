import Foundation
import OSLog

enum LogCategory: String, CaseIterable {
    case audioSession = "AudioSession"
    case mic = "Microphone"
    case vad = "VAD"
    case languageID = "LanguageID"
    case transcription = "Transcription"
    case translation = "Translation"
    case speechOutput = "SpeechOutput"
    case conversation = "Conversation"
    case onboarding = "Onboarding"
    case history = "History"
    /// `CaptureStore`/`CaptureListView` — DEBUG-only capture playback and
    /// diagnostics, see `Debug/CaptureRecord.swift`. The category still
    /// exists in Release builds (harmless, just unused) since `AppLog`
    /// itself isn't `#if DEBUG`-gated.
    case debugCapture = "DebugCapture"
}

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case error = "ERROR"
}

/// Central logging facade: every call mirrors to both the system unified
/// logging (visible live in Xcode's console or Console.app when tethered
/// to a Mac) and `LogStore`'s in-memory ring buffer (visible in-app via
/// Settings > Debug Log, and shareable as plain text) — built specifically
/// so problems on a real device, away from a Mac, can still be captured
/// and handed over.
///
/// Safe to call from any thread, including the real-time audio thread
/// (`MicrophoneInputManager`/`VADSegmenter`): `os.Logger` is thread-safe by
/// design, and the in-memory store hop is dispatched to the main actor
/// internally so callers don't need to think about it.
enum AppLog {
    private static let subsystem = "com.joshuabragge.Conversation"

    static func debug(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let text = message()
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(text, privacy: .public)")
        record(.debug, category, text)
    }

    static func info(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let text = message()
        Logger(subsystem: subsystem, category: category.rawValue).info("\(text, privacy: .public)")
        record(.info, category, text)
    }

    static func error(_ category: LogCategory, _ message: @autoclosure () -> String) {
        let text = message()
        Logger(subsystem: subsystem, category: category.rawValue).error("\(text, privacy: .public)")
        record(.error, category, text)
    }

    private static func record(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        Task { @MainActor in
            LogStore.shared.record(level: level, category: category, message: message)
        }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String

    var formatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return "\(f.string(from: timestamp)) [\(level.rawValue)] \(category.rawValue): \(message)"
    }
}

/// In-memory ring buffer of recent log lines. Capped rather than
/// unbounded — this is for "what just happened in the last few minutes,"
/// not a persistent log file.
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()
    private init() {}

    @Published private(set) var entries: [LogEntry] = []
    private let maxEntries = 2000

    func record(level: LogLevel, category: LogCategory, message: String) {
        entries.append(LogEntry(timestamp: Date(), level: level, category: category, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        entries.map(\.formatted).joined(separator: "\n")
    }
}
