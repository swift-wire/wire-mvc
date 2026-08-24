import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// Suite-scoped process environment for the `.wiremvc(…)` harness.
//
// An app that reads its configuration from the environment (12-factor) can only be pointed at a value a test
// discovers at runtime — a container's assigned host and port, say — by that value being in the *process*
// environment when the graph bootstraps. There is no scoped alternative: `Wire.bootstrap()` runs the app's own
// `@Provides`, which read `ProcessInfo.processInfo.environment` directly, and intercepting that would mean the
// app reading something this module owns — a testing dependency in production code.
//
// So the values are real environment variables, and what the harness adds is *management* rather than
// isolation: they are applied before the bootstrap by construction, and restored on the way out however the
// suite exits. That is the part a hand-written `SuiteTrait` gets wrong — ordering relative to `.wiremvc(…)` is
// expressible only as trait-list order, and a trait that sets and never restores leaks its values into every
// later suite in the process.
//
// Being process-global, the applied values are visible to *every* suite running at the time, not only the one
// that declared them — swift-testing runs suites concurrently, and `.serialized` orders tests within a suite
// rather than excluding other suites. So a given key should be configured by at most one suite in a target. A
// suite that must observe a key's absence, or a different value for it, has to run in its own process (or the
// whole target non-parallel); this is a property of the app reading `ProcessInfo`, not something the harness
// can arrange.

extension WireMVCTesting {
    /// Run `body` with `values` applied to the process environment, restoring the previous state afterwards —
    /// a variable that had no value is unset again rather than left empty.
    ///
    /// The restore runs on every exit, including a throw or cancellation, so a suite cannot leak its
    /// configuration into whatever runs *after* it. It cannot hide it from what runs *alongside* it: see the
    /// note above on concurrent suites.
    public static func withEnvironment<R>(
        _ values: [String: String],
        _ body: () async throws -> R
    ) async throws -> R {
        // Sorted so the applied order is deterministic, which matters only for legibility when a test logs it.
        // Iterated as pairs rather than subscripting by key: Glibc's `setenv` takes a non-optional
        // `UnsafePointer<CChar>` where Darwin's is nullable, so a subscript's `String?` builds on macOS and
        // fails on Linux.
        var restore: [(key: String, value: String?)] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            restore.append((key, ProcessInfo.processInfo.environment[key]))
            unsafe setenv(key, value, 1)
        }
        defer {
            for entry in restore {
                if let value = entry.value {
                    unsafe setenv(entry.key, value, 1)
                } else {
                    unsafe unsetenv(entry.key)
                }
            }
        }
        return try await body()
    }

    /// The generated suite factory's form: a `nil` provider runs `body` untouched, so the harness can wrap
    /// unconditionally and a suite that declares no environment pays nothing.
    ///
    /// The provider is a closure rather than a dictionary because it is evaluated at *suite entry*, after the
    /// traits listed before `.wiremvc(…)` have scoped — which is what lets it read a container endpoint that
    /// does not exist when the trait value is constructed.
    public static func withEnvironment<R>(
        _ provider: (@Sendable () throws -> [String: String])?,
        _ body: () async throws -> R
    ) async throws -> R {
        guard let provider else { return try await body() }
        return try await withEnvironment(provider(), body)
    }
}
