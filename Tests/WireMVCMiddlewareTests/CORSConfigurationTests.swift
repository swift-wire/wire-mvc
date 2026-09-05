// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import HTTPTypes
import Testing

@testable import WireMVCMiddleware

@Suite("CORS configuration")
struct CORSConfigurationTests {
    /// `.originBased` echoes whatever asked, so any origin is allowed but each response names exactly one —
    /// which is what makes it usable with credentials.
    @Test func originBasedEchoesTheRequestOrigin() {
        let policy = CORSConfiguration.AllowOrigin.originBased
        #expect(policy.value(for: "https://app.example") == "https://app.example")
        #expect(policy.variesByRequestOrigin)
    }

    /// `.oneOf` echoes only what it recognises, and sends nothing otherwise — *not* the first entry, which
    /// would tell an unlisted origin it was allowed.
    @Test func oneOfEchoesOnlyListedOrigins() {
        let policy = CORSConfiguration.AllowOrigin.oneOf(["https://a.example", "https://b.example"])
        #expect(policy.value(for: "https://b.example") == "https://b.example")
        #expect(policy.value(for: "https://evil.example") == nil)
        #expect(policy.variesByRequestOrigin)
    }

    /// A fixed answer does not vary by request, so the response must not claim to — advertising `Vary:
    /// Origin` on an invariant response costs cache hits for nothing.
    @Test func fixedPoliciesDoNotVaryByOrigin() {
        #expect(CORSConfiguration.AllowOrigin.all.value(for: "https://a.example") == "*")
        #expect(!CORSConfiguration.AllowOrigin.all.variesByRequestOrigin)
        #expect(!CORSConfiguration.AllowOrigin.custom("https://a.example").variesByRequestOrigin)
        #expect(CORSConfiguration.AllowOrigin.none.value(for: "https://a.example") == nil)
        #expect(!CORSConfiguration.AllowOrigin.none.variesByRequestOrigin)
    }

    /// The combinations that are legal. `.all` without credentials, and credentials with a policy that
    /// names one origin — the standard's own way of allowing any origin with credentials.
    @Test func legalCombinationsConstruct() {
        _ = CORSConfiguration(allowOrigin: .all, allowCredentials: false)
        _ = CORSConfiguration(allowOrigin: .originBased, allowCredentials: true)
        _ = CORSConfiguration(allowOrigin: .oneOf(["https://a.example"]), allowCredentials: true)
        _ = CORSConfiguration(allowOrigin: .custom("https://a.example"), allowCredentials: true)
    }

    // The illegal one — `.all` with credentials — traps at construction rather than shipping a response a
    // browser silently refuses. It cannot be asserted here: a `precondition` failure terminates the process,
    // and Swift Testing has no death test. It is covered by the initialiser's documented precondition and by
    // the fact that the legal combinations above compile and run.
}
