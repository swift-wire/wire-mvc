import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// The domain half of a route contributor: the `WireMVCRouteGen` tool (via `WireMVCCodegen`) emits the
/// `RouteContributor` witness as an `extension` on the plugin-emitted structural proxy, folding the route
/// codegen (verbs, `@Path`/… bindings, response modes, `@RawRoute`, the `~Copyable` middleware fold) off
/// the proxy's `_wireSubject` / `_wire<…>` / `_wireFactory_<key>` fields. These tests pin the emitted
/// extension for every route shape, the `@Middleware` classification (factory / by-type / by-key), and the
/// diagnostics.
@Suite("Route-contributor generation")
struct RouteContributorGenerationTests {

    /// Parse a fixture and return its first `@Controller` type as a `ControllerDeclaration`.
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

    private func witnessBody(
        _ source: String,
        pathPrefix: String,
        subjectAccessor: String,
        factoryKeys: Set<String> = []
    ) -> String {
        renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: pathPrefix,
            subjectAccessor: subjectAccessor,
            factoryKeys: factoryKeys
        ).witness
    }

    // MARK: - Golden extensions, per route shape

    @Test func plainJSONRouteWithPathBinding() {
        let source = """
            @Controller("/todos")
            struct Todos {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Todo {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/todos",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source == """
                extension _WireRouteContributor_Todos: RouteContributor {
                    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/todos/{id}") { request, _, pathParameters, _, responseSender in
                            let wireMVCOutcome: WireMVCOutcome
                            do {
                                let id = try await Path<String>.bind(name: "id", request: request, pathParameters: pathParameters, body: nil)
                                wireMVCOutcome = try WireMVCResponse.json(try await self._wireSubject.get(id: id), status: .ok)
                            } catch let wireMVCError {
                                wireMVCOutcome = (
                                    (wireMVCError as? WireMVCBindingError).map {
                                        WireMVCOutcome.status($0.status)
                                    }
                                    ?? WireMVCOutcome.status(.internalServerError)
                                )
                            }
                            try await wireMVCOutcome.send(on: responseSender)
                        }
                    }
                }
                """
        )
    }

    // MARK: - @WireMVCBootstrap composition root (M5.5 Phase 1)

    /// The generated `@main` entry: reads the `@WireMVCBootstrap` binding off the graph
    /// (`graph.appBootstrap`), builds the server + router from its factories, applies the collated
    /// routes, and serves via `WireMVC.serve`. `createServer` is `throws`, so its call carries `try`.
    @Test func bootstrapEntryGeneratesMain() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                @Inject let config: ServerConfig
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let decl = controller(source)
        let fallback = renderNotFoundRegistration(bootstrap: decl).registration  // no @NotFound → synth-404
        #expect(
            renderBootstrapEntry(bootstrap: decl, notFoundRegistration: fallback, factoryKeys: []) == """
                @main
                struct _WireMVCBootstrapEntry {
                    static func main() async throws {
                        let graph = try await Wire.bootstrap()
                        let bootstrap = graph.appBootstrap
                        let server = try bootstrap.createServer()
                        var builder = bootstrap.createRouteBuilder(for: server)
                        let wireMVCServices = try WireMVC.apply(graph, to: &builder)
                        builder.registerNotFound { _, _, _, _, responseSender in
                            try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
                        }
                        let handler = builder.finalize()
                        let wireMVCServed = graph._WireGlobalMiddleware_AppBootstrap.wrapGlobalMiddleware(handler)
                        try await WireMVC.serve(on: server, handler: wireMVCServed, services: wireMVCServices)
                    }
                }
                """
        )
    }

    /// The generated `.wiremvc(_:)` suite-trait factory: a `SuiteTrait` extension whose `WireMVCSuiteTrait`
    /// closure inlines ONE build (graph → server → builder → apply → registrations → finalize →
    /// `wrapGlobalMiddleware`) and hands the opaque handler to `WireMVCTesting.runSuite`. It is generic over
    /// the server the mode carries, because the route builder takes its `~Copyable` associated types from
    /// that server — which is also why the generated code names no concrete server, and why there is one
    /// build path rather than one per transport. The build sequence is shared with the `@main` (both wrap
    /// `bootstrapBuildLines`); only the `server` line differs.
    @Test func bootstrapGeneratesTestServerEntry() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                @Inject let config: ServerConfig
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let decl = controller(source)
        let fallback = renderNotFoundRegistration(bootstrap: decl).registration  // no @NotFound → synth-404
        #expect(
            renderBootstrapTestEntry(bootstrap: decl, notFoundRegistration: fallback, factoryKeys: []) == """
                extension SuiteTrait where Self == WireMVCSuiteTrait {
                    static func wiremvc<WireMVCTestServerType: HTTPServer>(
                        _ mode: WireMVCTestMode<WireMVCTestServerType>,
                        services: WireMVCTestServices? = nil
                    ) -> WireMVCSuiteTrait
                    where
                        WireMVCTestServerType.RequestContext: ~Copyable,
                        WireMVCTestServerType.Reader: ~Copyable,
                        WireMVCTestServerType.ResponseSender: ~Copyable,
                        WireMVCTestServerType.ResponseSender.Writer: ~Copyable
                    {
                        WireMVCSuiteTrait { runTests in
                            let graph = try await Wire.bootstrap()
                            let bootstrap = graph.appBootstrap
                            let server = mode.makeTestServer()
                            var builder = bootstrap.createRouteBuilder(for: server)
                            let wireMVCServices = try WireMVC.apply(graph, to: &builder)
                            builder.registerNotFound { _, _, _, _, responseSender in
                                try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
                            }
                            let handler = builder.finalize()
                            let wireMVCServed = graph._WireGlobalMiddleware_AppBootstrap.wrapGlobalMiddleware(handler)
                            try await WireMVCTesting.runSuite(mode, on: server, handler: wireMVCServed, services: wireMVCServices, servicePolicy: services, runTests: runTests)
                        }
                    }
                }
                """
        )
    }

    /// The app's own `createServer()` belongs to the `@main` only. A suite serves the server its mode
    /// carries, so production server configuration (TLS, bind interface, timeouts, HTTP/2) never has to be
    /// un-configured for tests.
    @Test func testEntryNeverCallsCreateServer() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let decl = controller(source)
        let entry = renderBootstrapTestEntry(bootstrap: decl, notFoundRegistration: "", factoryKeys: [])
        #expect(!entry.contains("createServer()"))
        #expect(entry.contains("let server = mode.makeTestServer()"))
        // The @main is the one place it is still called.
        #expect(
            renderBootstrapEntry(bootstrap: decl, notFoundRegistration: "", factoryKeys: []).contains("createServer()")
        )
    }

    /// A `mountIntrospectionAt() -> String?` method makes the generated `@main` register the graph's wiring
    /// model (`introspect()` JSON) at the returned path — before `finalize()`, so it's a real route.
    @Test func bootstrapEntryMountsIntrospection() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
                func mountIntrospectionAt() -> String? { "/wiring" }
            }
            """
        let rendered = renderBootstrapEntry(bootstrap: controller(source), notFoundRegistration: "", factoryKeys: [])
        #expect(rendered.contains("if let wireMVCIntrospectionPath = bootstrap.mountIntrospectionAt() {"))
        #expect(
            rendered.contains(
                "try WireMVC.mountIntrospection(for: graph, into: &builder, at: wireMVCIntrospectionPath)"
            )
        )
    }

    /// No `mountIntrospectionAt` method → no introspection mount in the entry.
    @Test func bootstrapEntryOmitsIntrospectionWhenAbsent() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        #expect(
            !renderBootstrapEntry(bootstrap: controller(source), notFoundRegistration: "", factoryKeys: []).contains(
                "mountIntrospection"
            )
        )
    }

    /// A `@Middleware`-guarded `mountIntrospectionAt` folds the guard around the introspection route: the
    /// proxy gains `registerIntrospection` folding the guard factory, and the `@main` calls it (precomputing
    /// the model once) instead of `WireMVC.mountIntrospection`. The guard factory is already on the proxy —
    /// the plugin reattributes the method-level `@Middleware` exactly as it does route-scope middleware.
    @Test func guardedIntrospectionFoldsGuardMiddleware() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
                @Middleware(AdminKeys.gate)
                func mountIntrospectionAt() -> String? { "/wiring" }
            }
            """
        let decl = controller(source)
        let factoryKeys: Set<String> = ["AdminKeys.gate"]

        let entry = renderBootstrapEntry(bootstrap: decl, notFoundRegistration: "", factoryKeys: factoryKeys)
        #expect(
            entry.contains(
                "let wireMVCIntrospectionResponse = try WireMVCResponse.json(graph.introspect(), status: .ok)"
            )
        )
        #expect(
            entry.contains(
                "graph._WireGlobalMiddleware_AppBootstrap.registerIntrospection(into: &builder, at: wireMVCIntrospectionPath, response: wireMVCIntrospectionResponse)"
            )
        )
        #expect(!entry.contains("WireMVC.mountIntrospection"))

        let ext = renderGlobalMiddlewareProxyExtension(bootstrap: decl, factoryKeys: factoryKeys)
        #expect(ext.diagnostics.isEmpty)
        #expect(ext.source.contains("func registerIntrospection<Builder: HTTPServerRouteBuilder>("))
        #expect(
            ext.source.contains(
                "self._wireFactory_AdminKeys_gate.create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
            )
        )
        #expect(ext.source.contains("try await response.send(on: responseSender)"))
    }

    /// No guard → the proxy has no `registerIntrospection` (the unguarded mount uses `WireMVC.mountIntrospection`).
    @Test func unguardedIntrospectionOmitsRegisterIntrospection() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
                func mountIntrospectionAt() -> String? { "/wiring" }
            }
            """
        let ext = renderGlobalMiddlewareProxyExtension(bootstrap: controller(source), factoryKeys: [])
        #expect(!ext.source.contains("registerIntrospection"))
    }

    /// M5.5 Phase 5: the global-middleware proxy's `wrapGlobalMiddleware<Handler>` folds the Bootstrap's
    /// factory `@Middleware`s around the router via `GlobalMiddlewareHandler`, each `.create`d at the
    /// handler's box types. Two compose in written order.
    @Test func globalMiddlewareProxyWrapsRouterWithFactories() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            @Middleware(LoggingKeys.accessLog)
            @Middleware(LoggingKeys.requestID)
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let rendered = renderGlobalMiddlewareProxyExtension(
            bootstrap: controller(source),
            factoryKeys: ["LoggingKeys.accessLog", "LoggingKeys.requestID"]
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("extension _WireGlobalMiddleware_AppBootstrap {"))
        #expect(
            rendered.source.contains("func wrapGlobalMiddleware<Handler: HTTPServerRequestHandler>(_ inner: Handler)")
        )
        #expect(rendered.source.contains("GlobalMiddlewareHandler(inner: inner, chain: wireCompose {"))
        #expect(
            rendered.source.contains(
                "self._wireFactory_LoggingKeys_accessLog.create(Handler.RequestContext.self, Handler.Reader.self, Handler.ResponseSender.self)"
            )
        )
        #expect(
            rendered.source.contains(
                "self._wireFactory_LoggingKeys_requestID.create(Handler.RequestContext.self, Handler.Reader.self, Handler.ResponseSender.self)"
            )
        )
    }

    /// No global `@Middleware` → the proxy's `wrapGlobalMiddleware` degrades to identity (`inner`), so the
    /// `@main` calls it uniformly. No `GlobalMiddlewareHandler`.
    @Test func globalMiddlewareProxyIdentityWhenEmpty() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let rendered = renderGlobalMiddlewareProxyExtension(bootstrap: controller(source), factoryKeys: [])
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("func wrapGlobalMiddleware<Handler: HTTPServerRequestHandler>"))
        #expect(!rendered.source.contains("GlobalMiddlewareHandler"))
    }

    /// A by-type (or keyed-binding) global middleware is diagnosed — only the factory form composes in the
    /// non-transforming generic wrap. The fold degrades to identity (nothing valid to compose).
    @Test func globalMiddlewareByTypeFormIsDiagnosed() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            @Middleware(AccessLog.self)
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let rendered = renderGlobalMiddlewareProxyExtension(bootstrap: controller(source), factoryKeys: [])
        #expect(rendered.diagnostics.count == 1)
        #expect(!rendered.source.contains("GlobalMiddlewareHandler"))
        if case .globalMiddlewareUnsupportedArgument(let reference) = rendered.diagnostics.first?.message {
            #expect(reference == "AccessLog.self")
        } else {
            Issue.record("expected globalMiddlewareUnsupportedArgument")
        }
    }

    /// A non-`throws` `createServer` drops the `try` on its call — the entry mirrors the factory's effect.
    @Test func bootstrapEntryOmitsTryForNonThrowingCreateServer() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() -> NIOHTTPServer { fatalError() }
            }
            """
        #expect(
            renderBootstrapEntry(bootstrap: controller(source), notFoundRegistration: "", factoryKeys: [])
                .contains("let server = bootstrap.createServer()")
        )
    }

    /// End to end: `generateRouteContributors` finds `@WireMVCBootstrap`, emits the `@main` entry, and
    /// adds `import Wire` (the entry calls `Wire.bootstrap()`). Default (no `testEntry`) is the program
    /// consumer: the `@main` is emitted and the `.wiremvc()` suite-trait factory (and its `WireMVCTesting`/
    /// `Testing` imports) is NOT — a production binary must not link the test client.
    @Test func generateEmitsBootstrapEntryAndWireImport() {
        let source = """
            import WireMVC
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let rendered = generateRouteContributors(files: [("App.swift", source)])
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("struct _WireMVCBootstrapEntry {"))
        #expect(rendered.source.contains("let bootstrap = graph.appBootstrap"))
        #expect(rendered.source.contains("import Wire\n"))
        // The gate is closed by default: no test entry, no `WireMVCTesting`/`Testing` import.
        #expect(!rendered.source.contains("static func wiremvc()"))
        #expect(!rendered.source.contains("import WireMVCTesting"))
        #expect(!rendered.source.contains("import Testing"))
    }

    /// A test consumer (`testEntry: true`) is the mirror image: the `.wiremvc()` suite-trait factory (and its
    /// `WireMVCTesting` + `Testing` imports) is emitted, and the `@main` is NOT — a `@main` can't live in a
    /// test bundle. `extraImports` become `import` lines so the emitted factory can name the re-composed app's types.
    @Test func generateEmitsTestServerEntryUnderTestEntryGate() {
        let source = """
            import WireMVC
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let rendered = generateRouteContributors(
            files: [("App.swift", source)],
            testEntry: true,
            extraImports: ["WireMVCBootstrapExample"]
        )
        #expect(rendered.diagnostics.isEmpty)
        // The test entry replaces the `@main`.
        #expect(!rendered.source.contains("@main"))
        #expect(!rendered.source.contains("struct _WireMVCBootstrapEntry {"))
        #expect(rendered.source.contains("extension SuiteTrait where Self == WireMVCSuiteTrait {"))
        #expect(rendered.source.contains("static func wiremvc<WireMVCTestServerType: HTTPServer>("))
        #expect(rendered.source.contains("_ mode: WireMVCTestMode<WireMVCTestServerType>,"))
        #expect(rendered.source.contains("WireMVCSuiteTrait { runTests in"))
        #expect(
            rendered.source.contains(
                "try await WireMVCTesting.runSuite(mode, on: server, handler: wireMVCServed, services: wireMVCServices, servicePolicy: services, runTests: runTests)"
            )
        )
        #expect(rendered.source.contains("import WireMVCTesting\n"))
        #expect(rendered.source.contains("import Testing\n"))
        #expect(rendered.source.contains("import WireMVCBootstrapExample\n"))
    }

    /// M5.5 Phase 3: the `@WireMVCBootstrap` composition root's `@ErrorResponse` is the global default
    /// tier — folded into every route's terminal, even a route (and controller) that declares no local
    /// `@ErrorResponse`. Read once from the Bootstrap; consulted after route/controller, before the 500.
    @Test func globalErrorResponseFoldsIntoEveryRoute() {
        let bootstrap = """
            @Singleton
            @WireMVCBootstrap
            @ErrorResponse(TenantMissing.self, .badRequest)
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            }
            """
        let controller = """
            @Singleton
            @Controller("/things")
            struct ThingsController {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Thing { fatalError() }
            }
            """
        let rendered = generateRouteContributors(
            files: [("Bootstrap.swift", bootstrap), ("Things.swift", controller)]
        )
        #expect(rendered.diagnostics.isEmpty)
        // The route has no local map, but the Bootstrap's global tier folds into its `catch`, ahead of
        // the binding-error built-in.
        #expect(
            rendered.source.contains("(wireMVCError is TenantMissing ? WireMVCOutcome.status(.badRequest) : nil)")
        )
    }

    /// M5.5 Phase 4: a `@NotFound @RawRoute` method on the Bootstrap becomes the fallback — the generated
    /// `@main` registers it via `registerNotFound`, dispatching through the `bootstrap` local (DI-capable).
    @Test func notFoundHandlerRegistersAsFallback() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
                @NotFound
                @RawRoute
                func handleNotFound<Sender: HTTPResponseSender & ~Copyable>(
                    request: HTTPRequest,
                    responseSender: consuming sending Sender
                ) async throws where Sender.Writer: ~Copyable { fatalError() }
            }
            """
        let rendered = generateRouteContributors(files: [("App.swift", source)])
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("builder.registerNotFound"))
        #expect(
            rendered.source.contains(
                "try await bootstrap.handleNotFound(request: request, responseSender: responseSender)"
            )
        )
    }

    /// A `@NotFound` handler that isn't `@RawRoute` is diagnosed — there's no matched route to
    /// decode/encode against, so the fallback must write the response directly.
    @Test func notFoundHandlerMustBeRaw() {
        let source = """
            @Singleton
            @WireMVCBootstrap
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
                @NotFound
                @JSONResponse
                func handleNotFound() -> Greeting { fatalError() }
            }
            """
        let rendered = generateRouteContributors(files: [("App.swift", source)])
        #expect(
            rendered.diagnostics.contains { if case .notFoundNotRaw = $0.message { return true } else { return false } }
        )
    }

    @Test func scopedControllerConstructsPerRequestViaScopeEntry() {
        // A `@Scoped(seed:)` controller is a bridge proxy: its witness constructs the controller fresh
        // per request from the proxy's `_wireEnterScope` thunk (seeded by the request), then dispatches
        // on that local — never the held `_wireSubject` (a bridge proxy has none).
        let source = """
            @Scoped(seed: HTTPRequest.self)
            @Controller("/sessions")
            struct Sessions {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Session {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/sessions",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "let (wireMVCController, wireMVCScopeTeardown) = try await self._wireEnterScope(request)"
            )
        )
        // The scope's teardown runs on every exit via an async defer (M5.4.5); BasicFormat may reflow the block.
        #expect(rendered.source.contains("defer {"))
        #expect(rendered.source.contains("_ = await wireMVCScopeTeardown()"))
        #expect(rendered.source.contains("try await wireMVCController.get(id: id)"))
        #expect(!rendered.source.contains("_wireSubject"))
    }

    @Test func middlewareFactoryKeyFold() {
        let source = """
            @Controller("/x")
            @Middleware(Keys.session)
            struct C {
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/x",
            factoryKeys: ["Keys.session"]
        )
        #expect(
            rendered.source == """
                extension _WireRouteContributor_C: RouteContributor {
                    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .get, path: "/x/y") { request, requestContext, _, reader, responseSender in
                            let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
                            let wireMVCChain = wireCompose {
                                self._wireFactory_Keys_session.create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)
                            }
                            try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                                try await wireMVCFinalBox.withPendingContents { _, _, _, responseSender in
                                let wireMVCOutcome: WireMVCOutcome
                                do {
                                    try await self._wireSubject.f()
                                    wireMVCOutcome = .status(.noContent)
                                } catch {
                                    wireMVCOutcome = WireMVCOutcome.status(.internalServerError)
                                }
                                try await wireMVCOutcome.send(on: responseSender)
                                }
                            }
                        }
                    }
                }
                """
        )
    }

    /// Every parameter-binding branch on one route — `@Path`/`@Query`/`@Header`/`@JSONBody`, an optional
    /// (`bindOptional`), a defaulted (`bindOptional(...) ?? default`), body collection, and a custom
    /// response status.
    @Test func allParameterBindingShapes() {
        let source = """
            @Controller("/search")
            struct Search {
                @Post("/{scope}")
                @JSONResponse(status: .created)
                func run(
                    @Path scope: String,
                    @Query("q") query: String,
                    @Query limit: Int?,
                    @Header("X-Trace") trace: String = "none",
                    @JSONBody filter: Filter
                ) async throws -> Results {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/search",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source == """
                extension _WireRouteContributor_Search: RouteContributor {
                    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
                    where
                        Builder.RequestContext: ~Copyable,
                        Builder.Reader: ~Copyable,
                        Builder.ResponseSender: ~Copyable,
                        Builder.ResponseSender.Writer: ~Copyable
                    {
                        builder.register(method: .post, path: "/search/{scope}") { request, _, pathParameters, reader, responseSender in
                            let wireMVCOutcome: WireMVCOutcome
                            do {
                                let requestBody = try await WireMVCRequest.collectBody(reader)
                                let scope = try await Path<String>.bind(name: "scope", request: request, pathParameters: pathParameters, body: requestBody)
                                let query = try await Query<String>.bind(name: "q", request: request, pathParameters: pathParameters, body: requestBody)
                                let limit = try await Query<Int>.bindOptional(name: "limit", request: request, pathParameters: pathParameters, body: requestBody)
                                let trace = try await Header<String>.bindOptional(name: "X-Trace", request: request, pathParameters: pathParameters, body: requestBody) ?? "none"
                                let filter = try await JSONBody<Filter>.bind(name: "filter", request: request, pathParameters: pathParameters, body: requestBody)
                                wireMVCOutcome = try WireMVCResponse.json(try await self._wireSubject.run(scope: scope, query: query, limit: limit, trace: trace, filter: filter), status: .created)
                            } catch let wireMVCError {
                                wireMVCOutcome = (
                                    (wireMVCError as? WireMVCBindingError).map {
                                        WireMVCOutcome.status($0.status)
                                    }
                                    ?? WireMVCOutcome.status(.internalServerError)
                                )
                            }
                            try await wireMVCOutcome.send(on: responseSender)
                        }
                    }
                }
                """
        )
    }

    // MARK: - @ErrorResponse (route error handling)

    /// A controller-scope `(E.self, .status)` shorthand covers every route: the terminal `catch`
    /// consults it (folding the binding-error built-in and re-throwing an unmapped error to the framework).
    @Test func controllerScopeStatusShorthandCoversRoute() {
        let source = """
            @Controller("/users")
            @ErrorResponse(NotFound.self, .notFound)
            struct Users {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        // No catch-all → the mapping chain, ending in the built-in 500 terminal (never a rethrow).
        #expect(rendered.source.contains("} catch let wireMVCError {"))
        #expect(rendered.source.contains("(wireMVCError is NotFound ? WireMVCOutcome.status(.notFound) : nil)"))
        // The binding-error built-in is folded in (BasicFormat may reflow the trailing closure).
        #expect(rendered.source.contains("(wireMVCError as? WireMVCBindingError).map"))
        #expect(rendered.source.contains("WireMVCOutcome.status($0.status)"))
        // M5.5 Phase 2: the terminal owns the 500 — an unmapped throw is written, never re-thrown.
        #expect(rendered.source.contains("?? WireMVCOutcome.status(.internalServerError)"))
        #expect(!rendered.source.contains("throw wireMVCError"))
        // The shipped binding-only catch is gone once @ErrorResponse is present.
        #expect(!rendered.source.contains("catch let wireMVCBindingError as WireMVCBindingError"))
    }

    /// A route-scope entry is consulted before the controller entry (route overrides): a route closure
    /// mapping is folded ahead of the controller's status shorthand.
    @Test func routeClosureOverridesController() {
        let source = """
            @Controller("/users")
            @ErrorResponse(NotFound.self, .notFound)
            struct Users {
                @Get("/{id}")
                @JSONResponse
                @ErrorResponse({ (e: NotFound) in .status(.gone) })
                func get(@Path id: String) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        let generated = rendered.source
        // Route closure is folded (through the helper), consulted before the controller's status shorthand.
        let routeCall = generated.range(of: "wireMVCRespond(to: wireMVCError, ({ (e: NotFound) in")
        let controllerStatus = generated.range(
            of: "(wireMVCError is NotFound ? WireMVCOutcome.status(.notFound) : nil)"
        )
        #expect(routeCall != nil && controllerStatus != nil)
        #expect(routeCall!.lowerBound < controllerStatus!.lowerBound)
        // A closure mapping throws through the helper, so the chain is `try`-prefixed.
        #expect(generated.contains("= try"))
    }

    /// An inline typed-parameter closure is spliced and applied through `wireMVCRespond`.
    @Test func inlineClosureMapping() {
        let source = """
            @Controller("/users")
            struct Users {
                @Post
                @JSONResponse(status: .created)
                @ErrorResponse({ (e: ValidationError) in try .json(Problem(e.message), status: .unprocessableContent) })
                func create(@JSONBody new: NewUser) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("wireMVCRespond(to: wireMVCError, ({ (e: ValidationError) in"))
    }

    /// A `Swift.Error` catch-all closure folds through `wireMVCRespondAny` as the non-optional terminal,
    /// so the assignment is direct (no guarded `else { throw }`).
    @Test func catchAllClosureIsTerminal() {
        let source = """
            @Controller("/users")
            @ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })
            struct Users {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> User {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("wireMVCRespondAny(to: wireMVCError, ({ (e: Swift.Error) in"))
        #expect(rendered.source.contains("wireMVCOutcome = try ("))
        // A catch-all matches everything, so nothing is re-thrown from the terminal.
        #expect(!rendered.source.contains("throw wireMVCError"))
    }

    /// A route with no bindings still gets a `do`/`catch` when it declares an `@ErrorResponse`, so a
    /// handler throw is mapped (the shipped no-binds fast path has no `catch`).
    @Test func noBindsRouteGainsCatchForErrorResponse() {
        let source = """
            @Controller("/users")
            struct Users {
                @Get
                @JSONResponse
                @ErrorResponse(NotFound.self, .notFound)
                func list() async throws -> [User] {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("do {"))
        #expect(rendered.source.contains("} catch let wireMVCError {"))
        // No bindings → the binding-error built-in is not folded in.
        #expect(!rendered.source.contains("as? WireMVCBindingError"))
    }

    /// A `@Scoped(seed:)` controller with an `@ErrorResponse` moves the scope-entry construction *inside*
    /// the `do`, so a throwing request-scoped binding maps like a handler throw.
    @Test func scopedControllerScopeEntryInsideDoWhenMapped() {
        let source = """
            @Scoped(seed: HTTPRequest.self)
            @Controller("/me")
            @ErrorResponse(Unauthenticated.self, .unauthorized)
            struct Me {
                @Get
                @JSONResponse
                func me() async throws -> Profile {
                    fatalError()
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/me",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        let generated = rendered.source
        let doOpen = generated.range(of: "do {")
        let scopeEntry = generated.range(
            of: "let (wireMVCController, wireMVCScopeTeardown) = try await self._wireEnterScope(request)"
        )
        #expect(doOpen != nil && scopeEntry != nil)
        #expect(doOpen!.lowerBound < scopeEntry!.lowerBound)  // scope entry is inside the do
    }

    // MARK: - @ErrorResponse diagnostics

    @Test func untypedClosureParameterIsDiagnosed() {
        let source = """
            @Controller("/users")
            struct Users {
                @Get @JSONResponse
                @ErrorResponse({ e in .status(.internalServerError) })
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseClosureNeedsTypedParameter = $0.message { return true } else { return false }
            }
        )
    }

    @Test func unresolvedStaticReferenceIsDiagnosed() {
        let source = """
            @Controller("/users")
            struct Users {
                @Get @JSONResponse
                @ErrorResponse(SharedErrors.handleNotFound)
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseUnresolvedMapping = $0.message { return true } else { return false }
            }
        )
    }

    @Test func duplicateErrorTypeAtOneScopeIsDiagnosed() {
        let source = """
            @Controller("/users")
            @ErrorResponse(NotFound.self, .notFound)
            @ErrorResponse(NotFound.self, .gone)
            struct Users {
                @Get @JSONResponse
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseDuplicateType = $0.message { return true } else { return false }
            }
        )
    }

    @Test func catchAllNotLastIsDiagnosed() {
        let source = """
            @Controller("/users")
            @ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })
            @ErrorResponse(NotFound.self, .notFound)
            struct Users {
                @Get @JSONResponse
                func list() async throws -> [User] { fatalError() }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .errorResponseCatchAllNotLast = $0.message { return true } else { return false }
            }
        )
    }

    // MARK: - @Middleware classification (factory / by-type / by-key)

    /// Controller-scope wraps outer, route-scope inner. `.self` arguments are graph bindings injected by
    /// type — folded as `self._wire<Type>`, never constructed inline.
    @Test func controllerAndRouteByTypeMiddlewareOrder() {
        let source = """
            @Controller("/x")
            @Middleware(ControllerGate.self)
            struct Gated {
                @Middleware(RouteGate.self)
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/x",
            factoryKeys: []
        )
        #expect(rendered.source.contains("self._wireControllerGate"))
        #expect(rendered.source.contains("self._wireRouteGate"))
        let controllerIndex = rendered.source.range(of: "self._wireControllerGate")
        let routeIndex = rendered.source.range(of: "self._wireRouteGate")
        #expect(controllerIndex != nil && routeIndex != nil)
        #expect(controllerIndex!.lowerBound < routeIndex!.lowerBound)
        #expect(rendered.source.contains("try await self._wireSubject.f()"))
    }

    /// A key that is *not* a `@Factory` template is a graph binding — folded as `self._wire<sanitised key>`,
    /// distinct from the factory `create` call.
    @Test func middlewareBindingKeyFold() {
        let source = """
            @Controller("/x")
            @Middleware(Gates.primary)
            struct C {
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/x",
            factoryKeys: []
        )
        #expect(rendered.source.contains("self._wireGates_primary"))
        #expect(!rendered.source.contains("_wireFactory_"))
        #expect(!rendered.source.contains(".create("))
    }

    @Test func rawRoutePassthrough() {
        let source = """
            @Controller("/users")
            struct Raw {
                @Get("/events")
                @RawRoute
                func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
                    responseSender: consuming sending Sender
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "builder.register(method: .get, path: \"/users/events\") { _, _, _, _, responseSender in"
            )
        )
        #expect(rendered.source.contains("try await self._wireSubject.events(responseSender: responseSender)"))
    }

    /// `@RawRoute(.responseSender)` binds the parameter to the register closure's `responseSender` by the
    /// explicit role — regardless of the parameter's *type*, so a transformed sender (a middleware's
    /// `MultiPartSender<S>`) that constraint-inference can't name still binds.
    @Test func rawRouteExplicitResponseSenderRole() {
        let source = """
            @Controller("/uploads")
            struct Uploads {
                @Post("/multipart")
                @RawRoute(.responseSender)
                func upload<Sender: HTTPResponseSender & ~Copyable>(
                    responseSender: consuming MultiPartSender<Sender>
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/uploads",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "builder.register(method: .post, path: \"/uploads/multipart\") { _, _, _, _, responseSender in"
            )
        )
        #expect(rendered.source.contains("try await self._wireSubject.upload(responseSender: responseSender)"))
    }

    /// Multiple explicit roles bind positionally, in order.
    @Test func rawRouteExplicitRolesBindPositionally() {
        let source = """
            @Controller("/uploads")
            struct Uploads {
                @Post("/multipart")
                @RawRoute(.request, .responseSender)
                func upload<Sender: HTTPResponseSender & ~Copyable>(
                    _ request: HTTPRequest,
                    responseSender: consuming MultiPartSender<Sender>
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/uploads",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.isEmpty)
        // request is used (not `_`) since a role names it; the call binds both by their labels.
        #expect(
            rendered.source.contains(
                "builder.register(method: .post, path: \"/uploads/multipart\") { request, _, _, _, responseSender in"
            )
        )
        #expect(rendered.source.contains("try await self._wireSubject.upload(request, responseSender: responseSender)"))
    }

    @Test func rawRouteRoleCountMismatchIsDiagnosed() {
        let source = """
            @Controller("/uploads")
            struct Uploads {
                @Post("/multipart")
                @RawRoute(.responseSender)
                func upload<Sender: HTTPResponseSender & ~Copyable>(
                    _ request: HTTPRequest,
                    responseSender: consuming MultiPartSender<Sender>
                ) async throws where Sender.Writer: ~Copyable {
                }
            }
            """
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/uploads",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.contains {
                if case .rawRouteRoleCountMismatch = $0.message { return true } else { return false }
            }
        )
    }

    // MARK: - Subject-accessor seam

    /// The witness varies only by the subject accessor — swapping `_wireSubject` for another field leaves
    /// the register/bind/encode/fold logic identical (it comes from the one generator, parameterised).
    @Test func witnessVariesOnlyBySubjectAccessor() {
        let source = """
            @Controller("/todos")
            struct Todos {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Todo {
                    fatalError()
                }
            }
            """
        let proxyWitness = witnessBody(source, pathPrefix: "/todos", subjectAccessor: "_wireSubject")
        let otherWitness = witnessBody(source, pathPrefix: "/todos", subjectAccessor: "controller")
        #expect(proxyWitness.replacingOccurrences(of: "self._wireSubject", with: "self.controller") == otherWitness)
    }

    @Test func subjectAccessorIsTheStructuralHalfContract() {
        // Meets WireGen's `_wireSubject` field (WireGenCore.contributorProxySubjectFieldName).
        #expect(contributorProxySubjectAccessor == "_wireSubject")
    }

    // MARK: - Diagnostics (route-shape validation, anchored)

    @Test func unannotatedParameterIsDiagnosed() {
        let rendered = renderRouteContributorExtension(
            controller: controller(
                """
                @Controller
                struct C {
                    @Get("/x")
                    @JSONResponse
                    func f(id: String) -> Int { 0 }
                }
                """
            ),
            pathPrefix: "",
            factoryKeys: []
        )
        #expect(rendered.diagnostics.count == 1)
        #expect(
            rendered.diagnostics.first?.message.message
                == "handler parameter 'id' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header"
        )
    }

    @Test func pathPlaceholderMismatchIsDiagnosed() {
        let rendered = renderRouteContributorExtension(
            controller: controller(
                """
                @Controller("/users")
                struct C {
                    @Get
                    @JSONResponse
                    func f(@Path id: String) -> Int { 0 }
                }
                """
            ),
            pathPrefix: "/users",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.first?.message.message
                == "@Path 'id' has no matching '{id}' placeholder in the route path \"/users\""
        )
    }

    @Test func rawRouteMissingSenderIsDiagnosed() {
        let rendered = renderRouteContributorExtension(
            controller: controller(
                """
                @Controller
                struct C {
                    @Get("/x")
                    @RawRoute
                    func f(_ request: HTTPRequest) async throws {
                    }
                }
                """
            ),
            pathPrefix: "",
            factoryKeys: []
        )
        #expect(
            rendered.diagnostics.first?.message.message
                == "@RawRoute handler 'f' must take the response sender (a parameter generic over HTTPResponseSender, or bound via @RawRoute(.responseSender)) to write its response"
        )
    }

    // MARK: - File-level generation (the tool's core)

    @Test func generatesSortedExtensionsWithImports() {
        let result = generateRouteContributors(files: [
            (
                "Controllers.swift",
                """
                import Domain

                @Controller("/b")
                struct Beta {
                    @Get @JSONResponse func g() -> Int { 0 }
                }

                @Controller("/a")
                struct Alpha {
                    @Get @JSONResponse func g() -> Int { 0 }
                }
                """
            )
        ])
        #expect(result.diagnostics.isEmpty)
        // Header + propagated import + WireMVC import.
        #expect(result.source.hasPrefix("// Generated by WireMVCRouteGen — do not edit."))
        #expect(result.source.contains("import Domain"))
        #expect(result.source.contains("import WireMVC"))
        // Extensions emitted for both, sorted by controller name (Alpha before Beta).
        let alpha = result.source.range(of: "extension _WireRouteContributor_Alpha")
        let beta = result.source.range(of: "extension _WireRouteContributor_Beta")
        #expect(alpha != nil && beta != nil)
        #expect(alpha!.lowerBound < beta!.lowerBound)
    }

    /// A controller in one file may fold a `@Factory` template declared in another: the tool collects
    /// factory keys across every input source before folding any witness, so the cross-file `@Middleware`
    /// still classifies as a factory (its `create` call), not a graph binding.
    @Test func factoryKeyDeclaredInAnotherFileIsClassifiedAsFactory() {
        let result = generateRouteContributors(files: [
            (
                "Middleware.swift",
                """
                @Factory(Keys.session)
                @MiddlewareFactory
                struct SessionMiddleware {}
                """
            ),
            (
                "Controller.swift",
                """
                @Controller("/x")
                @Middleware(Keys.session)
                struct C {
                    @Get @ResponseStatus(.noContent) func f() async throws {}
                }
                """
            ),
        ])
        #expect(result.diagnostics.isEmpty)
        #expect(
            result.source.contains(
                "self._wireFactory_Keys_session.create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
            )
        )
    }

    @Test func fileWithNoControllersEmitsHeaderOnly() {
        let result = generateRouteContributors(files: [("Empty.swift", "struct NotAController {}")])
        #expect(result.diagnostics.isEmpty)
        #expect(!result.source.contains("extension"))
        #expect(result.source.contains("import WireMVC"))
    }

    @Test func fileLevelDiagnosticCarriesLocation() {
        let result = generateRouteContributors(files: [
            (
                "Bad.swift",
                """
                @Controller
                struct C {
                    @Get("/x")
                    @JSONResponse
                    func f(id: String) -> Int { 0 }
                }
                """
            )
        ])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.location.line == 5)
    }

    // MARK: - Keyed test harness (H2.2b)

    /// The names the keyed harness derives from a `TestingKey` — the reference, variant, doubles struct, and
    /// the `@BindType` slot/mock/field — must match WireGen's blind, so pin them.
    @Test func testingKeyDiscoveryDerivesNames() {
        let file = Parser.parse(
            source: """
                enum Suite {
                    @BindType(Repo.self, MockRepo.self)
                    static let setup = TestingKey()
                }
                """
        )
        let key = discoverTestingKey(in: [file])
        #expect(key?.keyReference == "Suite.setup")
        #expect(key?.variantName == "Suite_setup")
        #expect(key?.doublesTypeName == "_Suite_setupDoubles")
        #expect(key?.harnessEnumName == "_WireMVCKeyed_Suite_setup")
        #expect(key?.substitutions.first?.mockType == "MockRepo")
        #expect(key?.substitutions.first?.fieldName == "repo")
    }

    /// The keyed `@BindType(K.member, Mock.self)` form: the doubles field name derives from the slot type
    /// (recovered from the `BindingKey<Slot>` declaration) plus the key, matching WireGen's
    /// `identifierName(forType:key:)` — `(any PrefsBackend, "PrefsKeys.primary")` → `prefsBackendKeyedPrefsKeysPrimary`.
    @Test func testingKeyDiscoveryReadsKeyedBindTypeForm() {
        let file = Parser.parse(
            source: """
                enum PrefsKeys { static let primary = BindingKey<any PrefsBackend>() }
                enum Suite {
                    @BindType(PrefsKeys.primary, MockPrefs.self)
                    static let setup = TestingKey()
                }
                """
        )
        let key = discoverTestingKey(in: [file])
        #expect(key?.substitutions.first?.fieldName == "prefsBackendKeyedPrefsKeysPrimary")
        #expect(key?.substitutions.first?.mockType == "MockPrefs")
    }

    /// A keyed `@BindType` whose `BindingKey` is declared on an `extension` of the slot type — the key
    /// reference reconstructs through the extended type (`AppConfig.alternate`).
    @Test func testingKeyDiscoveryResolvesBindingKeyOnExtension() {
        let file = Parser.parse(
            source: """
                extension AppConfig { static let alternate = BindingKey<AppConfig>() }
                enum Suite {
                    @BindType(AppConfig.alternate, MockConfig.self)
                    static let setup = TestingKey()
                }
                """
        )
        let key = discoverTestingKey(in: [file])
        #expect(key?.substitutions.first?.fieldName == "appConfigKeyedAppConfigAlternate")
    }

    /// A `TestingKey` `@BindType`ing a slot a `@Scoped(seed:)` controller injects, in a test consumer, makes
    /// that controller's route dispatch doubles-aware and emits the keyed factory + statics + `withBindValues`.
    @Test func keyedHarnessEmitsDoublesAwareDispatchAndFactory() {
        let rendered = generateRouteContributors(files: [("App.swift", keyedHarnessFixture)], testEntry: true)
        #expect(rendered.diagnostics.isEmpty)
        // The keyed dispatch lives on a variant witness emitted on the variant proxy type: correlate the
        // request's doubles from the per-key store (else 500), then enter request scope via the variant proxy
        // (`self`) — no production branch.
        #expect(
            rendered.source.contains("extension _Binds_mock_WireRouteContributor_NotesController: RouteContributor")
        )
        #expect(rendered.source.contains("_WireMVCKeyed_Binds_mock.doubles.value(for: wireMVCCorrelationID)"))
        #expect(rendered.source.contains("try await self._wireEnterScope(request, wireMVCDoubles)"))
        #expect(!rendered.source.contains(".get()"))
        #expect(rendered.source.contains("try await WireMVCOutcome.body("))
        #expect(rendered.source.contains("under key Binds.mock"))
        // The keyed dispatch retires the @TaskLocal proxy box, the production `if let` branch, and `.withValue`.
        #expect(!rendered.source.contains("@TaskLocal"))
        #expect(!rendered.source.contains("if let wireMVCVariantProxy"))
        #expect(!rendered.source.contains(".withValue("))
        // The production witness stays keyless — the plain scope entry, no doubles.
        #expect(rendered.source.contains("try await self._wireEnterScope(request)"))
        // Statics: the doubles store (no proxy holder) + typed withBindValues + the keyed factory.
        #expect(rendered.source.contains("enum _WireMVCKeyed_Binds_mock {"))
        #expect(rendered.source.contains("static let doubles = TestBindStore<_Binds_mockDoubles>()"))
        #expect(rendered.source.contains("func withBindValues<R>(noteBackend: MockNoteBackend,"))
        #expect(
            rendered.source.contains(
                "_ key: TestingKey, _ mode: WireMVCTestMode<WireMVCTestServerType>,"
            )
        )
        // The keyed factory bootstraps the variant graph and hand-registers each variant proxy's routes.
        #expect(rendered.source.contains("let graph = try await Wire.bootstrapBinds_mock()"))
        #expect(
            rendered.source.contains(
                "let wireMVCVariantProxy_NotesController = Wire.bootstrapBinds_mock_NotesControllerContributor(wireGraph: graph)"
            )
        )
        #expect(
            rendered.source.contains("try wireMVCVariantProxy_NotesController.registerWireRoutes(on: &builder)")
        )
    }

    /// The same fixture as a program consumer (`testEntry: false`) — no keyed harness is discovered, so the
    /// scoped controller's dispatch is the byte-for-byte production scope entry, with no doubles-aware branch.
    @Test func productionDispatchIsUnchangedWithoutTestEntry() {
        let rendered = generateRouteContributors(files: [("App.swift", keyedHarnessFixture)], testEntry: false)
        #expect(
            rendered.source.contains(
                "let (wireMVCController, wireMVCScopeTeardown) = try await self._wireEnterScope(request)"
            )
        )
        #expect(!rendered.source.contains("wireMVCVariantProxy"))
        #expect(!rendered.source.contains("_WireMVCKeyed_"))
        #expect(!rendered.source.contains("wiremvc(_ key:"))
    }

    /// Key every controller: under a `TestingKey`, EVERY `@Scoped(seed:)` controller is a keyed subject —
    /// even one that injects nothing the key touches (a mock-ignoring route). No selection heuristic. An
    /// app-scoped controller is never keyed (it has no per-request scope entry).
    @Test func everyScopedControllerIsKeyedRegardlessOfInjection() {
        let source = """
            @Singleton @WireMVCBootstrap struct AppBootstrap {}

            @Scoped(seed: HTTPRequest.self)
            @Controller("/ping")
            struct PingController {
                @Inject init(request: HTTPRequest) {}
                @Get("/")
                @JSONResponse
                func ping() -> Note { fatalError() }
            }

            @Singleton
            @Controller("/health")
            struct HealthController {
                @Inject init() {}
                @Get("/")
                @JSONResponse
                func health() -> Note { fatalError() }
            }

            enum Binds {
                @BindType(NoteBackend.self, MockNoteBackend.self)
                static let mock = TestingKey()
            }
            """
        let rendered = generateRouteContributors(files: [("App.swift", source)], testEntry: true)
        #expect(rendered.diagnostics.isEmpty)
        // The mock-ignoring seed-scoped `PingController` is keyed: a variant witness on its variant proxy type,
        // and the factory hand-registers the variant proxy the facade swift-wire emits for every seed-scoped subject.
        #expect(
            rendered.source.contains("extension _Binds_mock_WireRouteContributor_PingController: RouteContributor")
        )
        #expect(rendered.source.contains("Wire.bootstrapBinds_mock_PingControllerContributor(wireGraph: graph)"))
        #expect(
            rendered.source.contains("try wireMVCVariantProxy_PingController.registerWireRoutes(on: &builder)")
        )
        // The app-scoped `HealthController` is never keyed — no per-request scope entry to vary.
        #expect(!rendered.source.contains("_Binds_mock_WireRouteContributor_HealthController"))
        #expect(!rendered.source.contains("wireMVCVariantProxy_HealthController"))
    }

    /// A `@WireMVCBootstrap` root, a `@Scoped(seed:)` controller injecting the `@BindType`d slot, and the key.
    private let keyedHarnessFixture = """
        @Singleton
        @WireMVCBootstrap
        struct AppBootstrap {}

        @Scoped(seed: HTTPRequest.self)
        @Controller("/notes")
        struct NotesController {
            @Inject var backend: any NoteBackend
            @Get("/{id}")
            @JSONResponse
            func note(@Path id: String) -> Note { fatalError() }
        }

        enum Binds {
            @BindType(NoteBackend.self, MockNoteBackend.self)
            static let mock = TestingKey()
        }
        """

    /// An app-scoped `@TestScopable` controller carrying a **mock-consuming** `@Middleware` factory (`Audit`
    /// `@Inject`s the `@BindType`'d `NoteBackend`) — the Phase-B shape. Its variant witness must thread the
    /// per-request doubles to the factory's `create`.
    private let mockConsumingFactoryFixture = """
        @Singleton
        @WireMVCBootstrap
        struct AppBootstrap {}

        enum AuditKeys { static let factory = FactoryKey() }

        @Factory(AuditKeys.factory)
        @MiddlewareFactory
        struct Audit {
            @Inject var backend: any NoteBackend
        }

        @TestScopable
        @Singleton
        @Controller("/summary")
        @Middleware(AuditKeys.factory)
        struct SummaryController {
            @Inject var backend: any NoteBackend
            @Get("/{id}")
            @JSONResponse
            func summary(@Path id: String) -> Note { fatalError() }
        }

        enum Binds {
            @BindType(NoteBackend.self, MockNoteBackend.self)
            static let mock = TestingKey()
        }
        """

    /// Phase B: a mock-consuming lifted `@Factory` (`Audit`, which `@Inject`s the mocked `NoteBackend`) folds
    /// on the app-scoped variant witness with the per-request doubles threaded to its `create(doubles:)` —
    /// swift-wire re-emits it as a variant factory whose mock rides the call. The production witness's fold is
    /// box-role-only, and the doubles correlation is hoisted above the fold so `wireMVCDoubles` is in scope.
    @Test func mockConsumingFactoryFoldThreadsDoublesToCreate() {
        let rendered = generateRouteContributors(files: [("App.swift", mockConsumingFactoryFixture)], testEntry: true)
        #expect(rendered.diagnostics.isEmpty)
        // The variant witness threads the per-request doubles ahead of the box-role metatypes.
        #expect(
            rendered.source.contains(
                "self._wireFactory_AuditKeys_factory.create(doubles: wireMVCDoubles, "
                    + "Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
            )
        )
        // The production witness's fold stays box-role-only — no doubles (the mock is only bound under the key).
        #expect(
            rendered.source.contains(
                "self._wireFactory_AuditKeys_factory.create("
                    + "Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
            )
        )
        // Hoist: in the variant witness the doubles bind *above* the fold, else `create(doubles:)` wouldn't
        // resolve `wireMVCDoubles`. Assert the ordering within the variant extension.
        let marker = "_Binds_mock_WireRouteContributor_SummaryController: RouteContributor"
        if let start = rendered.source.range(of: marker) {
            let variant = rendered.source[start.lowerBound...]
            let doubles = variant.range(of: "let wireMVCDoubles =")?.lowerBound
            let fold = variant.range(of: "wireCompose {")?.lowerBound
            #expect(doubles != nil && fold != nil && doubles! < fold!)
        } else {
            Issue.record("no variant witness generated for SummaryController")
        }
    }

    /// The wire-mvc-examples shapes (Phase C): a generic `@TestScopable` controller carrying a **generic**
    /// mock-consuming `@Factory` (`Audit<…, Repository: TodoRepository>`, `@Inject var repository: Repository`)
    /// and a `@RawRoute`, under a two-slot key whose source order differs from alphabetical.
    private let phaseCFixture = """
        @Singleton
        @WireMVCBootstrap
        struct AppBootstrap {}

        enum AuditKeys { static let factory = FactoryKey() }

        @Factory(AuditKeys.factory)
        @MiddlewareFactory(.responseSender, .reader, .requestContext)
        struct Audit<Sender, Reader, Ctx, Repository: TodoRepository> {
            @Inject var repository: Repository
        }

        @TestScopable
        @Singleton
        @Controller("/todos")
        @Middleware(AuditKeys.factory)
        struct TodosController<Repository: TodoRepository> {
            @Inject var repository: Repository
            @Get
            @JSONResponse
            func list() -> Note { fatalError() }
            @Get("/stream")
            @RawRoute
            func stream<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(responseSender: consuming Sender) { fatalError() }
        }

        enum Binds {
            @BindType(TodoRepository.self, MockTodoRepository.self)
            @BindType(SessionManager.self, MockSessionManager.self)
            static let mock = TestingKey()
        }
        """

    /// Issue 01 (wire-mvc half): a mock-consuming factory **generic over its injected axis** — the mocked dep is
    /// spelled as the generic param `Repository`, matched via its constraint `TodoRepository`. The variant fold
    /// threads doubles to its `create`, agreeing with swift-wire's constraint-based variant factory.
    @Test func genericMockConsumingFactoryFoldThreadsDoubles() {
        let rendered = generateRouteContributors(files: [("App.swift", phaseCFixture)], testEntry: true)
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "self._wireFactory_AuditKeys_factory.create(doubles: wireMVCDoubles, "
                    + "Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)"
            )
        )
    }

    /// Issue 09: a `@RawRoute` on a variant (seedless `@TestScopable`) witness dispatches on the reconstructed
    /// `wireMVCController` after `_wireEnterScope(wireMVCDoubles)`, not the held `_wireSubject` (which a seedless
    /// variant proxy doesn't have). The production witness keeps `self._wireSubject`.
    @Test func rawRouteOnVariantWitnessEntersSeedlessScope() {
        let rendered = generateRouteContributors(files: [("App.swift", phaseCFixture)], testEntry: true)
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("try await wireMVCController.stream(responseSender: responseSender)"))
        #expect(rendered.source.contains("try await self._wireSubject.stream(responseSender: responseSender)"))
    }

    /// Issue 08: the doubles **construction** is ordered by field name (`sessionManager` before `todoRepository`)
    /// to match WireGen's alphabetically-sorted `_<Key>Doubles` struct — even though the `@BindType` source
    /// order (and the `withBindValues` parameters) is `todoRepository` first.
    @Test func doublesConstructionMatchesAlphabeticalStructOrder() {
        let rendered = generateRouteContributors(files: [("App.swift", phaseCFixture)], testEntry: true)
        #expect(rendered.diagnostics.isEmpty)
        #expect(
            rendered.source.contains(
                "_Binds_mockDoubles(sessionManager: sessionManager, todoRepository: todoRepository)"
            )
        )
        // The user-facing parameter order stays source order (matches the @BindType declaration).
        #expect(rendered.source.contains("todoRepository: MockTodoRepository, sessionManager: MockSessionManager"))
    }
}
