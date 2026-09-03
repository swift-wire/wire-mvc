import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// The attribute-reading path for user-defined request bindings.
///
/// This is the prototype the design note asks for before anything is built on it
/// (`Documentation/Notes/ExtensibleBindingsAndResponses.md`). The claim under test is narrow and specific:
/// **the codegen can learn a binding's obligations from its declaration, in a different file and a different
/// module from the use site.** Everything else in that design rests on it, and it had been asserted twice
/// and checked never.
@Suite("Request-binding obligations")
struct BindingObligationsTests {

    private func scan(_ sources: String...) -> [String: DeclaredRequestBinding] {
        scanRequestBindings(in: sources.map { Parser.parse(source: $0) })
    }

    // MARK: - The claim

    @Test("a binding's obligations are read from its declaration in another file")
    func acrossFiles() {
        // Two files, as the plugin passes them: the dependency declaring the binding, and the consumer
        // using it. Nothing links them but the name.
        let found = scan(
            """
            @RequestBinding(.body)
            public struct FormBody<Value: Decodable & Sendable>: RequestBound {}
            """,
            """
            @Controller("/session")
            struct SessionController {
                @Post @HTMLResponse
                func create(@FormBody input: Login) async throws -> some HTML { Page() }
            }
            """
        )
        #expect(found["FormBody"]?.obligations == .body)
    }

    /// WireMVC's own bindings are found by this scan, not by a table.
    ///
    /// The invariant that replaced the hardcoded floor: `@Path`, `@Query`, `@Header` and `@JSONBody` state
    /// their obligations on their own declarations, and a real build reads them because WireMVC is a
    /// Wire-aware dependency of every consumer. If the attributes were ever dropped, every route binding in
    /// every consumer would stop being recognised — so this asserts the source of truth is annotated, which
    /// is the whole of what the floor used to guarantee, without restating it.
    @Test("WireMVC's own bindings declare their obligations")
    func theBuiltInsAreAnnotated() {
        #expect(WireMVCBuiltIns.bindings["Path"]?.obligations == .path)
        #expect(WireMVCBuiltIns.bindings["JSONBody"]?.obligations == .body)
        #expect(WireMVCBuiltIns.bindings["Query"]?.obligations == [])
        #expect(WireMVCBuiltIns.bindings["Header"]?.obligations == [])
        #expect(WireMVCBuiltIns.bindings.count == 4, "\(WireMVCBuiltIns.bindings.keys.sorted())")
    }

