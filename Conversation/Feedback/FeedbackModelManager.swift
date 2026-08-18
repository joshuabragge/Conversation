import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Bridges swift-transformers' `Tokenizer` (`Tokenizers.AutoTokenizer`,
/// already a transitive dependency of WhisperKit — promoted to a direct
/// one here, see `project.yml`) to the `TokenizerLoader` protocol
/// `MLXLMCommon` expects. MLX's model loading is deliberately decoupled
/// from any specific tokenizer backend — the two protocols are
/// structurally almost identical (both modeled on the same Hugging Face
/// tokenizer shape) but don't share parameter labels, so a thin adapter is
/// still required rather than direct conformance.
private struct HuggingFaceTokenizerAdapter: MLXLMCommon.Tokenizer {
    let wrapped: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        wrapped.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        wrapped.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { wrapped.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { wrapped.convertIdToToken(id) }

    var bosToken: String? { wrapped.bosToken }
    var eosToken: String? { wrapped.eosToken }
    var unknownToken: String? { wrapped.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try wrapped.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

private struct HuggingFaceTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        HuggingFaceTokenizerAdapter(wrapped: try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

enum FeedbackModelError: LocalizedError {
    case modelNotBundled

    var errorDescription: String? {
        switch self {
        case .modelNotBundled:
            return "The local feedback model isn't bundled with this build."
        }
    }
}

/// Owns the local feedback-coach LLM's load state — the `Feedback/`
/// equivalent of `WhisperModelManager`/`LanguageIdentifier`, collapsed
/// into one type since (unlike Whisper) this model is *only* ever bundled,
/// never downloaded, so there's no separate download-progress bookkeeping
/// to factor out for Settings.
///
/// Two deliberate differences from `WhisperModelManager`/`LanguageIdentifier`:
/// - **Not `@MainActor`.** `WhisperModelManager` itself is `@MainActor`,
///   but it only does download bookkeeping — the actual CoreML inference
///   happens inside WhisperKit's own internals. This class holds the
///   `ChatSession` and drives real, multi-second MLX generation directly,
///   so it's its own `actor` instead, keeping that work off the main
///   actor/UI thread entirely rather than relying on an internal framework
///   detail to do it.
/// - **Only loaded when `FeedbackConfig.isEnabled`.** Bundling ships the
///   weights on disk for every install (see `FeedbackConfig`'s doc
///   comment), but loading them into memory has a real cost that users who
///   never turn the feature on shouldn't pay — callers (`prewarm()`,
///   `ConversationLoopController`'s pipeline hook) are expected to check
///   the flag themselves before calling in, this type doesn't re-check it.
actor FeedbackModelManager {
    static let shared = FeedbackModelManager()
    private init() {}

    /// Folder name matching the bundled model's on-disk layout — see the
    /// `type: folder` resource entry in `project.yml` and
    /// `Conversation/Resources/LLMModels/gemma-3-270m-it-4bit/`.
    private static let bundledResourceName = "gemma-3-270m-it-4bit"

    private var container: MLXLMCommon.ModelContainer?

    private var bundledDirectory: URL? {
        Bundle.main.url(forResource: Self.bundledResourceName, withExtension: nil)
    }

    /// Loads the bundled model weights once and reuses the same
    /// `ModelContainer` across turns — the expensive part (JIT/graph setup,
    /// weight loading). Cheap to call repeatedly once loaded.
    ///
    /// Deliberately does **not** cache a `ChatSession` alongside it. A
    /// `ChatSession` is MLXLMCommon's *multi-turn conversational*
    /// abstraction — every `respond(to:)` call on the same session
    /// accumulates onto its KV cache/message history rather than starting
    /// fresh. An earlier version of this method cached one `ChatSession`
    /// here and reused it forever, which meant every turn's feedback
    /// request silently continued the *same* unbounded conversation for
    /// the app's whole process lifetime — growing latency the longer a
    /// walk went on, no reset at conversation-session boundaries (stop/
    /// start, language-pair change), and no cap against Gemma 3 270M's
    /// 32768-token context window. Each coaching note is supposed to be an
    /// independent judgment about one isolated utterance (see
    /// `LanguageCoachService.prompt(for:)`, which already frames every
    /// call as self-contained), so `generate(prompt:)` now builds a fresh
    /// `ChatSession` per call instead — cheap (re-tokenizing a short
    /// system prompt, not reloading the model) and keeps every call's
    /// latency and behavior independent of how long the app has been
    /// running or how many turns came before it.
    private func loadedContainer() async throws -> MLXLMCommon.ModelContainer {
        if let container { return container }
        guard let directory = bundledDirectory else {
            AppLog.error(.feedback, "FeedbackModelManager: \(Self.bundledResourceName) not found in app bundle")
            throw FeedbackModelError.modelNotBundled
        }

        AppLog.info(.feedback, "FeedbackModelManager: loading \(Self.bundledResourceName) from \(directory.path)")
        let start = Date()
        let newContainer = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: HuggingFaceTokenizerLoader())
        container = newContainer
        AppLog.info(.feedback, "FeedbackModelManager: ready in \(Date().timeIntervalSince(start))s")
        return newContainer
    }

    /// Triggers the model load ahead of time — same "eat the first-call
    /// cost early" reasoning as `LanguageIdentifier.prewarm()` (JIT/graph
    /// setup on first real inference is typically much slower than steady
    /// state) — but callers should only invoke this once
    /// `FeedbackConfig.isEnabled` is true, unlike Whisper's unconditional
    /// prewarm.
    func prewarm() async throws {
        _ = try await loadedContainer()
    }

    /// Runs one independent, stateless coaching request and returns the
    /// model's raw response text — see `loadedContainer`'s doc comment for
    /// why this builds a new `ChatSession` per call rather than reusing one.
    func generate(prompt: String) async throws -> String {
        let container = try await loadedContainer()
        let session = MLXLMCommon.ChatSession(container, instructions: LanguageCoachService.systemInstructions)
        return try await session.respond(to: prompt)
    }
}
