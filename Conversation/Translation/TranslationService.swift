import SwiftUI
import Translation

/// Bridges Apple's `Translation` framework — whose only way to obtain a
/// `TranslationSession` is the `.translationTask` SwiftUI view modifier —
/// into an async facade the rest of the app can call from anywhere
/// (`translate(_:from:to:)`), without every call site needing a view.
///
/// This is the M2 spike for the plan's single riskiest unknown: whether a
/// session obtained this way can be kept alive and reused across repeated
/// calls instead of being torn down between them. Approach: a hidden,
/// always-mounted `TranslationSessionHost` view holds the `.translationTask`
/// binding; its closure runs a loop that drains an `AsyncStream` of pending
/// translation requests using one persistent session per language pair,
/// only re-triggering the task when the pair actually changes.
@MainActor
final class TranslationService: ObservableObject {
    @Published fileprivate(set) var configuration: TranslationSession.Configuration?

    private struct PendingRequest {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }

    private var requestContinuation: AsyncStream<PendingRequest>.Continuation?
    private var pendingRequests: AsyncStream<PendingRequest>?
    private var currentPair: (source: Locale.Language, target: Locale.Language)?

    /// Translates `text` from `source` to `target`, on-device, once the
    /// language pack for that pair is installed. Reuses the live session
    /// for repeated calls with the same pair; only restarts the underlying
    /// `.translationTask` when the pair changes.
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        AppLog.info(.translation, "translate: \"\(text)\" \(source.minimalIdentifier)->\(target.minimalIdentifier)")
        let start = Date()
        let isNewPair = ensureStream(source: source, target: target)
        if isNewPair {
            AppLog.info(.translation, "translate: language pair changed, (re)triggering .translationTask session")
        }
        do {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                requestContinuation?.yield(PendingRequest(text: text, continuation: continuation))
            }
            AppLog.info(.translation, "translate: \"\(result)\" (took \(Date().timeIntervalSince(start))s)")
            return result
        } catch {
            AppLog.error(.translation, "translate: failed after \(Date().timeIntervalSince(start))s: \(error.localizedDescription)")
            throw error
        }
    }

    @discardableResult
    private func ensureStream(source: Locale.Language, target: Locale.Language) -> Bool {
        if let pair = currentPair, pair.source == source, pair.target == target {
            return false
        }
        currentPair = (source, target)
        let (stream, continuation) = AsyncStream<PendingRequest>.makeStream()
        pendingRequests = stream
        requestContinuation = continuation
        configuration = TranslationSession.Configuration(source: source, target: target)
        return true
    }

    /// Invoked by `TranslationSessionHost`'s `.translationTask` closure.
    /// Runs for as long as the configuration stays unchanged and the host
    /// view stays mounted; SwiftUI cancels it automatically otherwise.
    fileprivate func run(session: TranslationSession) async {
        AppLog.info(.translation, "run: TranslationSession became available, draining request stream")
        guard let stream = pendingRequests else {
            AppLog.error(.translation, "run: no pendingRequests stream — shouldn't happen")
            return
        }
        for await request in stream {
            do {
                let response = try await session.translate(request.text)
                request.continuation.resume(returning: response.targetText)
            } catch {
                AppLog.error(.translation, "run: session.translate threw: \(error.localizedDescription)")
                request.continuation.resume(throwing: error)
            }
        }
        AppLog.info(.translation, "run: request stream ended (session torn down or superseded)")
    }
}

/// Invisible-but-full-size view that exists purely to host the
/// `.translationTask` modifier — Translation's session lifecycle is tied to
/// a view's, so this must stay mounted for the app's lifetime (added once
/// at the app root, as a `.background` behind the real UI).
///
/// Deliberately does **not** collapse to a zero-size frame: the first time
/// a language pack needs downloading, the system presents a confirmation
/// sheet anchored to this view's geometry. A `0x0` host gives it nothing to
/// anchor to, so the sheet never surfaces and `session.translate()` just
/// hangs forever waiting for a download that was never confirmed — visible
/// as "STT works, but no translated speech ever comes out, no error either."
struct TranslationSessionHost: View {
    @ObservedObject var service: TranslationService

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .translationTask(service.configuration) { session in
                await service.run(session: session)
            }
    }
}
