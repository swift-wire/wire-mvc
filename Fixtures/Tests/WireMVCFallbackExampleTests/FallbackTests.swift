// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCFallbackExample

// The app declares no `@NotFound`, so an unmatched request reaches the plugin's **synthesised** 404. This
// suite exists to prove a global `@Middleware`'s contributed header reaches that fallback — the one branch
// every other fixture misses by virtue of writing its own handler.
@Suite(.wiremvc(.swiftHttpServer))
struct FallbackTests {
    /// The baseline: a matched route carries the global contribution.
    @Test func matchedRouteCarriesTheGlobalHeader() async throws {
        try await withClient { client in
            let response = try await client.get("/ping")
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }

    /// The point of the fixture. Before the synthesised fallback bound its request context and resolved,
    /// this 404 went out bare — a global security or CORS header would have been absent from exactly the
    /// response nobody declared and therefore nobody checked.
    @Test func synthesisedNotFoundCarriesTheGlobalHeader() async throws {
        try await withClient { client in
            let response = try await client.get("/no/such/route")
            #expect(response.status == 404)
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }

    /// `/ping` exists but only answers `GET`, so a `DELETE` is a **405**, not a 404 — and it names what
    /// the resource does accept. Previously both came back `404`, which tells a client to fix a URL that
    /// was already right.
    ///
    /// Asserted over a real server rather than only against the trie, because the status and the `Allow`
    /// header are the router's to emit, and the trie only decides *which* answer is owed.
    @Test func aWrongMethodOnARealRouteIsMethodNotAllowed() async throws {
        try await withClient { client in
            let response = try await client.delete("/ping")
            #expect(response.status == 405)
            #expect(response.head?.headerFields[.allow] == "GET")
        }
    }

    /// The 405 carries global-middleware contributions, like every other response.
    ///
    /// It gets them the way the 404 does: the router resolves *which* answer is owed and hands the allowed
    /// set to a **synthesised** `registerMethodNotAllowed` handler, which has a `ResponseHeaderCarrying`
    /// context and drains the registry. A router-written head could not — it is not constrained to such a
    /// context — and a bare 405 is precisely the gap that once let a 404 escape without a security or CORS
    /// header: a response nobody declares is the one nobody checks.
    @Test func aMethodNotAllowedCarriesTheGlobalHeader() async throws {
        try await withClient { client in
            let response = try await client.delete("/ping")
            #expect(response.status == 405)
            #expect(response.head?.headerFields[.allow] == "GET")
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }
}

// The gate path. A gate answers the request itself, so the terminal — and its drain — never runs. These
// are the only tests anywhere that exercise `respondingWith`, and the only ones that exercise `.setIfAbsent`.
@Suite(.wiremvc(.swiftHttpServer))
struct GateTests {
    /// A gate's own response carries what middleware contributed. Without `respondingWith` draining, the
    /// global `x-stamp` would be missing from exactly the responses that most want a header — a challenge,
    /// a redirect, a 403.
    @Test func aGateResponseCarriesContributedFields() async throws {
        try await withClient { client in
            let response = try await client.get("/gated")
            #expect(response.status == 401)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.wwwAuthenticate] == #"Bearer realm="fixture""#, "the gate's own field")
            #expect(fields[.init("x-stamp")!] == "global", "a global contribution reached a gated response")
        }
    }

    /// `.setIfAbsent` defers. `Stamp` runs outside the gate and has already set `x-stamp`, so the gate's
    /// own `.setIfAbsent` must lose — on a matched route as well as on the gated one above.
    @Test func setIfAbsentDefersToAContributorAlreadyThere() async throws {
        try await withClient { client in
            let response = try await client.get("/ping")
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.init("x-stamp")!] == "global")
        }
    }
}

// CORS over a live server. The app configures `.oneOf` with credentials — allowed because it names one
// origin per response, where `.all` with credentials traps at construction.
@Suite(.wiremvc(.swiftHttpServer))
struct CORSTests {
    /// An actual request from a listed origin: the origin is echoed, credentials advertised, `Vary` says the
    /// answer depends on `Origin`, and `Expose-Headers` names what script may read.
    @Test func anAllowedOriginGetsTheCORSFields() async throws {
        try await withClient { client in
            let response = try await client.get("/ping", headers: ["Origin": "https://allowed.example"])
            #expect(response.status == 200)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.accessControlAllowOrigin] == "https://allowed.example")
            #expect(fields[.accessControlAllowCredentials] == "true")
            #expect(fields[values: .vary].contains("Origin"))
            #expect(fields[.accessControlExposeHeaders] == "x-stamp")
        }
    }

    /// An unlisted origin is answered *without* the field. Echoing it, or falling back to the first listed
    /// entry, would tell the browser it was allowed.
    @Test func anUnlistedOriginGetsNoAllowOrigin() async throws {
        try await withClient { client in
            let response = try await client.get("/ping", headers: ["Origin": "https://evil.example"])
            #expect(response.status == 200)
            #expect(response.head?.headerFields[.accessControlAllowOrigin] == nil)
        }
    }

    /// A same-origin request carries no `Origin`, so it must gain no CORS fields at all — and in particular
    /// no `Vary: Origin`, which would cost cache hits on every response that never varies.
    @Test func aRequestWithoutOriginIsUntouched() async throws {
        try await withClient { client in
            let fields = try #require(try await client.get("/ping").head?.headerFields)
            #expect(fields[.accessControlAllowOrigin] == nil)
            #expect(!fields[values: .vary].contains("Origin"))
        }
    }

