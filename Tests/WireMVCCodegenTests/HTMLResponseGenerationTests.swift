// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// `@HTMLResponse` — the streaming route kind. These pin the emitted terminal shape, the content-type
/// seeding, and the diagnostics. The runtime half is pinned separately by `Fixtures/StreamingTierPrototype`.
@Suite("@HTMLResponse generation")
struct HTMLResponseGenerationTests {

    private func controller(_ source: String) -> ControllerDeclaration {
        let file = Parser.parse(source: source)
        for statement in file.statements {
            if let declaration: any DeclSyntaxProtocol = statement.item.asProtocol(DeclGroupSyntax.self),
                let controller = ControllerDeclaration(declaration)
            {
                return controller
            }
        }
        fatalError("fixture has no controller")
    }

    private func witness(_ source: String) -> String {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: "/pages",
            subjectAccessor: "_wireSubject",
            factoryKeys: [],
            discoveredBindings: WireMVCBuiltIns.bindings,
            discoveredModes: WireMVCBuiltIns.modes
        ).witness
    }

    private func diagnostics(_ source: String) -> [String] {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: "/pages",
            subjectAccessor: "_wireSubject",
            factoryKeys: [],
            discoveredBindings: WireMVCBuiltIns.bindings,
            discoveredModes: WireMVCBuiltIns.modes
        ).diagnostics.map(\.message.message)
    }

    // MARK: - The emitted terminal

    @Test("a plain HTML route streams through wireMVCStreamingTerminal")
    func plainRoute() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/home")
                @HTMLResponse
                func home() async throws -> some HTML { HomePage() }
            }
            """
        )

        // The streaming terminal, not the buffered one.
        #expect(emitted.contains("try await wireMVCStreamingTerminal("))
        #expect(emitted.contains("responseSender: responseSender"))
        #expect(!emitted.contains("let wireMVCOutcome: WireMVCOutcome"))
        // The producer is named but never typed — it is inferred from `building`.
        #expect(emitted.contains("producer: WireMVCHTMLProducer(try await self._wireSubject.home())"))
        #expect(emitted.contains("WireMVCStreamingOutcome("))
        #expect(emitted.contains("status: .ok"))
        // The codegen names no content type: the producer supplies its own at send time. Behaviour is
        // pinned over the wire by `HTMLResponseOverTheWireTests.servesAStreamedPage`.
        #expect(!emitted.contains("text/html"))
        // The same error chain a buffered route gets, as the mapping closure.
        #expect(emitted.contains("errorMapping: { wireMVCError in"))
        #expect(emitted.contains("WireMVCOutcome.status(.internalServerError)"))
    }

    @Test("an annotated status is carried through")
    func annotatedStatus() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/gone")
                @HTMLResponse(status: .notFound)
                func gone() async throws -> some HTML { NotFoundPage() }
            }
            """
        )
        #expect(emitted.contains("status: .notFound"))
    }

    @Test("bindings and the body collection sit inside the building closure")
    func bindingsInsideBuilding() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/{id}")
                @HTMLResponse
                func page(@Path id: String, @Query q: String?) async throws -> some HTML { Page(id, q) }
            }
            """
        )
        let building = emitted.range(of: "building: {")
        let mapping = emitted.range(of: "errorMapping: {")
        #expect(building != nil && mapping != nil)
        // Binding decode is *before* the error mapping closure, i.e. inside `building` — so a decode
        // failure still maps through @ErrorResponse rather than escaping past the head.
        if let building, let mapping, let id = emitted.range(of: "let id = try") {
            #expect(id.lowerBound > building.upperBound)
            #expect(id.upperBound < mapping.lowerBound)
        }
        #expect(emitted.contains("WireMVCBindingError"))
    }

    @Test("a response tuple projects status and body")
    func responseTuple() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/home")
                @HTMLResponse
                func home() async throws -> (status: HTTPResponse.Status, body: some HTML) { (.ok, HomePage()) }
            }
            """
        )
        #expect(emitted.contains("let wireMVCReturn = try await self._wireSubject.home()"))
        #expect(emitted.contains("status: wireMVCReturn.status"))
        #expect(emitted.contains("producer: WireMVCHTMLProducer(wireMVCReturn.body)"))
    }

    /// A route naming its own content type still emits it as an ordinary static contribution — and, because
    /// the producer only seeds when the field is absent, it still wins at send time. That precedence is a
    /// runtime property now rather than an ordering of emitted literals, so the wire suite is where it is
    /// asserted; this pins only that the route's own header survives the change.
    @Test("a route's own content type is still emitted")
    func contentTypeOverride() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/feed")
                @HTMLResponse
                @ResponseHeader(.contentType, "application/xhtml+xml")
                func feed() async throws -> some HTML { Feed() }
            }
            """
        )
        #expect(emitted.contains(#".set(.contentType, "application/xhtml+xml")"#))
        #expect(!emitted.contains("text/html"), "the codegen no longer names a default")
    }

    // MARK: - Streaming + a request body

    /// The combination that shipped broken. `collectBody` **consumes** the reader and a closure only
    /// borrows it, so emitting the collection inside `building` produces
    /// `'reader' is borrowed and cannot be consumed`. Nothing exercised a streaming route with a body
    /// binding, so the codegen emitted uncompilable code and every test still passed — only a fixture route
    /// through the real plugin caught it.
    @Test("a streaming route with a body binding collects through the terminal, not in the closure")
    func bodyBindingUsesTheCollectingOverload() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Post("/preview")
                @HTMLResponse
                func preview(@JSONBody input: Draft) async throws -> some HTML { Preview(input) }
            }
            """
        )
        #expect(emitted.contains("collectingBodyFrom: reader"))
        #expect(emitted.contains("building: { requestBody in"))
        // The read must not be inside the closure — that is the shape that does not compile.
        if let building = emitted.range(of: "building: {"),
            let collect = emitted.range(of: "WireMVCRequest.collectBody(")
        {
            #expect(collect.lowerBound < building.lowerBound, "the collection is not emitted inside building")
        } else {
            // No inline `collectBody` at all is the expected shape: the terminal overload does it.
            #expect(!emitted.contains("WireMVCRequest.collectBody("))
        }
    }

    /// …and the binding decode still sits *inside* `building`, so a malformed body maps through
    /// `@ErrorResponse` rather than escaping. Hoisting the read would have compiled and lost that.
    @Test("the body binding decode stays inside the mapped region")
    func decodeStaysMapped() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Post("/preview")
                @HTMLResponse
                func preview(@JSONBody input: Draft) async throws -> some HTML { Preview(input) }
            }
            """
        )
        guard let building = emitted.range(of: "building: { requestBody in"),
            let mapping = emitted.range(of: "errorMapping: {"),
            let decode = emitted.range(of: "JSONBody<Draft>.bind")
        else {
            Issue.record("expected shape not emitted")
            return
        }
        #expect(decode.lowerBound > building.upperBound)
        #expect(decode.upperBound < mapping.lowerBound)
    }

    @Test("a streaming route with no body binding takes the plain overload")
    func noBodyNoCollectingOverload() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/home")
                @HTMLResponse
                func home() async throws -> some HTML { HomePage() }
            }
            """
        )
        #expect(!emitted.contains("collectingBodyFrom:"))
        #expect(!emitted.contains("requestBody in"))
        #expect(emitted.contains("building: {"))
    }

    // MARK: - The buffered path is untouched

    @Test("a JSON route still emits the buffered terminal")
    func jsonUnchanged() {
        let emitted = witness(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/data")
                @JSONResponse
                func data() async throws -> Payload { Payload() }
            }
            """
        )
        #expect(emitted.contains("try await wireMVCBufferedTerminal("))
        #expect(!emitted.contains("wireMVCStreamingTerminal"))
        #expect(!emitted.contains("text/html"))
    }

    // MARK: - Diagnostics

    @Test("@HTMLResponse on a Void handler is diagnosed")
    func htmlOnVoid() {
        let messages = diagnostics(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/ping")
                @HTMLResponse
                func ping() async throws {}
            }
            """
        )
        #expect(messages.contains { $0.contains("@HTMLResponse on 'ping' requires a returned value") })
    }

    @Test("two response annotations on one route are diagnosed")
    func duplicateAnnotations() {
        let messages = diagnostics(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/home")
                @HTMLResponse
                @JSONResponse
                func home() async throws -> some HTML { HomePage() }
            }
            """
        )
        #expect(messages.contains { $0.contains("more than one response annotation") })
    }

    @Test("a returned status makes an annotated one dead, and is diagnosed")
    func deadStatusArgument() {
        let messages = diagnostics(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/home")
                @HTMLResponse(status: .ok)
                func home() async throws -> (status: HTTPResponse.Status, body: some HTML) { (.ok, HomePage()) }
            }
            """
        )
        #expect(messages.contains { $0.contains("the status on @HTMLResponse(status:)") })
    }
    // MARK: - Request bodies on a streaming response

    /// Bindings declared outside WireMVC, one per streamed kind. WireMVC declares neither itself — the
    /// real ones live in the fixtures and examples — so a test that wants them has to supply them, exactly
    /// as the plugin would after scanning a consumer's sources.
    private var streamedBindings: [String: DeclaredRequestBinding] {
        var bindings = WireMVCBuiltIns.bindings
        bindings["DigestBody"] = DeclaredRequestBinding(obligations: .readerBody)
        bindings["PartsStream"] = DeclaredRequestBinding(obligations: .bodyStream, streamType: "MultipartParts")
        return bindings
    }

    private func witness(_ source: String, bindings: [String: DeclaredRequestBinding]) -> String {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: "/pages",
            subjectAccessor: "_wireSubject",
            factoryKeys: [],
            discoveredBindings: bindings,
            discoveredModes: WireMVCBuiltIns.modes
        ).witness
    }

    private func diagnostics(_ source: String, bindings: [String: DeclaredRequestBinding]) -> [String] {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: "/pages",
            subjectAccessor: "_wireSubject",
            factoryKeys: [],
            discoveredBindings: bindings,
            discoveredModes: WireMVCBuiltIns.modes
        ).diagnostics.map(\.message.message)
    }

    /// A binding that **reduces** the body without holding it composes with a streaming response, through
    /// the lending overload: the reader arrives as a parameter of `building` rather than being consumed
    /// before it.
    ///
    /// The point of `lendingBodyFrom:` is *where* the bind ends up. Inside `building` it is inside the
    /// mapped `do`, so a malformed body still maps through `@ErrorResponse`; hoisting it would compile and
    /// lose that.
    @Test func readerBodyCombinesWithStreamingResponse() {
        let source = """
            @Controller("/pages")
            struct Pages {
                @Post("/report")
                @HTMLResponse
                func report(@DigestBody digest: Digest) async throws -> some HTML {
                    Text(digest.hex)
                }
            }
            """
        let rendered = witness(source, bindings: streamedBindings)
        #expect(rendered.contains("lendingBodyFrom: reader,"))
        #expect(rendered.contains("building: { reader in"))
        // The collecting overload must not also be selected — the reader can only be consumed once.
        #expect(!rendered.contains("collectingBodyFrom:"))
        // The bind resolves to the lent reader by shadowing, so it is rendered exactly as it always was.
        #expect(rendered.contains("reader: reader"))
        #expect(diagnostics(source, bindings: streamedBindings).isEmpty)
    }

    /// A binding that **lends** the stream to the handler does not, and says why.
    ///
    /// This combination had no test at all before the split — the old single diagnostic covered both kinds
    /// and was covered by neither.
    @Test func bodyStreamOnStreamingResponseIsDiagnosed() {
        let source = """
            @Controller("/pages")
            struct Pages {
                @Post("/live")
                @HTMLResponse
                func live<Stream: MultipartPartStream & ~Copyable>(
                    @PartsStream stream: consuming Stream
                ) async throws -> some HTML {
                    Text("x")
                }
            }
            """
        let messages = diagnostics(source, bindings: streamedBindings)
        #expect(messages.count == 1)
        let message = try! #require(messages.first)
        #expect(message.contains("lends its request body stream"))
        // It names the working alternative rather than only refusing.
        #expect(message.contains("@RawRoute"))
        #expect(message.contains(".readerBody"))
    }
}

