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
            if let declaration = statement.item.asProtocol(DeclGroupSyntax.self) as? (any DeclSyntaxProtocol),
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
            factoryKeys: []
        ).witness
    }

    private func diagnostics(_ source: String) -> [String] {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: "/pages",
            subjectAccessor: "_wireSubject",
            factoryKeys: []
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
        // Content-type is seeded through the ordinary header machinery.
        #expect(emitted.contains(#".setIfAbsent(.contentType, "text/html; charset=utf-8")"#))
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

    @Test("a route @ResponseHeader still beats the seeded content type")
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
        // Seeded first as setIfAbsent, the route's own .set applied after — order is the tier rule.
        let seeded = emitted.range(of: #".setIfAbsent(.contentType, "text/html; charset=utf-8")"#)
        let route = emitted.range(of: #".set(.contentType, "application/xhtml+xml")"#)
        #expect(seeded != nil && route != nil)
        if let seeded, let route { #expect(seeded.lowerBound < route.lowerBound) }
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
        #expect(emitted.contains("let wireMVCOutcome: WireMVCOutcome"))
        #expect(emitted.contains("try await wireMVCOutcome.send(on: responseSender)"))
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
}
