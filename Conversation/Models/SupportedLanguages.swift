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
    static func availableOnThisDevice() -> [Locale.Language] {
        // `SFSpeechRecognizer(locale:)` with a bare language code (no
        // region) isn't guaranteed to resolve the way a fully-qualified
        // locale like "en-US" does — match against the actual supported
        // locale list instead of constructing one ourselves.
        let supportedLocales = SFSpeechRecognizer.supportedLocales()

        return candidateIdentifiers.compactMap { identifier in
            guard let matchedLocale = supportedLocales.first(where: { $0.identifier.hasPrefix(identifier) }),
                  let recognizer = SFSpeechRecognizer(locale: matchedLocale),
                  recognizer.supportsOnDeviceRecognition
            else { return nil }
            return Locale.Language(identifier: identifier)
        }
    }
}
