import Foundation

struct TimeoutError: Error {}

/// Races `operation` against a `seconds` deadline; throws `TimeoutError` if
/// the deadline wins, cancelling whichever task loses. Used to turn silent
/// hangs (e.g. a `TranslationSession` call stuck on an unconfirmed
/// language-pack download) into a visible, diagnosable error.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
