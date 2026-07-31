import Foundation
import Testing

@testable import WireMVCTesting

// `setenv`/`unsetenv` come from the platform C library. Foundation re-exports Darwin on macOS but not Glibc on
// Linux, so the import has to be explicit for the test's own set-up calls to build on both.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `withEnvironment` applies values for the duration of a body and restores what was there before. Unit-level
/// and `.serialized`, because the process environment is global: two of these running concurrently would race
/// on the same keys, which is the constraint the suite-factory parameter documents.
@Suite(.serialized)
struct TestEnvironmentTests {
    private let key = "WIREMVC_TEST_ENVIRONMENT_UNIT"

    @Test func appliesValuesForTheBodyAndUnsetsAfter() async throws {
        #expect(ProcessInfo.processInfo.environment[key] == nil)

        try await WireMVCTesting.withEnvironment([key: "applied"]) {
            #expect(ProcessInfo.processInfo.environment[key] == "applied")
        }

        // The variable had no value before, so it is unset again — not left as an empty string.
        #expect(ProcessInfo.processInfo.environment[key] == nil)
    }

    @Test func restoresAPreviousValueRatherThanUnsetting() async throws {
        unsafe setenv(key, "original", 1)
        defer { unsafe unsetenv(key) }

        try await WireMVCTesting.withEnvironment([key: "overridden"]) {
            #expect(ProcessInfo.processInfo.environment[key] == "overridden")
        }

        #expect(ProcessInfo.processInfo.environment[key] == "original")
    }

    /// The restore runs on the throwing path too — a suite that fails must not leak its configuration into
    /// whatever runs next.
    @Test func restoresWhenTheBodyThrows() async {
        struct Marker: Error {}
        #expect(ProcessInfo.processInfo.environment[key] == nil)

        await #expect(throws: Marker.self) {
            try await WireMVCTesting.withEnvironment([key: "applied"]) { throw Marker() }
        }

        #expect(ProcessInfo.processInfo.environment[key] == nil)
    }

    /// A `nil` provider is the generated factory's "no environment declared" case: the body runs untouched.
    @Test func nilProviderRunsTheBodyUntouched() async throws {
        let provider: (@Sendable () throws -> [String: String])? = nil
        let ran = try await WireMVCTesting.withEnvironment(provider) { true }
        #expect(ran)
        #expect(ProcessInfo.processInfo.environment[key] == nil)
    }
}
