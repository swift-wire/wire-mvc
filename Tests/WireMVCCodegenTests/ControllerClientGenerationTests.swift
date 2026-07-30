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

    /// `@RawRoute` has no derivable shape — it owns its own wire format — so it contributes no method and no
    /// diagnostic. It stays reachable through `TestClient`'s untyped verbs.
    @Test func rawRoutesAreSkipped() {
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
        #expect(rendered.contains("func fetch(id: String)"))
        #expect(!rendered.contains("stream"))
    }

    /// A controller whose every route is raw gets no client at all — an empty struct is noise.
    @Test func aControllerWithNoTypedRouteEmitsNothing() {
        let declaration = controller(
            """
            @Controller("/exports")
            struct ExportController {
                @Get("/stream")
                @RawRoute
                func stream<S: HTTPResponseSender & ~Copyable>(responseSender: consuming S) async throws {}
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
