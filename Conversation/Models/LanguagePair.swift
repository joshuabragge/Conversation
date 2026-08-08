import Foundation

/// The two languages a conversation session is between. Order doesn't
/// imply direction — either language can be spoken first; `other(than:)`
/// just picks whichever one wasn't detected.
struct LanguagePair: Equatable, Codable {
    let first: Locale.Language
    let second: Locale.Language

    var languages: [Locale.Language] { [first, second] }

    func other(than language: Locale.Language) -> Locale.Language {
        language == first ? second : first
    }

    // Locale.Language isn't natively Codable in a stable way across OS
    // versions, so persist just the BCP-47 identifier strings.
    private enum CodingKeys: String, CodingKey { case first, second }

    init(first: Locale.Language, second: Locale.Language) {
        self.first = first
        self.second = second
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        first = Locale.Language(identifier: try container.decode(String.self, forKey: .first))
        second = Locale.Language(identifier: try container.decode(String.self, forKey: .second))
    }

    func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(first.minimalIdentifier, forKey: .first)
        try container.encode(second.minimalIdentifier, forKey: .second)
    }
}

extension Locale.Language {
    /// A short BCP-47-ish identifier good enough for persistence, display,
    /// and comparing against WhisperKit/SFSpeechRecognizer language codes.
    var minimalIdentifier: String {
        languageCode?.identifier ?? "und"
    }

    /// Display name in the current locale, e.g. "German" — falls back to
    /// the raw code if the system can't localize it for some reason.
    var displayName: String {
        Locale.current.localizedString(forLanguageCode: minimalIdentifier) ?? minimalIdentifier
    }
}
