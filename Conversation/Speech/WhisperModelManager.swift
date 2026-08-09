import Foundation
import WhisperKit

enum WhisperModelManagerError: LocalizedError {
    case cannotDeleteBundledModel

    var errorDescription: String? {
        switch self {
        case .cannotDeleteBundledModel:
            return "The bundled model ships inside the app itself and can't be deleted separately."
        }
    }
}

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

    /// The local folder for `model` if it ships inside the app bundle
    /// itself, added via `project.yml`'s folder-reference source entry —
    /// currently just `.tiny`. Checked before anything cache/network
    /// related, so the default model needs no network at all, even on a
    /// brand new install (see CLAUDE.md's "WhisperKit needed network on
    /// every launch" entry for why that used to not be true even after
    /// the first launch).
    func bundledFolder(for model: WhisperModelOption) -> String? {
        guard let resourceName = model.bundledResourceName,
              let url = Bundle.main.url(forResource: resourceName, withExtension: nil)
        else { return nil }
        return url.path
    }

    func isBundled(_ model: WhisperModelOption) -> Bool {
        bundledFolder(for: model) != nil
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
        isBundled(model) || cachedFolder(for: model) != nil
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
        if let bundled = bundledFolder(for: model) {
            AppLog.debug(.languageID, "WhisperModelManager: \(model.modelName) is bundled with the app at \(bundled), skipping download")
            return bundled
        }
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

    /// Deletes `model`'s downloaded files from disk and forgets the cached
    /// folder, freeing up the storage it used — the counterpart to
    /// `download(_:)` for the "I only wanted to try this one" case. The
    /// bundled `tiny` model can't be deleted this way (nothing to remove
    /// short of uninstalling the app) — throws rather than silently
    /// no-op-ing so a caller looping over "delete everything" notices,
    /// instead of the tiny model quietly not being covered by that loop.
    ///
    /// If `model` was the active detection model
    /// (`RecognitionConfig.whisperModel`), resets the selection back to
    /// `.tiny` — leaving Settings pointed at a model with nothing left on
    /// disk would silently trigger a redownload the next time
    /// `LanguageIdentifier` actually needs it, i.e. unexpectedly needing
    /// network mid-walk instead of using the always-available bundled model.
    func delete(_ model: WhisperModelOption) throws {
        guard !isBundled(model) else {
            throw WhisperModelManagerError.cannotDeleteBundledModel
        }
        if let folder = cachedFolder(for: model) {
            try FileManager.default.removeItem(atPath: folder)
            AppLog.info(.languageID, "WhisperModelManager: deleted \(model.modelName) from \(folder)")
        }
        invalidateCache(for: model)
        downloadProgress[model] = nil
        isDownloading[model] = nil
        if RecognitionConfig.whisperModel == model {
            AppLog.info(.languageID, "WhisperModelManager: \(model.modelName) was the active detection model, resetting to tiny")
            RecognitionConfig.whisperModel = .tiny
        }
    }

    /// Deletes every currently-downloaded model except the bundled `tiny`
    /// one — the "free up storage" bulk action in Settings. Best-effort:
    /// keeps going if one deletion fails rather than aborting the rest,
    /// and returns whichever models actually failed so the caller can
    /// surface that instead of silently claiming success.
    @discardableResult
    func deleteAllDownloaded() -> [WhisperModelOption] {
        var failed: [WhisperModelOption] = []
        for model in WhisperModelOption.allCases where !isBundled(model) && isDownloaded(model) {
            do {
                try delete(model)
            } catch {
                AppLog.error(.languageID, "WhisperModelManager: failed to delete \(model.modelName): \(error.localizedDescription)")
                failed.append(model)
            }
        }
        return failed
    }
}
