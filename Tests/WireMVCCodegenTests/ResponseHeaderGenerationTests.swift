import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// Response headers on a typed route: the `@ResponseHeader` constants, the labelled response tuple, and
/// how the two resolve into one `headerFields:` argument. Pins each rung of the ladder separately — the
/// fixtures prove the whole thing compiles and serves, but only these say *what* was emitted.
@Suite("Response header generation")
struct ResponseHeaderGenerationTests {

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

    private func witness(_ source: String, pathPrefix: String = "/things") -> String {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: pathPrefix,
            subjectAccessor: "_wireSubject",
            factoryKeys: []
        ).witness
    }

    // MARK: - Emission

    /// The regression that matters most: a route using none of this emits exactly what it emitted before
    /// response headers existed — no `headerFields:` argument, no `resolved` call, no return local. It is
    /// what lets the 77 pre-existing goldens stay untouched, so it is asserted rather than assumed.
    @Test func routeWithoutHeadersEmitsTheOriginalCall() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/{id}") @JSONResponse
                func get(@Path id: String) async throws -> Thing { Thing() }
            }
            """
        let emitted = witness(source)
        #expect(
            emitted.contains(
                "wireMVCOutcome = try WireMVCResponse.json(try await self._wireSubject.get(id: id), "
                    + "status: .ok, coding: wireMVCAppCoding)"
            )
        )
        #expect(!emitted.contains("headerFields:"))
        #expect(!emitted.contains("wireMVCReturn"))
    }

    /// Tier order is application order — controller entries first, the route's after — and the verb rides
    /// through as the contribution's case name, so `.append` stays an append rather than being normalised
    /// to a set.
    @Test func staticHeadersEmitInTierOrderWithVerbs() {
        let source = """
            @Singleton @Controller("/things")
            @ResponseHeader(.cacheControl, "public")
            @ResponseHeader(.vary, "Accept-Encoding")
            struct Things {
                @Get("/{id}") @JSONResponse
                @ResponseHeader(.cacheControl, "no-store")
                @ResponseHeader(.vary, "Origin", .append)
                func get(@Path id: String) async throws -> Thing { Thing() }
            }
            """
        #expect(
            witness(source).contains(
                "headerFields: WireMVCResponseHeaders.resolved(statics: ["
                    + ".set(.cacheControl, \"public\"), .set(.vary, \"Accept-Encoding\"), "
                    + ".set(.cacheControl, \"no-store\"), .append(.vary, \"Origin\")])"
            )
        )
    }

    /// The full tuple: body, status and headers all projected off one return local, with the statics under
    /// the returned fields.
    @Test func fullResponseTupleProjectsEveryElement() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/{id}") @JSONResponse
                @ResponseHeader(.cacheControl, "no-store")
                func get(@Path id: String) async throws
                    -> (status: HTTPResponse.Status, headers: HTTPFields, body: Thing) { fatalError() }
            }
            """
        let emitted = witness(source)
        #expect(emitted.contains("let wireMVCReturn = try await self._wireSubject.get(id: id)"))
        #expect(
            emitted.contains(
                "WireMVCResponse.json(wireMVCReturn.body, status: wireMVCReturn.status, "
                    + "headerFields: WireMVCResponseHeaders.resolved("
                    + "statics: [.set(.cacheControl, \"no-store\")], returned: wireMVCReturn.headers)"
            )
        )
    }

    /// A tuple naming only `headers` leaves the status to the annotation — the annotation stays the
    /// declared default and the return overrides only what it actually names.
    @Test func headersOnlyTupleKeepsTheAnnotatedStatus() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Post("/") @JSONResponse(status: .created)
                func make() async throws -> (headers: HTTPFields, body: Thing) { fatalError() }
            }
            """
        let emitted = witness(source)
        #expect(emitted.contains("status: .created"))
        #expect(!emitted.contains("status: wireMVCReturn.status"))
        #expect(emitted.contains("returned: wireMVCReturn.headers"))
    }

    /// The bodiless tuple — the computed-redirect shape — carries **no** response annotation: its return
    /// type states both the mode and that the status is computed.
    @Test func bodilessTupleEmitsAStatusOutcomeWithNoAnnotation() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/moved")
                func moved() async throws -> (status: HTTPResponse.Status, headers: HTTPFields) { fatalError() }
            }
            """
        #expect(
            witness(source).contains(
                "wireMVCOutcome = .status(wireMVCReturn.status, "
                    + "headerFields: WireMVCResponseHeaders.resolved(returned: wireMVCReturn.headers))"
            )
        )
        #expect(diagnostics(source).isEmpty, "the return type is the declaration; no annotation is owed")
    }

    /// …and writing one anyway is rejected, rather than silently ignored. Before this rule the annotation's
    /// status was emitted nowhere while looking authoritative in the source.
    @Test func annotatingASelfDescribingReturnIsDiagnosed() {
        let messages = diagnostics(
            """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/moved") @ResponseStatus(.found)
                func moved() async throws -> (status: HTTPResponse.Status, headers: HTTPFields) { fatalError() }
            }
            """
        )
        #expect(
            messages.contains { if case .responseAnnotationOnSelfDescribingReturn = $0 { true } else { false } }
        )
    }

    /// A body-carrying tuple still needs `@JSONResponse` — that names the codec — but its `status:`
    /// argument would never be read, so it is rejected too. The dead value becomes unwritable rather than
    /// merely diagnosed.
    @Test func annotatedStatusBesideAReturnedStatusIsDiagnosed() {
        let messages = diagnostics(
            """
            @Singleton @Controller("/things")
            struct Things {
                @Post("/") @JSONResponse(status: .created)
                func make() async throws -> (status: HTTPResponse.Status, body: Thing) { fatalError() }
            }
            """
        )
        #expect(messages.contains { if case .deadResponseStatusArgument = $0 { true } else { false } })
    }

    /// The bare `@JSONResponse` beside a returned status is the correct spelling, and emits the returned
    /// one with no trace of the annotation's implicit `.ok`.
    @Test func bareJSONResponseBesideAReturnedStatusIsAccepted() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Post("/") @JSONResponse
                func make() async throws -> (status: HTTPResponse.Status, body: Thing) { fatalError() }
            }
            """
        #expect(diagnostics(source).isEmpty)
        #expect(witness(source).contains("status: wireMVCReturn.status"))
        #expect(!witness(source).contains("status: .ok"))
    }

    /// A `Void` handler still carries its constants — the status-only response that says something.
    @Test func responseStatusRouteCarriesStaticHeaders() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Delete("/{id}") @ResponseStatus(.noContent)
                @ResponseHeader(.cacheControl, "no-store")
                func remove(@Path id: String) async throws {}
            }
            """
        #expect(
            witness(source).contains(
                "wireMVCOutcome = .status(.noContent, headerFields: "
                    + "WireMVCResponseHeaders.resolved(statics: [.set(.cacheControl, \"no-store\")]))"
            )
        )
    }

    /// An *unlabelled* tuple is a payload, not a response shape, so nothing about it changes. This is what
    /// keeps the feature from silently reinterpreting an existing handler's return type.
    @Test func unlabelledTupleStaysABody() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/pair") @JSONResponse
                func pair() async throws -> (Int, String) { fatalError() }
            }
            """
        let emitted = witness(source)
        #expect(emitted.contains("WireMVCResponse.json(try await self._wireSubject.pair()"))
        #expect(!emitted.contains("wireMVCReturn"))
    }

    // MARK: - Typed client

    /// The client decodes what crosses the wire, which is the body — not the tuple the handler wrote.
    /// Before this projection the generated test target failed to compile ("cannot conform to 'Decodable'").
    @Test func clientDecodesTheTupleBody() throws {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/{id}") @JSONResponse
                func get(@Path id: String) async throws
                    -> (status: HTTPResponse.Status, headers: HTTPFields, body: Thing) { fatalError() }
            }
            """
        let client = try #require(renderControllerClient(controller: controller(source), pathPrefix: "/things"))
        #expect(client.contains("async throws -> Thing"))
        #expect(!client.contains("status: HTTPResponse.Status"))
    }

    /// A bodiless tuple has nothing to decode, so the method returns nothing — and, the actual bug, it is
    /// still *generated*. Reading the whole tuple as "returns a value" tripped the `@ResponseStatus` check
    /// and dropped the route from the client with no diagnostic at all.
    @Test func clientStillGeneratesForABodilessTuple() throws {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/moved")
                func moved() async throws -> (status: HTTPResponse.Status, headers: HTTPFields) { fatalError() }
            }
            """
        let client = try #require(renderControllerClient(controller: controller(source), pathPrefix: "/things"))
        #expect(client.contains("func moved("))
        #expect(!client.contains("-> (status:"))
    }

    // MARK: - Diagnostics

    private func diagnostics(_ source: String) -> [WireMVCDiagnostic] {
        generateRouteContributors(files: [("Things.swift", source)]).diagnostics.map(\.message)
    }

    /// A near-miss on the labels is far more likely a typo than an intended payload, so it is rejected
    /// rather than quietly encoded as a JSON body.
    @Test func invalidResponseTupleLabelsAreDiagnosed() {
        let messages = diagnostics(
            """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/{id}") @JSONResponse
                func get(@Path id: String) async throws -> (status: HTTPResponse.Status, header: HTTPFields) {
                    fatalError()
                }
            }
            """
        )
        #expect(messages.contains { if case .responseTupleInvalidLabels = $0 { true } else { false } })
    }

    /// Two `set`s of one field at one scope has no answer — neither can be said to have been meant.
    @Test func twoSetsOfOneFieldAreDiagnosed() {
        let messages = diagnostics(
            """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/{id}") @JSONResponse
                @ResponseHeader(.vary, "Accept-Encoding")
                @ResponseHeader(.vary, "Origin")
                func get(@Path id: String) async throws -> Thing { Thing() }
            }
            """
        )
        #expect(messages.contains { if case .responseHeaderDuplicateField = $0 { true } else { false } })
    }

    /// …but a second entry that *appends* is exactly what a repeatable field wants, and must pass. This is
    /// the case the pre-verb design got wrong: it rejected this and advised folding the values, which is
    /// invalid for `Set-Cookie`.
    @Test func appendingASecondValueIsNotADuplicate() {
        let source = """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/{id}") @JSONResponse
                @ResponseHeader(.setCookie, "a=1")
                @ResponseHeader(.setCookie, "b=2", .append)
                func get(@Path id: String) async throws -> Thing { Thing() }
            }
            """
        #expect(diagnostics(source).isEmpty)
        #expect(
            witness(source).contains(
                "statics: [.set(.setCookie, \"a=1\"), .append(.setCookie, \"b=2\")]"
            )
        )
    }

    /// A raw handler writes its own response head, so nothing here could set the field for it — and
    /// silently ignoring the annotation would look like it applied.
    @Test func responseHeaderOnARawRouteIsDiagnosed() {
        let messages = diagnostics(
            """
            @Singleton @Controller("/things")
            struct Things {
                @Get("/stream") @RawRoute
                @ResponseHeader(.cacheControl, "no-store")
                func stream<S: HTTPResponseSender & ~Copyable>(responseSender: consuming S) async throws
                where S.Writer: ~Copyable {}
            }
            """
        )
        #expect(messages.contains { if case .responseHeaderOnRawRoute = $0 { true } else { false } })
    }
}
