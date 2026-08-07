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
}
