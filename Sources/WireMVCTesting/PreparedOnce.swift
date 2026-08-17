public import Synchronization

// The `prepare()` pre-step runs once per *process*, which is free in a program (the generated `@main`
// calls it once and serves) and is not free in a test bundle: a suite trait builds the app afresh at every
// suite entry, so a bundle with three `.wiremvc()` suites would call `prepare()` three times.
//
// That matters because of what a pre-step is *for*. `LoggingSystem.bootstrap` — and its metrics and
// tracing counterparts — trap on a second call ("can only be initialized once per process"), so the
// natural body of a `prepare()` turns a multi-suite bundle into a crash. Making the user write an
// idempotent `prepare()` would push the footgun onto them and defeat the point of a one-time hook, so the
// generated test entry routes through this instead. The `@main` does not: it has nothing to guard.

/// Runs `body` at most once per process, returning the same value to every later caller.
///
/// Memoises the `Task` rather than the value, under a mutex, so concurrent suites cannot both start the
/// work: the first caller creates the task, the rest await the one already stored. (Swift Testing may run
/// suites in parallel, so a plain has-it-run flag would race.)
extension WireMVCTesting {
    /// The single in-flight-or-finished pre-step. `any Sendable` because one process has exactly one
    /// Bootstrap and so one `prepare()` return type; the generated caller is the only caller, and it
    /// always asks for the type it just stored.
    private static let inFlight = Mutex<Task<any Sendable, any Error>?>(nil)

    public static func preparedOnce<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = inFlight.withLock { stored -> Task<any Sendable, any Error> in
            if let stored { return stored }
            let created = Task<any Sendable, any Error> { try await body() }
            stored = created
            return created
        }
        let value = try await task.value
        guard let typed = value as? Value else {
            // Unreachable through the generated entry (one Bootstrap, one `prepare()`), so this reports a
            // wiring mistake rather than a user error — hence the explicit message over a force-cast.
            throw WireMVCStartupError.preparedValueTypeMismatch(
                expected: String(describing: Value.self),
                actual: String(describing: type(of: value))
            )
        }
        return typed
    }
}

public enum WireMVCStartupError: Error, CustomStringConvertible {
    case preparedValueTypeMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .preparedValueTypeMismatch(let expected, let actual):
            return
                "WireMVC startup: prepare() was already run in this process and returned \(actual), but \(expected) was requested — more than one Bootstrap ran in one test bundle."
        }
    }
}
