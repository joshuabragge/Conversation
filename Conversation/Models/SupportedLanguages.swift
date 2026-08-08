import Speech

/// Computes which languages are actually usable for a conversation session
/// on *this* device, right now.
///
/// Apple's `Translation` framework has no bulk "list every supported
/// language" API — `LanguageAvailability` only answers per-pair questions
/// (`status(from:to:)`) — so there's no way to build the candidate list
/// purely from Translation's side. Instead: start from a curated list of
/// languages that are broadly available across iOS's on-device Speech and
/// Translation support, then filter it live against
/// `SFSpeechRecognizer.supportedLocales()` + `supportsOnDeviceRecognition`,
/// which *is* fully enumerable. This is a known simplification versus a
/// truly from-scratch derivation — see the plan's risk about on-device
/// coverage gaps not necessarily overlapping between STT/Translation/TTS.
enum SupportedLanguages {
    /// Candidate pool — languages Apple has broadly shipped on-device
    /// Speech + Translation support for as of iOS 18. Not exhaustive by
    /// construction; `availableOnThisDevice()` is the actual source of
    /// truth per-device.
    private static let candidateIdentifiers = [
        "en", "de", "es", "fr", "it", "pt", "ja", "ko",
        "zh", "ar", "hi", "nl", "pl", "ru", "sv", "tr",
    ]

    /// Languages with confirmed on-device `SFSpeechRecognizer` support on
    /// this device, right now.
    ///
    /// Observed in the field: a language can report `supportsOnDeviceRecognition
    /// == false` on one check and `true` on another within the same
    /// device, seemingly because on-device model readiness lags behind
    /// the query rather than being instantly available — bad enough that
    /// it was taking a force-quit-and-relaunch per language to see them
    /// all. Retries a few times within a single call before giving up on
    /// a candidate, accumulating anything that's *ever* confirmed
    /// available rather than requiring every attempt to agree (once
    /// confirmed available, it's trusted — the flakiness so far has only
    /// looked like "not ready yet," never "available then revoked").
    static func availableOnThisDevice() async -> [Locale.Language] {
        var confirmed: [Locale.Language] = []
        let maxAttempts = 5

        for attempt in 1...maxAttempts {
            let found = checkOnce()
            AppLog.info(.onboarding, "SupportedLanguages attempt \(attempt)/\(maxAttempts): found \(found.map(\.minimalIdentifier))")

            for language in found where !confirmed.contains(language) {
                confirmed.append(language)
            }

            if confirmed.count >= candidateIdentifiers.count {
                AppLog.info(.onboarding, "SupportedLanguages: all candidates confirmed, stopping early")
                break
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        AppLog.info(.onboarding, "SupportedLanguages: final result \(confirmed.map(\.minimalIdentifier))")
        return confirmed
    }

    private static func checkOnce() -> [Locale.Language] {
        // `SFSpeechRecognizer(locale:)` with a bare language code (no
        // region) isn't guaranteed to resolve the way a fully-qualified
        // locale like "en-US" does — match against the actual supported
        // locale list instead of constructing one ourselves.
        let supportedLocales = SFSpeechRecognizer.supportedLocales()

        return candidateIdentifiers.compactMap { identifier in
            guard let matchedLocale = supportedLocales.first(where: { $0.identifier.hasPrefix(identifier) }) else {
                return nil
            }
            guard let recognizer = SFSpeechRecognizer(locale: matchedLocale) else {
                AppLog.debug(.onboarding, "SupportedLanguages: \(identifier) matched locale \(matchedLocale.identifier) but SFSpeechRecognizer init failed")
                return nil
            }
            guard recognizer.supportsOnDeviceRecognition else {
                AppLog.debug(.onboarding, "SupportedLanguages: \(identifier) (\(matchedLocale.identifier)) not yet on-device-capable")
                return nil
            }
            return Locale.Language(identifier: identifier)
        }
    }
}
