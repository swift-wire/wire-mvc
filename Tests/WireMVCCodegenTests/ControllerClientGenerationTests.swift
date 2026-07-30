import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

// The per-controller typed client: one method per typed route, parameters from the route's bindings, return
// from its `@JSONResponse` type. Derived from the same declarations the witness reads, so these assert the
// derivation rather than a hand-written surface.

@Suite("Controller client generation")
struct ControllerClientGenerationTests {
    private func controller(_ source: String) -> ControllerDeclaration {
        let file = Parser.parse(source: source)
        for statement in file.statements {
            if let structDecl = statement.item.as(StructDeclSyntax.self),
                let declaration = ControllerDeclaration(structDecl)
            {
                return declaration
            }
        }
        fatalError("no controller in fixture")
    }

    /// The whole shape for one route: a `@Path` binding becomes a parameter, the path template travels
    /// verbatim (the runtime substitutes), and the `@JSONResponse` type becomes the return.
    @Test func aTypedRouteBecomesATypedMethod() {
        let declaration = controller(
            """
            @Controller("/notes")
            struct NotesController {
                @Get("/{id}")
                @JSONResponse
                func fetch(@Path("id") id: String) async throws -> Note { fatalError() }
            }
            """
        )
        #expect(
            renderControllerClient(controller: declaration, pathPrefix: "/notes") == """
                /// Typed access to `NotesController`'s routes, derived from its verb annotations. Each method
                /// returns the route's decoded response and throws `WireMVCRouteError` for a non-2xx.
                struct NotesControllerClient {
                    let client: TestClient

                    /// `GET /notes/{id}`
                    func fetch(id: String) async throws -> Note {
                        let wireMVCResponse = try await client.routeResponse(method: "GET", path: "/notes/{id}", pathParameters: ["id": String(id)])
                        return try wireMVCResponse.json(Note.self)
                    }
                }

                /// `NotesController`'s routes, over the running suite's transport.
                var notesController: NotesControllerClient {
                    NotesControllerClient(client: .current)
                }
                """
        )
    }

    /// An optional `@Query` alongside a required one. `??` binds looser than `+`, so the entries must be
    /// parenthesised individually — `optional.map { … } ?? [] + [next]` parses as
    /// `optional ?? ([] + [next])`, silently dropping every following item whenever the optional is present.
    @Test func anOptionalQueryDoesNotSwallowLaterItems() {
        let declaration = controller(
            """
            @Controller("/todos")
            struct TodosController {
                @Get("/")
                @JSONResponse
                func list(@Query("q") search: String?, @Query("page") page: Int) async throws -> [Todo] { fatalError() }
            }
            """
        )
        let rendered = try! #require(renderControllerClient(controller: declaration, pathPrefix: "/todos"))
        #expect(rendered.contains(#"(search.map {"#))
        #expect(rendered.contains(#"} ?? []) + ([(name: "page", value: String(page))])"#))
        // The required item must not sit inside the `??`'s right-hand side.
        #expect(!rendered.contains(#"?? [] + ["#))
    }

    /// `@Header` and `@JSONBody`: the header travels as a wire-named string, the body as the encoded value.
    @Test func headerAndBodyBindingsBecomeArguments() {
        let declaration = controller(
            """
            @Controller("/todos")
            struct TodosController {
                @Post("/")
                @JSONResponse(status: .created)
                func create(@JSONBody body: NewTodo, @Header("x-session") session: String) async throws -> Todo { fatalError() }
            }
            """
        )
        let rendered = try! #require(renderControllerClient(controller: declaration, pathPrefix: "/todos"))
        #expect(rendered.contains(#"headers: ["x-session": String(session)]"#))
        #expect(rendered.contains("json: body"))
        #expect(rendered.contains("func create(body: NewTodo, session: String) async throws -> Todo"))
    }

    /// A `@ResponseStatus` route returns `Void` — there is no body to decode, and `routeResponse` has
    /// already thrown for a non-2xx.
    @Test func aStatusOnlyRouteReturnsVoid() {
        let declaration = controller(
            """
            @Controller("/todos")
            struct TodosController {
                @Delete("/{id}")
                @ResponseStatus(.noContent)
                func remove(@Path("id") id: Int) async throws {}
            }
            """
        )
        let rendered = try! #require(renderControllerClient(controller: declaration, pathPrefix: "/todos"))
        #expect(rendered.contains("func remove(id: Int) async throws {"))
        #expect(rendered.contains("_ = try await client.routeResponse("))
        #expect(!rendered.contains(".json("))
    }

    /// A `@RawRoute` gets a shim, not a typed method: its parameters are all roles and it writes its own
    /// response, so nothing on either side is typed — but the request line still is. The shim is shaped after
    /// the proposal's `HTTPClient.perform`, handing the response head and a body reader to a closure, and
    /// applies no status rule because a raw route may answer a non-2xx by design.
    @Test func rawRoutesGetAnUntypedShim() {
        let declaration = controller(
            """
            @Controller("/exports")
            struct ExportController {
                @Get("/{id}")
                @JSONResponse
                func fetch(@Path("id") id: String) async throws -> Export { fatalError() }

                @Get("/stream")
                @RawRoute
                func stream<S: HTTPResponseSender & ~Copyable>(responseSender: consuming S) async throws {}
            }
            """
        )
        let rendered = try! #require(renderControllerClient(controller: declaration, pathPrefix: "/exports"))
        #expect(rendered.contains("func fetch(id: String) async throws -> Export"))
        #expect(rendered.contains("func stream<WireMVCRawReturn: ~Copyable>("))
        #expect(
            rendered.contains(
                "responseHandler: (HTTPResponse, consuming TestResponseReader) async throws -> WireMVCRawReturn"
            )
        )
        #expect(rendered.contains(#"client.performRawRoute(method: "GET", path: "/exports/stream""#))
        // The typed route keeps the status rule; the raw one must not.
        #expect(rendered.contains(#"client.routeResponse(method: "GET", path: "/exports/{id}""#))
    }

    /// A raw route declares no bindings, so its arguments come from the path template's placeholders — which
    /// is the whole point of the shim: the path is derived, so renaming the route breaks the test.
    @Test func aRawRoutesPlaceholdersBecomeParameters() {
        let declaration = controller(
            """
            @Controller("/exports")
            struct ExportController {
                @Get("/{id}/parts/{part}")
                @RawRoute
                func part<S: HTTPResponseSender & ~Copyable>(
                    pathParameters: [String: Substring],
                    responseSender: consuming S
                ) async throws {}
            }
            """
        )
        let rendered = try! #require(renderControllerClient(controller: declaration, pathPrefix: "/exports"))
        #expect(rendered.contains("func part<WireMVCRawReturn: ~Copyable>(id: String, part: String,"))
        #expect(rendered.contains(#"pathParameters: ["id": String(id), "part": String(part)]"#))
    }

    /// Placeholder extraction is the shim's only source of parameters, so it is pinned directly: order of
    /// appearance, duplicates collapsed, and a name that isn't a valid identifier sanitised for the
    /// parameter while the wire name stays as written.
    @Test func placeholdersAreReadInOrderAndSanitised() {
        let parameters = pathPlaceholderParameters(in: "/a/{user-id}/b/{tail}/c/{tail}")
        #expect(parameters.map(\.name) == ["userId", "tail"])
        #expect(parameters.map(\.wireName) == ["user-id", "tail"])
        #expect(parameters.allSatisfy { $0.type == "String" })
    }

    /// A controller with no verb-annotated route at all gets no client — an empty struct is noise. (One with
    /// only raw routes *does* get one: the shims are the point.)
    @Test func aControllerWithNoRouteEmitsNothing() {
        let declaration = controller(
            """
            @Controller("/exports")
            struct ExportController {
                func notARoute() {}
            }
            """
        )
        #expect(renderControllerClient(controller: declaration, pathPrefix: "/exports") == nil)
    }

    /// The client is a test-only surface: a program consumer must not link `TestClient`, so `--test-entry`
    /// gates it.
    @Test func theClientIsOnlyEmittedForATestConsumer() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {}

            @Singleton
            @Controller("/notes")
            struct NotesController {
                @Get("/{id}")
                @JSONResponse
                func fetch(@Path("id") id: String) async throws -> Note { fatalError() }
            }
            """
        let program = generateRouteContributors(files: [("App.swift", source)], testEntry: false)
        #expect(!program.source.contains("NotesControllerClient"))

        let test = generateRouteContributors(files: [("App.swift", source)], testEntry: true)
        #expect(test.source.contains("struct NotesControllerClient {"))
        #expect(test.source.contains("var notesController: NotesControllerClient {"))
    }
}
