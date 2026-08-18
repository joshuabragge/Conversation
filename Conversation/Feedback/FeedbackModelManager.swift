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

    private var session: MLXLMCommon.ChatSession?

    private var bundledDirectory: URL? {
        Bundle.main.url(forResource: Self.bundledResourceName, withExtension: nil)
    }

    /// Loads the bundled model once and reuses the same session (and its
    /// KV cache machinery) across turns. Cheap to call repeatedly once
    /// loaded.
    private func loadedSession() async throws -> MLXLMCommon.ChatSession {
        if let session { return session }
        guard let directory = bundledDirectory else {
            AppLog.error(.feedback, "FeedbackModelManager: \(Self.bundledResourceName) not found in app bundle")
            throw FeedbackModelError.modelNotBundled
        }

        AppLog.info(.feedback, "FeedbackModelManager: loading \(Self.bundledResourceName) from \(directory.path)")
        let start = Date()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: HuggingFaceTokenizerLoader())
        let newSession = MLXLMCommon.ChatSession(container, instructions: LanguageCoachService.systemInstructions)
        session = newSession
        AppLog.info(.feedback, "FeedbackModelManager: ready in \(Date().timeIntervalSince(start))s")
        return newSession
    }

    /// Triggers the model load ahead of time — same "eat the first-call
    /// cost early" reasoning as `LanguageIdentifier.prewarm()` (JIT/graph
    /// setup on first real inference is typically much slower than steady
    /// state) — but callers should only invoke this once
    /// `FeedbackConfig.isEnabled` is true, unlike Whisper's unconditional
    /// prewarm.
    func prewarm() async throws {
        _ = try await loadedSession()
    }

    /// Runs one turn of the coaching conversation and returns the model's
    /// raw response text.
    func generate(prompt: String) async throws -> String {
        let session = try await loadedSession()
        return try await session.respond(to: prompt)
    }
}
