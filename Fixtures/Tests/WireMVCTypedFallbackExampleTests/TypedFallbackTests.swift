// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCTypedFallbackExample

// The app's `@NotFound` is typed — `@JSONResponse(status: .notFound)` returning a `Problem` — so an
// unmatched request is answered through the same terminal a route is. These pin what that terminal
// guarantees, over a real server: the status and body, the stated length, a global header, and both error
// tiers.
@Suite(.wiremvc(.swiftHttpServer))
struct TypedFallbackTests {
    /// The baseline: a matched route is unaffected, and carries the global contribution.
    @Test func aMatchedRouteIsServedByItsRoute() async throws {
        try await withClient { client in
            let response = try await client.get("/ping")
            #expect(response.status == 200)
            #expect(try response.json(Pong.self) == Pong(alive: true))
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }

    @Test func anUnmatchedRequestIsAnsweredWithTheFallbacksBody() async throws {
        try await withClient { client in
            let response = try await client.get("/no/such/route")
            #expect(response.status == 404)
            #expect(try response.json(Problem.self) == Problem(detail: "no route matches this request"))
            #expect(response.head?.headerFields[.contentType] == "application/json")
        }
    }

    /// What a raw fallback had to remember and usually did not: a buffered response states its length, so
    /// it is not sent chunked.
    @Test func theFallbackStatesItsLength() async throws {
        try await withClient { client in
            let response = try await client.get("/no/such/route")
            let length = try #require(response.head?.headerFields[.contentLength])
            #expect(Int(length) == response.body.count)
            #expect(response.head?.headerFields[.transferEncoding] == nil)
        }
    }

    @Test func aGlobalMiddlewaresHeaderReachesTheFallback() async throws {
        try await withClient { client in
            let response = try await client.get("/no/such/route")
            #expect(response.status == 404)
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }

    /// `@Query` binds on the fallback as it does on a route, and the handler's own `@ErrorResponse` maps
    /// what it throws, body and all.
    @Test func theHandlersErrorMappingAnswersFirst() async throws {
        try await withClient { client in
            let response = try await client.get("/no/such/route?hint=withdrawn")
            #expect(response.status == 410)
            #expect(try response.json(Problem.self) == Problem(detail: "this was withdrawn"))
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }

    /// The Bootstrap's `@ErrorResponse` is the global tier, consulted after the handler's own.
    @Test func theBootstrapsErrorMappingAnswersWhatTheHandlersDoesNot() async throws {
        try await withClient { client in
            let response = try await client.get("/no/such/route?hint=unavailable")
            #expect(response.status == 503)
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }

    /// A path that exists answered with the wrong method is still the router's 405, not the fallback's 404.
    @Test func aWrongMethodOnARealRouteIsNotTheFallback() async throws {
        try await withClient { client in
            let response = try await client.delete("/ping")
            #expect(response.status == 405)
            #expect(response.head?.headerFields[.allow] == "GET")
        }
    }
}