    /// The same for the response side, so both live next to the tests that depend on them.
    @Test("WireMVC's own response modes declare their pair")
    func theBuiltInModesAreAnnotated() {
        #expect(
            WireMVCBuiltIns.modes["JSONResponse"]
                == DeclaredResponseMode(terminal: .buffered, codec: "WireMVCJSONCodec")
        )
        #expect(
            WireMVCBuiltIns.modes["HTMLResponse"]
                == DeclaredResponseMode(terminal: .streaming, codec: "WireMVCHTMLProducer", clientBody: .text)
        )
        #expect(WireMVCBuiltIns.modes["ResponseStatus"] == DeclaredResponseMode(terminal: .bodiless, codec: nil))
        #expect(WireMVCBuiltIns.modes.count == 3, "\(WireMVCBuiltIns.modes.keys.sorted())")
    }

    @Test("the obligations are read, not guessed")
    func readsEachObligation() {
        let found = scan(
            """
            @RequestBinding(.body)
            public struct FormBody<V>: RequestBound {}
            @RequestBinding(.path)
            public struct Slug<V>: RequestBound {}
            @RequestBinding(.body, .path)
            public struct Odd<V>: RequestBound {}
            @RequestBinding
            public struct Plain<V>: RequestBound {}
            """
        )
        #expect(found["FormBody"]?.obligations == .body)
        #expect(found["Slug"]?.obligations == .path)
        #expect(found["Odd"]?.obligations == [.body, .path])
        #expect(found["Plain"]?.obligations == [], "a bare marker states no obligation — recognition needs no flag")
    }

    /// Recognition is "the declaration exists", so an unannotated type is not a binding and the use site
    /// keeps today's clear diagnostic rather than degrading into a type error further from the cause.
    @Test("a type without the attribute is not a binding")
    func unannotatedIsNotABinding() {
        let found = scan("public struct NotABinding<V>: RequestBound {}")
        #expect(found["NotABinding"] == nil)
    }

    // MARK: - Shapes the scan must survive

    @Test("the built-ins can be declared the same way")
    func builtInsNeedNoSpecialCase() {
        // `@Path` stops being privileged: its placeholder validation is just the `.path` obligation.
        let found = scan(
            """
            @RequestBinding(.path) public struct Path<Value>: RequestBound {}
            @RequestBinding public struct Query<Value>: RequestBound {}
            @RequestBinding public struct Header<Value>: RequestBound {}
            @RequestBinding(.body) public struct JSONBody<Value>: RequestBound {}
            """
        )
        #expect(found["Path"]?.obligations == .path)
        #expect(found["Query"]?.obligations == [])
        #expect(found["Header"]?.obligations == [])
        #expect(found["JSONBody"]?.obligations == .body)
    }

    @Test("a binding nested in a namespace is still found")
    func nestedDeclaration() {
        let found = scan(
            """
            public enum Bindings {
                @RequestBinding(.body)
                public struct Yaml<Value>: RequestBound {}
            }
            """
        )
        #expect(found["Yaml"]?.obligations == .body, "the scan walks; it does not depend on where the author put it")
    }

    @Test("classes and actors declare bindings too")
    func nonStructDeclarations() {
        let found = scan(
            """
            @RequestBinding(.body) public final class BoxedBody<V>: RequestBound {}
            @RequestBinding public actor Session<V>: RequestBound {}
            """
        )
        #expect(found["BoxedBody"]?.obligations == .body)
        #expect(found["Session"]?.obligations == [])
    }

    @Test("a fully qualified obligation is read the same as a shorthand one")
    func qualifiedArgument() {
        let found = scan("@RequestBinding(BindingObligations.body) public struct Q<V>: RequestBound {}")
        #expect(found["Q"]?.obligations == .body)
    }

    /// A known limit, pinned so it is a decision rather than a surprise. The attribute must sit on the type
    /// declaration; on an extension it is not seen. That fails *safely* — the binding is simply unrecognised,
    /// so the use site gets today's clear "needs a binding annotation" diagnostic rather than misbehaving.
    /// Worth a targeted diagnostic later if anyone trips over it.
    @Test("the attribute is not read from an extension")
    func attributeOnExtensionIsNotSeen() {
        let found = scan(
            """
            public struct FormBody<V>: RequestBound {}
            @RequestBinding(.body)
            extension FormBody {}
            """
        )
        #expect(found["FormBody"] == nil)
    }

    // MARK: - The decision it enables

    /// The whole point: the two hardcodes this replaces. `routeHasBody` currently tests
    /// `binding.wrapper == "JSONBody"` (`RouteCodegen.swift:638`); with obligations it becomes a lookup, and
    /// a user's `@FormBody` route collects its body without WireMVC knowing the name.
    @Test("a discovered body binding answers what the JSONBody hardcode answers")
    func replacesTheBodyHardcode() {
        let found = scan(
            """
            @RequestBinding(.body) public struct JSONBody<V>: RequestBound {}
            @RequestBinding(.body) public struct FormBody<V>: RequestBound {}
            @RequestBinding public struct Header<V>: RequestBound {}
            """
        )
        func routeReadsBody(_ wrappers: [String]) -> Bool {
            wrappers.contains { found[$0]?.contains(.body) ?? false }
        }
        #expect(routeReadsBody(["Path", "JSONBody"]))
        #expect(routeReadsBody(["FormBody"]), "the case the hardcode cannot answer today")
        #expect(!routeReadsBody(["Path", "Header"]))
    }

    /// And the diagnostic that falls out for free — a request has one body.
    @Test("two body bindings on one route are countable at compile time")
    func twoBodyBindingsAreCountable() {
        let found = scan(
            """
            @RequestBinding(.body) public struct JSONBody<V>: RequestBound {}
            @RequestBinding(.body) public struct FormBody<V>: RequestBound {}
            """
        )
        let bodies = ["JSONBody", "FormBody"].filter { found[$0]?.contains(.body) ?? false }
        #expect(bodies.count == 2, "countable, so diagnosable — nothing says this today")
    }
}