    /// Two requests to the *same* URL, in one test, against one server — the shape every other test here
    /// misses, because each `@Test` binds a fresh port and so never reuses a cache entry.
    ///
    /// `/ping` answers with `Cache-Control: max-age=5`, which is an ordinary thing for a route to return.
    /// A URLSession that caches will serve the second GET from the copy stored for the first, and that copy
    /// was made for a request carrying no `Origin` — so the CORS fields come back missing and the middleware
    /// looks broken when it never ran. `TestClient` disables caching for exactly this reason; this pins it.
    @Test func aCacheableRouteIsNotReplayedForALaterRequest() async throws {
        try await withClient { client in
            let plain = try #require(try await client.get("/ping").head?.headerFields)
            #expect(plain[.cacheControl] == "max-age=5", "the route really is cacheable")
            #expect(plain[.accessControlAllowOrigin] == nil)

            let fields = try #require(
                try await client.get("/ping", headers: ["Origin": "https://allowed.example"]).head?.headerFields
            )
            #expect(fields[.accessControlAllowOrigin] == "https://allowed.example", "reached the server")
        }
    }

    /// The preflight. Answered by the middleware rather than routed — it is an `OPTIONS` to a path whose
    /// real route is a `GET`, so there is nothing to dispatch to. It carries the preflight-only fields *and*
    /// the shared ones, which only holds because `respondingWith` drains the contributions into it.
    @Test func aPreflightIsAnsweredWithBothFieldSets() async throws {
        try await withClient { client in
            let response = try await client.send(
                "OPTIONS",
                "/ping",
                headers: ["Origin": "https://allowed.example", "Access-Control-Request-Method": "POST"]
            )
            #expect(response.status == 204)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.accessControlAllowMethods] == "GET, POST", "preflight-only")
            // Field names are case-insensitive, and `rawName` keeps canonical casing ("Content-Type").
            #expect(fields[.accessControlAllowHeaders]?.lowercased() == "content-type", "preflight-only")
            #expect(fields[.accessControlMaxAge] == "600", "preflight-only")
            #expect(fields[.accessControlAllowOrigin] == "https://allowed.example", "drained contribution")
            #expect(fields[.accessControlAllowCredentials] == "true", "drained contribution")
        }
    }
}

// A controller-scope contributor alongside the global one. Both write to the same registry, so both fields
// must arrive — reproducing a case where the global one was being lost.
@Suite(.wiremvc(.swiftHttpServer))
struct TwoScopeContributionTests {
    @Test func globalAndControllerContributionsBothArrive() async throws {
        try await withClient { client in
            let fields = try #require(try await client.get("/ping").head?.headerFields)
            #expect(fields[.init("x-controller")!] == "controller", "the controller-scope contribution")
            #expect(fields[.init("x-stamp")!] == "global", "the global contribution")
        }
    }
}

// Route identity on the box, end to end. `ControllerStamp` folds *once*, on the controller, and reports the
// matched template and parameters of whichever route it wrapped; `Stamp` folds globally and reports that it
// can see no route at all. Before this the fold was never told which route it was folded onto, so a
// per-route rule needed a distinct `FactoryKey` and middleware type per route.
@Suite(.wiremvc(.swiftHttpServer))
struct RouteIdentityTests {
    /// The template is the registration text, not the request path — `/ping/echo/{name}` for a request to
    /// `/ping/echo/world`. That is the half a rule keys on: the values alone cannot tell two routes apart.
    @Test func aFoldedMiddlewareSeesTheMatchedTemplateAndParameters() async throws {
        try await withClient { client in
            let fields = try #require(try await client.get("/ping/echo/world").head?.headerFields)
            #expect(fields[.init("x-route-template")!] == "/ping/echo/{name}")
            #expect(fields[.init("x-route-params")!] == "name=world")
        }
    }

    /// The *same* middleware, folded once on the controller, reporting a different route — which is the
    /// thing that could not be written before.
    @Test func oneFoldReportsADifferentRoutePerRoute() async throws {
        try await withClient { client in
            let ping = try #require(try await client.get("/ping").head?.headerFields)
            #expect(ping[.init("x-route-template")!] == "/ping")

            let echo = try #require(try await client.get("/ping/echo/other").head?.headerFields)
            #expect(echo[.init("x-route-template")!] == "/ping/echo/{name}")
        }
    }

    /// A matched route that declares no parameters reports `(empty)`, never `(none)`. The box keeps "no
    /// route" and "a route with no parameters" apart, and this is the response that proves the distinction
    /// survives to a middleware rather than living only in a doc comment.
    @Test func aRouteWithNoParametersIsNotTheSameAsNoRoute() async throws {
        try await withClient { client in
            let fields = try #require(try await client.get("/ping").head?.headerFields)
            #expect(fields[.init("x-route-params")!] == "(empty)", "matched, and takes nothing")
            #expect(fields[.init("x-route-scope")!] == "(none)", "the global tier, above the router")
        }
    }

    /// The global tier folds around the router's `handle`, so no match has happened when its box is built —
    /// on a matched route, on a gated one, and on the synthesised 404 alike. A global middleware reading a
    /// template would be reading one that cannot exist yet.
    @Test func theGlobalTierNeverSeesARoute() async throws {
        try await withClient { client in
            for path in ["/ping", "/ping/echo/world", "/gated", "/no/such/route"] {
                let fields = try #require(try await client.get(path).head?.headerFields)
                #expect(fields[.init("x-route-scope")!] == "(none)", "\(path)")
            }
        }
    }
}