/// The typed client for `@HTMLResponse` routes.
///
/// These exist because the first cut of `@HTMLResponse` shipped without them: a fourth response mode added
/// to a three-way test fell through to `return nil`, and every HTML route vanished from its controller's
/// client with no diagnostic. The last test here is the structural one — it fails for *any* future response
/// mode that forgets the client, which is the check that was missing rather than this one case.
@Suite("@HTMLResponse typed client")
struct HTMLResponseClientTests {

    private func client(_ source: String) -> String {
        let file = Parser.parse(source: source)
        for statement in file.statements {
            if let declaration: any DeclSyntaxProtocol = statement.item.asProtocol(DeclGroupSyntax.self),
                let controller = ControllerDeclaration(declaration)
            {
                return renderControllerClient(
                    controller: controller,
                    pathPrefix: "/pages",
                    discoveredBindings: WireMVCBuiltIns.bindings,
                    discoveredModes: WireMVCBuiltIns.modes
                ).source ?? ""
            }
        }
        fatalError("fixture has no controller")
    }

    @Test("an HTML route gets a client method returning the rendered markup")
    func htmlRouteReturnsMarkup() {
        let emitted = client(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/home")
                @HTMLResponse
                func home() async throws -> some HTML { HomePage() }
            }
            """
        )
        #expect(emitted.contains("func home("))
        #expect(emitted.contains("-> String"), "markup, not a decoded value")
        #expect(emitted.contains("return wireMVCResponse.bodyText"))
        #expect(!emitted.contains("wireMVCResponse.json"), "there is no type to decode into")
    }

    @Test("its bindings still become method parameters")
    func htmlRouteKeepsItsBindings() {
        let emitted = client(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/{id}")
                @HTMLResponse
                func page(@Path id: String, @Query q: String?) async throws -> some HTML { Page(id, q) }
            }
            """
        )
        #expect(emitted.contains("id: String"))
        #expect(emitted.contains("q: String?"))
    }

    /// **The check that was missing.** Every route carrying a verb and a response annotation must appear in
    /// the client; a mode that forgets to admit itself fails here rather than shipping.
    @Test("every annotated route appears in its controller's client")
    func noRouteIsSilentlyDropped() {
        let emitted = client(
            """
            @Controller("/pages")
            struct PagesController {
                @Get("/home") @HTMLResponse
                func home() async throws -> some HTML { HomePage() }
                @Get("/data") @JSONResponse
                func data() async throws -> Payload { Payload() }
                @Delete("/{id}") @ResponseStatus(.noContent)
                func remove(@Path id: String) async throws {}
                @Get("/moved")
                func moved() -> (status: HTTPResponse.Status, headers: HTTPFields) { (.found, [:]) }
            }
            """
        )
        for route in ["home", "data", "remove", "moved"] {
            #expect(emitted.contains("func \(route)("), "route '\(route)' is missing from the client")
        }
    }

}