/// The seam, exercised through `generateRouteContributors` — the entry point `WireMVCRouteGen` calls.
///
/// The two hardcodes this replaced were a `Set<String>` of wrapper names (recognition) and `== "JSONBody"`
/// (body collection). Both are answered here by a binding WireMVC has never heard of, declared in a
/// *different file* — which is how the plugin passes a dependency's sources.
@Suite("User-declared bindings, end to end")
struct UserBindingIntegrationTests {

    private func generate(_ sources: String...) -> (source: String, diagnostics: [String]) {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles
                + sources.enumerated().map { (path: "File\($0.offset).swift", source: $0.element) },
            testEntry: false,
            extraImports: [],
            sourceModules: [:],
            consumerModule: nil
        )
        // Errors only. A warning is not a failure — mixing the two makes every "no diagnostics" assertion
        // brittle the moment a new warning is added, which is exactly what happened here.
        return (result.source, result.diagnostics.filter { $0.message.severity == .error }.map(\.message.message))
    }

    private static let formBodyDeclaration = """
        @RequestBinding(.body)
        public struct FormBody<Value: Decodable & Sendable>: RequestBound {}
        """

    @Test("a trailing catch-all is a valid template — the runtime decides whether it can be served")
    func catchAllTemplateIsNotDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Controller("/files")
            public struct FilesController: Sendable {
                @Get("/{path*}")
                @JSONResponse
                public func serve(@Path path: String) async throws -> String { path }
            }
            """
        )
        // Not codegen's call: the native router serves this, and the ServerTransport bridge refuses it at
        // registration, where the runtime is known. A controller in a shared package does not know which
        // it will be.
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
    }

    @Test("a wildcard shape no template expresses is an error at build time")
    func unexpressibleWildcardIsDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Controller("/files")
            public struct FilesController: Sendable {
                @Get("/*")
                @JSONResponse
                public func serve() async throws -> String { "" }
            }
            """
        )
        #expect(diagnostics.count == 1, "got: \(diagnostics)")
        #expect((diagnostics.first ?? "").contains("{name*}"), "names the shape that does work")
    }

    @Test("a catch-all before the end is an error — everything after it is unreachable")
    func misplacedCatchAllIsDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Controller("/files")
            public struct FilesController: Sendable {
                @Get("/{path*}/edit")
                @JSONResponse
                public func serve(@Path path: String) async throws -> String { path }
            }
            """
        )
        #expect(diagnostics.count == 1, "got: \(diagnostics)")
        #expect((diagnostics.first ?? "").contains("must be the last segment"))
    }

    @Test("the wildcard check does not catch an ordinary parameter")
    func ordinaryParameterIsNotDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Controller("/files")
            public struct FilesController: Sendable {
                @Get("/{path}")
                @JSONResponse
                public func serve(@Path path: String) async throws -> String { path }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
    }

    @Test("a user binding is recognised, so its parameter is not diagnosed")
    func recognised() {
        let (source, diagnostics) = generate(
            Self.formBodyDeclaration,
            """
            @Controller("/session")
            public struct SessionController {
                @Post
                @JSONResponse
                public func create(@FormBody input: Login) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
        // Emission was already generic — the binding is called exactly like a built-in.
        #expect(source.contains("FormBody<Login>.bind("))
    }

    @Test("a user body binding makes the terminal collect the request body")
    func collectsTheBody() {
        let (source, _) = generate(
            Self.formBodyDeclaration,
            """
            @Controller("/session")
            public struct SessionController {
                @Post
                @JSONResponse
                public func create(@FormBody input: Login) async throws -> Token { Token() }
            }
            """
        )
        // The terminal collects — `collectBody` consumes the reader, which the `building` closure could
        // only borrow — so the obligation shows up as the overload the route calls.
        #expect(source.contains("collectingBodyFrom: reader"), "the == \"JSONBody\" hardcode's job")
        #expect(source.contains("body: requestBody"))
    }

    @Test("a user binding with no body obligation collects nothing")
    func noObligationNoCollection() {
        let (source, diagnostics) = generate(
            """
            @RequestBinding
            public struct Locale<Value: Sendable>: RequestBound {}
            """,
            """
            @Controller("/pages")
            public struct PagesController {
                @Get
                @JSONResponse
                public func page(@Locale locale: String) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
        #expect(source.contains("Locale<String>.bind("))
        #expect(!source.contains("collectBody"), "no obligation, no read")
    }

    /// The exact combination the `/pages/echo` fixture serves: a body binding WireMVC has never heard of, on
    /// a **streaming** route. Both halves were separately broken at some point — the binding unrecognised,
    /// and the collection emitted where the reader cannot be consumed — so the pair is worth pinning here as
    /// well as in the fixture, which only a plugin-run build exercises.
    @Test("a user body binding on a streaming route uses the collecting terminal")
    func userBodyBindingOnAStreamingRoute() {
        let (source, diagnostics) = generate(
            Self.formBodyDeclaration,
            """
            @Controller("/session")
            public struct SessionController {
                @Post("/echo")
                @HTMLResponse
                public func echo(@FormBody input: Login) async throws -> some HTML { Page(input) }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
        #expect(source.contains("collectingBodyFrom: reader"))
        #expect(source.contains("building: { requestBody in"))
        #expect(source.contains("FormBody<Login>.bind("))
        #expect(source.contains("body: requestBody"))
    }

    // MARK: - The `.path` obligation

    /// The placeholder check generalised. `@Path` was checked by *name* against the route's `{name}`
    /// placeholders (`RouteCodegen.swift:526`); the obligation is what that check was really asking about,
    /// so a binding declared outside WireMVC now gets it too.
    @Test("a user path binding without a matching placeholder is diagnosed")
    func userPathBindingMissingPlaceholder() {
        let (_, diagnostics) = generate(
            """
            @RequestBinding(.path)
            public struct Slug<Value: Sendable>: RequestBound {}
            """,
            """
            @Controller("/pages")
            public struct PagesController {
                @Get("/{id}")
                @JSONResponse
                public func page(@Slug name: String) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("no matching '{name}' placeholder") }, "got: \(diagnostics)")
    }

    @Test("a user path binding with a matching placeholder is accepted")
    func userPathBindingWithPlaceholder() {
        let (source, diagnostics) = generate(
            """
            @RequestBinding(.path)
            public struct Slug<Value: Sendable>: RequestBound {}
            """,
            """
            @Controller("/pages")
            public struct PagesController {
                @Get("/{name}")
                @JSONResponse
                public func page(@Slug name: String) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
        #expect(source.contains("Slug<String>.bind("))
    }

    /// A binding with *no* `.path` obligation is not checked against the template — otherwise every
    /// `@Query`-shaped binding would be required to appear in the path.
    @Test("a binding without the obligation is not checked against the template")
    func noObligationNoPlaceholderCheck() {
        let (_, diagnostics) = generate(
            """
            @RequestBinding
            public struct Locale<Value: Sendable>: RequestBound {}
            """,
            """
            @Controller("/pages")
            public struct PagesController {
                @Get("/home")
                @JSONResponse
                public func page(@Locale locale: String) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
    }

    private func renderedClient(
        _ controllerSource: String,
        bindings: [String: DeclaredRequestBinding] = [:]
    ) -> String? {
        let file = Parser.parse(source: controllerSource)
        for statement in file.statements {
            if let d: any DeclSyntaxProtocol = statement.item.asProtocol(DeclGroupSyntax.self),
                let c = ControllerDeclaration(d)
            {
                return renderControllerClient(
                    controller: c,
                    pathPrefix: "/session",
                    discoveredBindings: bindings,
                    discoveredModes: WireMVCBuiltIns.modes
                ).source
            }
        }
        return nil
    }

    /// Warnings, kept apart from errors — `generate` returns only the latter.
    private func warnings(_ sources: String...) -> [String] {
        generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles
                + sources.enumerated().map { (path: "File\($0.offset).swift", source: $0.element) },
            testEntry: false,
            extraImports: [],
            sourceModules: [:],
            consumerModule: nil
        )
        .diagnostics.filter { $0.message.severity == .warning }.map(\.message.message)
    }

    private static let sessionController = """
        @Controller("/session")
        public struct SessionController {
            @Post
            @JSONResponse
            public func create(@FormBody input: Login) async throws -> Token { Token() }
        }
        """

    /// The client half of the seam: a user `.body` binding must reach `sendBody`, or its payload is dropped
    /// from the request.
    @Test("a user body binding supplies the body in the generated client")
    func userBodyBindingReachesTheClient() throws {
        let bindings = scanRequestBindings(in: [Parser.parse(source: Self.formBodyDeclaration)])
        let rendered = try #require(renderedClient(Self.sessionController, bindings: bindings))
        #expect(rendered.contains("let wireMVCBody = try FormBody<Login>.sendBody("))
        #expect(rendered.contains("body: wireMVCBody.bytes, contentType: wireMVCBody.contentType"))
    }

    /// Without the declaration the client cannot recognise the binding at all, so the **route is dropped** —
    /// not merely sent without its body. Asserting `!contains("sendBody")` alone would pass on an empty
    /// string and prove nothing, which is exactly how this went unnoticed once already.
    @Test("an unrecognised binding drops the route from the client entirely")
    func unrecognisedBindingDropsTheRoute() {
        #expect(renderedClient(Self.sessionController) == nil, "no declaration, no client — and no diagnostic")
    }

    /// A declared obligation the binding cannot honour. Without this the mismatch surfaces as
    /// `type 'X' has no member 'sendBody'` inside *generated* code, pointing at emitted text rather than at
    /// the declaration that is wrong.
    @Test("a .body binding without RequestBodySendable is warned about")
    func missingSendConformanceIsWarned() {
        let found = warnings(Self.formBodyDeclaration, Self.sessionController)
        #expect(found.contains { $0.contains("does not conform to RequestBodySendable") }, "got: \(found)")
    }

    @Test("a binding that does conform is not warned about")
    func conformingBindingIsQuiet() {
        let found = warnings(
            Self.formBodyDeclaration + "\nextension FormBody: RequestBodySendable {}",
            Self.sessionController
        )
        #expect(!found.contains { $0.contains("does not conform") }, "got: \(found)")
    }

    @Test("an unknown attribute is still diagnosed, not silently bound")
    func unknownIsStillDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Controller("/pages")
            public struct PagesController {
                @Get
                @JSONResponse
                public func page(@Pth id: String) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("needs a binding annotation") })
    }
}

/// The streaming request tier's codegen: what the terminal does differently, and the three combinations it
/// refuses. Driven through `generateRouteContributors`, so a binding declared in one file reaches a route in
/// another exactly as the plugin delivers it.
@Suite("Streaming request bindings")
struct StreamingBindingTests {

    private static let binding = """
        @RequestBinding(.readerBody)
        public struct Upload<Value>: RequestBodyReading {}
        """

    private func generate(_ controller: String) -> (source: String, diagnostics: [String]) {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                ("Upload.swift", Self.binding), ("Controller.swift", controller),
            ]
        )
        return (result.source, result.diagnostics.filter { $0.message.severity == .error }.map { $0.message.message })
    }

    /// The whole behavioural difference: the reader goes to the binding, and no body is collected.
    @Test("a streaming binding is handed the reader, and nothing is collected")
    func handsOverTheReader() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @JSONResponse
                public func receive(@Upload file: Receipt) async throws -> Receipt { file }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(source.contains("Upload<Receipt>.bindReader("))
        #expect(source.contains("reader: reader"))
        #expect(!source.contains("collectBody"), "a streamed route must not collect its body")
        // The reader is bound in the register closure rather than discarded as `_`.
        #expect(source.contains("pathParameters, reader, responseSender in"))
    }

    @Test("two streaming bindings on one route are refused")
    func twoStreamsRefused() {
        let (_, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @JSONResponse
                public func receive(@Upload a: Receipt, @Upload b: Receipt) async throws -> Receipt { a }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("stream the request body") }, "\(diagnostics)")
    }

    /// Streaming and collecting on one route cannot both happen — collecting consumes the reader.
    @Test("streaming beside a collected body is refused")
    func streamBesideCollectRefused() {
        let (_, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @JSONResponse
                public func receive(@Upload a: Receipt, @JSONBody b: Receipt) async throws -> Receipt { a }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("both streams and collects") }, "\(diagnostics)")
    }

    /// A **reduced** request body combines with a streaming response, through the lending terminal
    /// overload.
    ///
    /// This used to be refused, on the grounds that the streaming terminal consumes the reader before the
    /// head goes out. That is true of the collecting overload and not of `lendingBodyFrom:`, which hands
    /// the reader to `building` as a consuming parameter — moved in rather than captured — so the binding
    /// consumes it inside the mapped region. Lending the stream to the *handler* is still refused; see
    /// `BodyStreamBindingTests.lentStreamOnStreamingResponseRefused`.
    @Test("a reduced request body combines with a streaming response")
    func reducedBodyOnStreamingResponseAllowed() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @HTMLResponse
                public func receive(@Upload a: Receipt) async throws -> some HTML { Page() }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(source.contains("lendingBodyFrom: reader,"))
        #expect(!source.contains("collectingBodyFrom:"), "the reader can only be consumed once")
    }
}

/// The **lent stream** binding kind: the handler pulls from the body as it arrives, rather than being handed
/// a finished value.
///
/// Emitted unlike every other binding — `var x = Wrapper.makeStream(reader: reader)`, passed `&x` — because
/// the handler mutates it by pulling and the stream's type depends on the reader, which only the witness can
/// name. That is the whole reason this is a distinct obligation rather than a flavour of `.readerBody`.
@Suite("Lent body streams")
struct BodyStreamBindingTests {

    /// The binding is a property wrapper like every other, and names the stream type. It has to: the wrapper
    /// is generic over the parameter's type, so a static factory on it cannot resolve that generic parameter
    /// (`generic parameter 'Value' could not be inferred`), and the declaration is the only place left to say.
    private static let binding = """
        @RequestBinding(.bodyStream, stream: "MultipartParts")
        @propertyWrapper
        public struct Upload<Value: ~Copyable>: ~Copyable { public var wrappedValue: Value }
        """

    private func generate(_ controller: String) -> (source: String, diagnostics: [String]) {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                ("Upload.swift", Self.binding), ("Controller.swift", controller),
            ]
        )
        return (result.source, result.diagnostics.filter { $0.message.severity == .error }.map { $0.message.message })
    }

    private func controller(ownership: String) -> String {
        """
        @Singleton @Controller("/files")
        public struct Files {
            @Post @JSONResponse
            public func receive<S: PartStream & ~Copyable>(@Upload parts: \(ownership) S) async throws -> Receipt {
                Receipt()
            }
        }
        """
    }

    /// A **lent** stream does not combine with a streaming response, where a reduced body now does — see
    /// `StreamingBindingTests.reducedBodyOnStreamingResponseAllowed`.
    ///
    /// The reason is the typed tier's shape rather than the reader's ownership: a handler returns before its
    /// response body is written, so it cannot still be holding the stream. Expressing it needs the response
    /// to be a parameter rather than a return value, which is designed and ownership-verified but blocked on
    /// swiftlang/swift#91473 (#173). `@RawRoute` serves the case meanwhile.
    @Test("a lent stream on a streaming response route is refused")
    func lentStreamOnStreamingResponseRefused() {
        let (_, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @HTMLResponse
                public func receive<S: PartStream & ~Copyable>(@Upload parts: consuming S) async throws -> some HTML {
                    Page()
                }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("lends its request body stream") }, "\(diagnostics)")
        // It points at what does work rather than only refusing.
        #expect(diagnostics.contains { $0.contains("@RawRoute") }, "\(diagnostics)")
    }

    /// `consuming` is the only ownership that fits: the stream is used up once, through `withParts`.
    @Test("a consuming stream is built from the reader and passed by value")
    func consumingStream() {
        let (source, diagnostics) = generate(controller(ownership: "consuming"))
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        // `let`, not `var`: consuming a binding is not mutating it, so `var` was only ever a
        // `VariableNeverMutated` warning in generated code.
        #expect(source.contains("let parts = MultipartParts(request: request, reader: reader)"))
        #expect(source.contains("receive(parts: parts)"), "by value for consuming")
        #expect(!source.contains("collectBody"), "a lent stream must not collect the body first")
        #expect(!source.contains("MultipartParts<"), "no type argument — the reader is inferred from the call")
    }

    /// The construction is a spelling; the check that the request can produce the stream at all is a
    /// `LentBodyStream` requirement, called on the constructed value.
    ///
    /// It is emitted **before** the handler is called and inside `building`, which is the whole point. On
    /// today's tiers a check deferred to `withParts` would map just as well — the handler runs before the
    /// head. The duplex shape runs it after, where the same deferred check truncates a response that has
    /// already claimed a status.
    @Test("a lent stream is validated after construction and before the handler")
    func lentStreamValidated() {
        let (source, diagnostics) = generate(controller(ownership: "consuming"))
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        let construct = source.range(of: "let parts = MultipartParts(request: request, reader: reader)")
        let validate = source.range(of: "try parts.validateRequest()")
        let call = source.range(of: "receive(parts: parts)")
        #expect(construct != nil && validate != nil && call != nil, "\(source)")
        if let construct, let validate, let call {
            #expect(construct.upperBound < validate.lowerBound, "validated after it exists")
            #expect(validate.upperBound < call.lowerBound, "and before the handler is given it")
        }
        // Borrowing, so the stream survives to be lent on: it is still `parts` that reaches the handler,
        // not something the check handed back.
        #expect(!source.contains("parts = try parts.validateRequest()"), "\(source)")
    }

    /// Only a lent stream gets the call. Every other binding's construction can throw on its own, so a
    /// second statement would be a check with nothing to check.
    @Test("an ordinary binding is not given a validation step")
    func ordinaryBindingNotValidated() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post("/{id}") @JSONResponse
                public func receive(@Path id: String, @JSONBody meta: Meta) async throws -> Receipt {
                    Receipt()
                }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(!source.contains("validateRequest()"), "\(source)")
    }

    /// `inout` is refused rather than emitted. It was briefly supported on the theory that SE-0293 would
    /// make it usable — but it is wrong for this shape regardless: calling a `consuming` method on an
    /// `inout` binding is `missing reinitialization of inout parameter after consume`, and a stream has
    /// nothing sensible to put back.
    @Test("an inout stream parameter is refused")
    func inoutStreamRefused() {
        let (_, diagnostics) = generate(controller(ownership: "inout"))
        #expect(diagnostics.contains { $0.contains("must be 'consuming'") }, "\(diagnostics)")
    }

    /// A non-copyable parameter must state ownership anyway; saying so here names the one spelling that
    /// works, rather than leaving the author with the compiler's generic advice.
    @Test("a stream parameter with no ownership is diagnosed")
    func missingOwnership() {
        let (_, diagnostics) = generate(controller(ownership: ""))
        #expect(diagnostics.contains { $0.contains("must be 'consuming'") }, "\(diagnostics)")
    }

    @Test("a bodyStream binding naming no stream type is diagnosed")
    func missingStreamType() {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                (
                    "Upload.swift",
                    """
                    @RequestBinding(.bodyStream)
                    @propertyWrapper
                    public struct Upload<Value: ~Copyable>: ~Copyable { public var wrappedValue: Value }
                    """
                ),
                ("Controller.swift", controller(ownership: "consuming")),
            ]
        )
        let messages = result.diagnostics.map { $0.message.message }
        #expect(messages.contains { $0.contains("names no stream type") }, "\(messages)")
    }

    /// A lent stream must not be nagged about `RequestSendable`. It has nothing to send, its route is
    /// omitted from the client on purpose, and the warning's own advice — add the conformance or the call
    /// will not compile — is about a call that is never generated.
    @Test("a lent stream is exempt from the send-conformance warning")
    func lentStreamNotWarnedAbout() {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                ("Upload.swift", Self.binding),
                ("Controller.swift", controller(ownership: "consuming")),
            ],
            testEntry: true
        )
        let messages = result.diagnostics.map { $0.message.message }
        #expect(
            !messages.contains { $0.contains("does not conform to RequestSendable") },
            "\(messages)"
        )
    }

    /// Both streamed kinds consume the route's one reader, so mixing them is the same contradiction as
    /// using either twice.
    @Test("a lent stream beside a reducing stream is refused")
    func lentBesideReducingRefused() {
        let (_, diagnostics) = generate(
            """
            @RequestBinding(.readerBody)
            public struct Digest<Value>: RequestBodyReading {}

            @Singleton @Controller("/files")
            public struct Files {
                @Post @JSONResponse
                public func receive<S: PartStream & ~Copyable>(
                    @Upload parts: consuming S, @Digest digest: BodyDigest
                ) async throws -> Receipt { Receipt() }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("stream the request body") }, "\(diagnostics)")
    }

    @Test("a lent stream beside a collected body is refused")
    func lentBesideCollectRefused() {
        let (_, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @JSONResponse
                public func receive<S: PartStream & ~Copyable>(
                    @Upload parts: consuming S, @JSONBody meta: Meta
                ) async throws -> Receipt { Receipt() }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("both streams and collects") }, "\(diagnostics)")
    }
}

/// A lent stream has no typed-client shape, and its absence is a stated property rather than an accident.
///
/// The client used to emit a method for it, and the method did not compile: it spelled
/// `Wrapper<consuming Stream>.send(…)`, because the generic machinery assumed every binding has a value to
/// send. A lent stream does not — its parameter is the *means of pulling* the body, and a client has no
/// reader to build one from.
@Suite("Lent streams and the typed client")
struct LentStreamClientTests {

    private func client(_ sources: String...) -> String {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles
                + sources.enumerated().map { (path: "File\($0.offset).swift", source: $0.element) },
            testEntry: true
        )
        return result.source
    }

    @Test("a lent-stream route is omitted, and its siblings are not")
    func lentStreamRouteOmitted() {
        let source = client(
            """
            @RequestBinding(.bodyStream, stream: "MultipartParts")
            @propertyWrapper
            public struct Upload<Value: ~Copyable>: ~Copyable { public var wrappedValue: Value }
            """,
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post("/stream") @JSONResponse
                public func receiveStream<S: PartStream & ~Copyable>(
                    @Upload parts: consuming S
                ) async throws -> Receipt { Receipt() }

                @Get("/count") @JSONResponse
                public func count() async throws -> Receipt { Receipt() }
            }
            """
        )
        #expect(!source.contains("func receiveStream("), "a lent stream has no client shape")
        #expect(source.contains("func count("), "and omitting it does not take the controller's other routes with it")
    }

    /// The controller emitted no client at all before this was handled — every route on it vanished, not
    /// just the streaming one. Worth pinning separately, since that is the failure mode that hurts.
    @Test("a controller whose only route is a lent stream still emits nothing broken")
    func lentStreamOnlyController() {
        let source = client(
            """
            @RequestBinding(.bodyStream, stream: "MultipartParts")
            @propertyWrapper
            public struct Upload<Value: ~Copyable>: ~Copyable { public var wrappedValue: Value }
            """,
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post("/stream") @JSONResponse
                public func receiveStream<S: PartStream & ~Copyable>(
                    @Upload parts: consuming S
                ) async throws -> Receipt { Receipt() }
            }
            """
        )
        #expect(!source.contains("struct FilesClient"), "no client rather than an empty or broken one")
        #expect(!source.contains(".send(name: \"parts\""), "and certainly not an uncompilable send")
    }

}
