import Foundation

/// Owns persisted conversation history — one JSON file on disk
/// (`chatHistory.json` in Application Support), not UserDefaults, since
/// this is meant to grow across many walks rather than stay small like the
/// handful of settings UserDefaults already backs elsewhere in the app.
///
/// `ConversationLoopController` calls `upsert(_:)` after every completed
/// turn (not just once at `stop()`), keyed by a session ID it generates in
/// `start()` — so a session is saved incrementally as it happens. This
/// matters for a hands-free walking app specifically: swiping the app away
/// mid-walk instead of tapping Stop is a completely normal way to end a
/// session, and only persisting on an explicit `stop()` would silently
/// lose everything since the last one.
@MainActor
final class ConversationHistoryStore: ObservableObject {
    static let shared = ConversationHistoryStore()

    /// Newest first, matching the rest of the app's "most recent thing is
    /// immediately visible" convention (see `ConversationView`'s reversed
    /// history).
    @Published private(set) var sessions: [ChatSession] = []

    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("chatHistory.json")
        load()
    }

    /// Creates or updates `session` in place, matched by `id`. Safe/cheap to
    /// call after every single turn — new sessions are inserted at the
    /// front so the list stays newest-first without needing to re-sort.
    func upsert(_ session: ChatSession) {
        guard !session.turns.isEmpty else { return }
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
            AppLog.info(.history, "upsert: new session \(session.id), \(session.languagePair.first.minimalIdentifier)/\(session.languagePair.second.minimalIdentifier)")
        }
        persist()
    }

    func delete(_ session: ChatSession) {
        AppLog.info(.history, "delete: session \(session.id)")
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    func deleteAll() {
        AppLog.info(.history, "deleteAll: removing \(sessions.count) session(s)")
        sessions.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            AppLog.debug(.history, "load: no history file yet at \(fileURL.path)")
            return
        }
        do {
            sessions = try JSONDecoder().decode([ChatSession].self, from: data)
            AppLog.info(.history, "load: loaded \(sessions.count) session(s)")
        } catch {
            AppLog.error(.history, "load: failed to decode history, starting empty: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLog.error(.history, "persist: failed to write history: \(error.localizedDescription)")
        }
    }
}
