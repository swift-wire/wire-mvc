import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// Proof that `@Replaces` swaps a re-composed app binding for a test double. This target re-composes the
// app's graph via its own `WireMVCBuildPlugin` (the app carries `_WireExports.swift`), and its
// `@Replaces FakeGreeter` supersedes the app's `RealGreeter`. `@Replaces` carries no `TestingKey`, so the
// keyless `.wiremvc(_:)` serving the replaced graph is exactly right here.
//
// It is also the in-process gate. `@Replaces` is a graph-level mechanism — the transport observes nothing
// about it — so this suite runs on `.inProcess`: same build (the app's real router, global middleware, error
// tiers and `@NotFound` fallback), same assertions, but the handler is called directly instead of over a
// socket. The payoff is visible in this target's manifest: it names no concrete server at all. The generated
// factory is generic over whatever server the mode carries, so a socket-free suite depends on no server
// package — unlike its two live siblings.

@Suite(.wiremvc(.inProcess))
struct ReplaceTests {
    /// `GET /hello/{name}` routes through the graph-constructed `HelloController`, whose injected `Greeter`
    /// resolves to the target's `@Replaces` `FakeGreeter` — so the body is `FAKE:Alice`, not the real
    /// `Hello, Alice!`. This is the whole point: the app's real binding was superseded by the test double.
    @Test func serveHelloUsesReplacedFakeGreeter() async throws {
        // Through the generated typed client: `hello(name:)` is `GET /hello/{name}`, and its return is the
        // route's own `@JSONResponse` type. No path string, no status assertion, no decode — and renaming
        // the route or changing `Greeting` breaks this at compile time rather than at runtime.
        let greeting = try await helloController.hello(name: "Alice")
        #expect(greeting.message == "FAKE:Alice")
        #expect(greeting.message != "Hello, Alice!")
    }

    /// Mode parity, 1/3 — the global `@ErrorResponse(TenantMissing.self, .badRequest)` tier. `GET
    /// /hello/tenant` throws, and the tier maps it to a 400 in-process exactly as it does live: the tier is
    /// folded into the route by the same build, so the transport never sees it.
    @Test func globalErrorTierMapsToBadRequest() async throws {
        // A typed method returns the decoded response, so a non-2xx arrives as a throw carrying the status.
        let error = try await #require(throws: WireMVCRouteError.self) {
            try await helloController.tenant()
        }
        #expect(error.status == .badRequest)
    }

    /// Mode parity, 2/3 — the `@NotFound` `@RawRoute` fallback. No typed method exists for it: an unmatched
    /// path is not addressable by route, so this stays on the untyped client, which is exactly what that
    /// surface is for. An unmatched path reaches the Bootstrap's own
    /// handler, which writes its 404 through the response sender directly (the raw path, not a typed
    /// response) — so this also covers ``InProcessResponseSender`` serving a route that owns its own writes.
    @Test func notFoundFallbackServes() async throws {
        let response = try await TestClient.current.get("/no/such/route")
        #expect(response.status == 404)
        #expect(response.bodyText.contains("no route here"))
    }

    /// Mode parity, 3/3 — the `@Middleware`-guarded introspection mount. Also untyped: `/wiring` is mounted
    /// by the Bootstrap, not declared on a `@Controller`, so no client covers it. `/wiring` is registered before
    /// `finalize()` with its guard chain folded around it, so it is a real route in-process too and answers
    /// the graph's wiring model as JSON.
    @Test func guardedIntrospectionRouteServes() async throws {
        let response = try await TestClient.current.get("/wiring")
        #expect(response.status == 200)
        #expect(response.bodyText.contains("HelloController"))
    }
}
