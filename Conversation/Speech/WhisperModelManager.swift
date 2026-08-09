import Foundation
import WhisperKit

/// Manages WhisperKit model downloads independently of any particular
/// `LanguageIdentifier` instance, so Settings can show real download
/// status/progress and trigger a download ahead of time — not just
/// whenever a conversation turn happens to need it first.
///
/// This is the same UserDefaults-cached-local-folder mechanism from the
/// "WhisperKit needed network on every launch" fix (see `CLAUDE.md`),
/// factored out to one shared owner so onboarding, Settings, and
/// `LanguageIdentifier` all agree on what's actually downloaded instead of
/// tracking it in three places.
@MainActor
final class WhisperModelManager: ObservableObject {
    static let shared = WhisperModelManager()
    private init() {}

    @Published private(set) var downloadProgress: [WhisperModelOption: Double] = [:]
    @Published private(set) var isDownloading: [WhisperModelOption: Bool] = [:]

    private static func cacheKey(for model: WhisperModelOption) -> String {
        "com.joshuabragge.Conversation.whisperModelFolder.\(model.modelName)"
    }

    /// The cached local folder for `model`, if one exists *and* still
    /// actually exists on disk — a stale `UserDefaults` entry pointing at
    /// a folder that's since been deleted (e.g. app reinstall) doesn't count.
    func cachedFolder(for model: WhisperModelOption) -> String? {
        let key = Self.cacheKey(for: model)
        guard let path = UserDefaults.standard.string(forKey: key),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return path
    }

    func isDownloaded(_ model: WhisperModelOption) -> Bool {
        cachedFolder(for: model) != nil
    }

    /// Forgets a cached folder — used when loading from it fails (stale or
    /// corrupt), so the next `download(_:)` call re-fetches instead of
    /// repeating the same failure forever.
    func invalidateCache(for model: WhisperModelOption) {
        UserDefaults.standard.removeObject(forKey: Self.cacheKey(for: model))
    }

    /// Downloads `model` if not already cached, reporting fractional
    /// progress along the way. Safe/cheap to call even if already
    /// downloaded — returns immediately in that case.
    ///
    /// Uses WhisperKit's lower-level `WhisperKit.download(variant:...)`
    /// directly rather than the full `WhisperKit(config:)` convenience
    /// initializer, specifically because this one exposes a progress
    /// callback the convenience initializer doesn't.
    @discardableResult
    func download(_ model: WhisperModelOption) async throws -> String {
        if let cached = cachedFolder(for: model) {
            AppLog.debug(.languageID, "WhisperModelManager: \(model.modelName) already cached at \(cached)")
            return cached
        }

        isDownloading[model] = true
        downloadProgress[model] = 0
        defer { isDownloading[model] = false }

        AppLog.info(.languageID, "WhisperModelManager: downloading \(model.modelName)")
        let start = Date()
        do {
            let folder = try await WhisperKit.download(variant: model.modelName) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress[model] = progress.fractionCompleted
                }
            }
            let path = folder.path
            UserDefaults.standard.set(path, forKey: Self.cacheKey(for: model))
            downloadProgress[model] = 1
            AppLog.info(.languageID, "WhisperModelManager: \(model.modelName) downloaded to \(path) in \(Date().timeIntervalSince(start))s")
            return path
        } catch {
            AppLog.error(.languageID, "WhisperModelManager: \(model.modelName) download failed after \(Date().timeIntervalSince(start))s: \(error.localizedDescription)")
            throw error
        }
    }
}
