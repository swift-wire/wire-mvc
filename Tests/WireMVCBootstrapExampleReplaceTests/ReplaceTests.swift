import Testing
import WireMVCTesting
// The retroactive `NIOHTTPServer: WireMVCTestServer` conformance. This suite runs `.inProcess` and never
// binds a port, but the generated `.wiremvc(_:)` factory emits both mode branches, so the live one's
// `serveForSuite` bound still has to be satisfiable for the factory to type-check.
import WireMVCTestingNIOHTTPServer

@testable import WireMVCBootstrapExample

// Proof that `@Replaces` swaps a re-composed app binding for a test double. This target re-composes the
// app's graph via its own `WireMVCBuildPlugin` (the app carries `_WireExports.swift`), and its
// `@Replaces FakeGreeter` supersedes the app's `RealGreeter`. `@Replaces` carries no `TestingKey`, so the
// keyless `.wiremvc(_:)` serving the replaced graph is exactly right here.
//
// It is also the in-process gate. `@Replaces` is a graph-level mechanism — the transport observes nothing
// about it — so this suite runs on `.inProcess`: same build (the app's real router, global middleware, error
// tiers and `@NotFound` fallback), same assertions, but the handler is called directly instead of over a
// socket. Two things follow, and are the point of the mode: the target needs no
// `WireMVCTestingNIOHTTPServer` (nothing reads a bound port), and it needs no `@Replaces ServerConfig(port: 0)`
// (nothing binds one), so it can't collide with the sibling live suite on a port.

@Suite(.wiremvc(.inProcess))
struct ReplaceTests {
    /// `GET /hello/{name}` routes through the graph-constructed `HelloController`, whose injected `Greeter`
    /// resolves to the target's `@Replaces` `FakeGreeter` — so the body is `FAKE:Alice`, not the real
    /// `Hello, Alice!`. This is the whole point: the app's real binding was superseded by the test double.
    @Test func serveHelloUsesReplacedFakeGreeter() async throws {
        let response = try await TestClient.current.get("/hello/Alice")
        #expect(response.status == 200)
        let greeting = try response.json(Greeting.self)
        #expect(greeting.message == "FAKE:Alice")
        #expect(greeting.message != "Hello, Alice!")
    }

    /// Mode parity, 1/3 — the global `@ErrorResponse(TenantMissing.self, .badRequest)` tier. `GET
    /// /hello/tenant` throws, and the tier maps it to a 400 in-process exactly as it does live: the tier is
    /// folded into the route by the same build, so the transport never sees it.
    @Test func globalErrorTierMapsToBadRequest() async throws {
        let response = try await TestClient.current.get("/hello/tenant")
        #expect(response.status == 400)
    }

    /// Mode parity, 2/3 — the `@NotFound` `@RawRoute` fallback. An unmatched path reaches the Bootstrap's own
    /// handler, which writes its 404 through the response sender directly (the raw path, not a typed
    /// response) — so this also covers ``InProcessResponseSender`` serving a route that owns its own writes.
    @Test func notFoundFallbackServes() async throws {
        let response = try await TestClient.current.get("/no/such/route")
        #expect(response.status == 404)
        #expect(response.bodyText.contains("no route here"))
    }

    /// Mode parity, 3/3 — the `@Middleware`-guarded introspection mount. `/wiring` is registered before
    /// `finalize()` with its guard chain folded around it, so it is a real route in-process too and answers
    /// the graph's wiring model as JSON.
    @Test func guardedIntrospectionRouteServes() async throws {
        let response = try await TestClient.current.get("/wiring")
        #expect(response.status == 200)
        #expect(response.bodyText.contains("HelloController"))
    }
}
