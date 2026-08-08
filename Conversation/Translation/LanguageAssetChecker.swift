import Translation

enum LanguagePackStatus {
    case installed
    case supportedNotInstalled
    case unsupported
}

/// Wraps `Translation`'s `LanguageAvailability` to check whether a language
/// pair's on-device pack is ready, so onboarding can surface "this needs a
/// one-time download" before the user's first turn hits it mid-conversation.
///
/// `LanguageAvailability` only answers per-pair questions — there's no
/// bulk enumeration API — which is also why `SupportedLanguages` has to
/// start from a curated candidate list rather than deriving one from
/// Translation directly.
enum LanguageAssetChecker {
    static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguagePackStatus {
        let availability = LanguageAvailability()
        switch await availability.status(from: source, to: target) {
        case .installed: return .installed
        case .supported: return .supportedNotInstalled
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}
