import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// `@HTMLResponse` over real HTTP, on the harness-owned `NIOHTTPServer`. This is the only place the
// *generated* streaming terminal actually runs — everywhere else it is compile-tested. What is being proved
// here is not that Elementary renders (its own suite covers that) but that the codegen's terminal, the
// header machinery and the proposal's response body writer compose into a well-formed response on the wire.

@Suite(.wiremvc(.swiftHttpServer))
struct HTMLResponseOverTheWireTests {

    /// The plain shape: a streamed `200` whose content type the codegen seeded.
    @Test func servesAStreamedPage() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/home")
            #expect(response.status == 200)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.contentType] == "text/html; charset=utf-8")

            let html = response.bodyText
            #expect(html.hasPrefix("<!DOCTYPE html><html><head>"))
            #expect(html.contains("<title>Home</title>"))
            #expect(html.contains(#"<li class="todo">first</li>"#))
            #expect(html.hasSuffix("</body></html>"))
        }
    }

    /// **The observable difference.** A response assembled in memory knows its size, so the head carries
    /// `Content-Length`. One written incrementally does not: the head goes out before the body exists. On a
    /// ~28 KB page that absence is the signal, and it is what regresses if the terminal ever goes back to
    /// buffering.
    ///
    /// It is a weaker signal than it first appears, and worth being precise about: this stack reports
    /// `Transfer-Encoding: Identity` rather than `chunked`, so framing is not the tell here. What a
    /// collecting client can observe is only that the length was unknown up front. The byte-exact proof —
    /// that the peer receives *many separate writes*, and receives the head while the body is still
    /// rendering — needs a writer that records each write, and lives in `StreamingTierPrototypeTests`.
    /// This test's job is to prove the generated terminal produces a well-formed response over real HTTP.
    @Test func aLargePageIsNotLengthPrefixed() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/list/400")
            #expect(response.status == 200)
            let fields = try #require(response.head?.headerFields)

            #expect(fields[.contentLength] == nil, "a streamed body cannot know its length up front")

            // …and streaming did not corrupt it: the whole page arrived, in order.
            let html = response.bodyText
            #expect(html.count > 20_000, "the large page really is large")
            #expect(html.contains("task number 0 —"))
            #expect(html.contains("task number 399 —"))
            #expect(html.hasSuffix("</ul></body></html>"))
        }
    }

    /// A small page still streams; it simply completes in one write. The point is that nothing special
    /// happens at the boundary — the same terminal serves both.
    @Test func aSmallPageIsAlsoStreamed() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/home")
            #expect(response.status == 200)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.contentLength] == nil)
        }
    }

    /// An annotated non-200 status, and a route constant that coexists with the seeded content type
    /// (`.setIfAbsent` seeds, the route's `.set` for a *different* field simply adds).
    @Test func annotatedStatusAndRouteConstants() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/gone")
            #expect(response.status == 404)
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.contentType] == "text/html; charset=utf-8")
            #expect(fields[.cacheControl] == "no-store")
            #expect(response.bodyText.contains("<title>Gone</title>"))
        }
    }

    /// A binding failure is a *pre-head* failure, so it still maps — the streaming tier does not weaken
    /// error handling before the first byte. `{count}` is an `Int`; "abc" cannot decode.
    @Test func aBindingFailureStillMaps() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/list/abc")
            #expect(response.status == 400, "the decode failed before the head went out")
            #expect(!response.bodyText.contains("<!DOCTYPE html>"), "no page was streamed")
        }
    }

    /// A handler throw likewise maps, through the route's `@ErrorResponse` — identical to what a
    /// `@JSONResponse` route would do, because the throw happens inside the terminal's `building` closure.
    /// The same route streams a page for a smaller count, which is the point: the mapping covers the
    /// failing path of an ordinary route, not a route that exists only to fail.
    @Test func aHandlerThrowMapsThroughErrorResponse() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/list/999")
            #expect(response.status == 400)
            #expect(!response.bodyText.contains("<!DOCTYPE html>"))
        }
    }

    /// The global middleware tier reaches an HTML route like any other: `AccessLog` contributes
    /// `x-served-by` on the way in, and it is resolved into the head *before* the body streams.
    @Test func globalMiddlewareContributesToAStreamedHead() async throws {
        try await withClient { client in
            let response = try await client.get("/pages/home")
            let fields = try #require(response.head?.headerFields)
            #expect(fields[.init("x-served-by")!] == "wire-mvc")
        }
    }
}

/// The generated typed client for HTML routes. It shipped missing — `@HTMLResponse` was a fourth response
/// mode added to a three-way test in `ControllerClientGeneration`, so every HTML route fell through to
/// `return nil` and vanished from its controller's client with no diagnostic.
@Suite(.wiremvc(.swiftHttpServer))
struct HTMLResponseTypedClientTests {

    @Test func theClientHandsBackTheRenderedMarkup() async throws {
        try await withClient(for: PagesControllerClient.self) { pages in
            let html = try await pages.home()
            #expect(html.hasPrefix("<!DOCTYPE html><html><head>"))
            #expect(html.contains("<title>Home</title>"))
            #expect(html.contains(#"<li class="todo">first</li>"#))
        }
    }

    /// Bindings still become method parameters, and the path template is filled in for you.
    @Test func bindingsBecomeParameters() async throws {
        try await withClient(for: PagesControllerClient.self) { pages in
            let html = try await pages.list(count: 3)
            #expect(html.contains("task number 0 —"))
            #expect(html.contains("task number 2 —"))
            #expect(!html.contains("task number 3 —"))
        }
    }

    /// The non-2xx rule is the same one every typed method applies — an HTML route is not special here.
    @Test func aNonSuccessStatusThrows() async throws {
        try await withClient(for: PagesControllerClient.self) { pages in
            let error = try await #require(throws: WireMVCRouteError.self) { try await pages.list(count: 999) }
            #expect(error.status == .badRequest)
        }
    }
}

/// Header precedence in the generated client, pinned behaviourally rather than by generated text.
///
/// `headerArgument` resolves a collision with `{ _, declared in declared }` — the route's own `@Header`
/// binding wins over the caller's loose `headers:` bag. That is one closure away from the opposite, both
/// spellings compile, and no golden test can tell them apart once the emitter is rewritten to build the
/// request through `RequestSendable.send`. This test can.
@Suite(.wiremvc(.swiftHttpServer))
struct DeclaredHeaderPrecedenceTests {

    @Test func aDeclaredHeaderBeatsTheCallersBag() async throws {
        try await withClient(for: PagesControllerClient.self) { pages in
            let html = try await pages.tenant(tenant: "declared", headers: ["x-tenant": "caller"])
            #expect(html.contains("<title>declared</title>"), "the typed parameter is the specific statement")
            #expect(!html.contains("caller"))
        }
    }

    /// …and the bag still carries what the route does not declare.
    @Test func theBagStillCarriesUndeclaredHeaders() async throws {
        try await withClient(for: PagesControllerClient.self) { pages in
            let html = try await pages.tenant(tenant: "acme", headers: ["x-trace": "abc123"])
            #expect(html.contains("<title>acme</title>"))
        }
    }
}
