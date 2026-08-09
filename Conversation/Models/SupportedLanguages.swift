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

    /// A standard/default region for each candidate — checked first,
    /// before falling back to whatever other regional variant is
    /// available. See `checkOnce`'s doc comment for why this matters: it
    /// isn't just a tie-breaker, it's the fix for a real bug.
    private static let preferredRegion: [String: String] = [
        "en": "en-US", "de": "de-DE", "es": "es-ES", "fr": "fr-FR",
        "it": "it-IT", "pt": "pt-BR", "ja": "ja-JP", "ko": "ko-KR",
        "zh": "zh-CN", "ar": "ar-SA", "hi": "hi-IN", "nl": "nl-NL",
        "pl": "pl-PL", "ru": "ru-RU", "sv": "sv-SE", "tr": "tr-TR",
    ]

    /// Languages with confirmed on-device `SFSpeechRecognizer` support on
    /// this device, right now.
    ///
    /// Retries a few times within a single call before giving up on a
    /// candidate — belt-and-suspenders in case on-device model readiness
    /// genuinely does lag right after a fresh install, though the much
    /// bigger effect (see `checkOnce`) turned out to be about *which*
    /// locale variant gets checked, not timing. Accumulates anything
    /// that's *ever* confirmed available across attempts, rather than
    /// requiring every attempt to agree.
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

    /// **The real bug this fixes**: `SFSpeechRecognizer.supportedLocales()`
    /// returns a `Set<Locale>`, and Swift randomizes `Set` iteration order
    /// per process (deliberately, to resist hash-flooding — not a bug in
    /// Swift). The original code did `.first(where: { $0.identifier.hasPrefix(identifier) })`
    /// over that Set, which meant it checked an effectively **random**
    /// regional variant of each language on every single launch — and a
    /// real device log showed exactly that: run 1 checked `de-AT`,
    /// `zh-HK`, `es-419` (mostly *not* on-device-capable) and found only
    /// `["fr"]`; run 2 of the same app on the same device checked `de-DE`
    /// (implicitly, via this fix's predecessor happening to land there),
    /// `zh-CN`, `es-CO` and found `["en", "de"]` instead — a completely
    /// different result from a relaunch alone, with nothing else changed.
    /// This wasn't a timing/readiness issue at all.
    ///
    /// Fix: check a known-standard region for each language first
    /// (`preferredRegion`), then deterministically try every other
    /// matching variant in sorted order — not whichever the Set happened
    /// to hand back first — so results are consistent across launches and
    /// prefer the variant most likely to actually have on-device support.
    private static func checkOnce() -> [Locale.Language] {
        let sortedLocales = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }

        return candidateIdentifiers.compactMap { identifier -> Locale.Language? in
            let preferredMatch = preferredRegion[identifier].flatMap { preferred in
                sortedLocales.first { $0.identifier == preferred }
            }
            let fallbackMatches = sortedLocales.filter { $0.identifier.hasPrefix(identifier) }
            let orderedCandidates = ([preferredMatch].compactMap { $0 }) + fallbackMatches

            for matchedLocale in orderedCandidates {
                guard let recognizer = SFSpeechRecognizer(locale: matchedLocale) else { continue }
                if recognizer.supportsOnDeviceRecognition {
                    AppLog.debug(.onboarding, "SupportedLanguages: \(identifier) matched via \(matchedLocale.identifier)")
                    return Locale.Language(identifier: identifier)
                }
                AppLog.debug(.onboarding, "SupportedLanguages: \(identifier) (\(matchedLocale.identifier)) not on-device-capable")
            }
            return nil
        }
    }
}
