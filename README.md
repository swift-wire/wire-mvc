# wire-mvc

`WireMVC` is a declarative-routing adapter for [swift-wire](https://github.com/tachyonics/swift-wire),
built on top of the [swift-http-api-proposal](https://github.com/apple/swift-http-api-proposal).
Controllers annotated `@Controller` are collated automatically, and each of their methods is either
*transformed* — request and response annotations decode the parameters and encode the result — or
marked `@RawRoute`, which exposes the proposal's own server API to the handler directly.

```swift
@Singleton
@Controller("/users")
struct UsersController {
    @Inject var repository: UserRepository

    @Get("/{id}")
    @JSONResponse
    func getUser(@Path id: String) async throws -> User { try repository.find(id) }

    @Post
    @JSONResponse(status: .created)
    func create(@JSONBody new: NewUser) async throws -> User { repository.insert(new) }

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    func delete(@Path id: String) async throws { try repository.remove(id) }

    // Untransformed: `@RawRoute` hands the handler the proposal's response sender verbatim — no
    // parameter decoding, no response encoding — and the handler writes the response itself. It is
    // generic over the sender (the route builder's associated type) and takes only the primitives it
    // needs, so a streaming or server-sent-events route needs no annotation beyond the verb.
    @Get("/events")
    @RawRoute
    func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        var body = UniqueArray<UInt8>(copying: Array("data: hello\n\n".utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
}
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/tachyonics/wire-mvc.git", branch: "main",
             traits: ["NIOHTTPServer"]),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [
            .product(name: "WireMVC", package: "wire-mvc"),
            .product(name: "Wire", package: "swift-wire"),
        ],
        plugins: [.plugin(name: "WireMVCBuildPlugin", package: "wire-mvc")]
    ),
]
```

`WireMVCBuildPlugin` runs both code generators — swift-wire's `WireGen` for the graph and this
package's `WireMVCRouteGen` for the route witnesses — so a WireMVC target applies it **instead of**
swift-wire's `WireBuildPlugin`, not alongside it. The traits decide what gets resolved:
`NIOHTTPServer` for a live server, `ServerTransport` to mount on Hummingbird or Vapor, `Elementary`
for HTML responses. All are off by default.

The easiest way to bootstrap an application is to use a `@WireMVCBootstrap` annotated struct,
which can inject other bindings from the swift-wire graph, can declare global middleware, and provides
extension points for supplying graph inputs, a configured server, a route builder, where to mount graph
introspection, and a route-not-found endpoint.

```swift
@Singleton
@WireMVCBootstrap
@Middleware(CORSMiddlewareKeys.factory)  // global: every route and the fallback alike
@Middleware(GlobalMiddleware.serveStaticFiles)
package struct AppBootstrap {
    @Inject let config: ServerConfig

    package static func prepare() throws -> AppInputs {
        let config = ConfigReader(providers: [EnvironmentVariablesProvider()])
        let level = Logger.Level(rawValue: config.string(forKey: "log.level", default: "info")) ?? .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardOutput(label: label)
            handler.logLevel = level
            return handler
        }
        return AppInputs(config: config)
    }

    package func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(
            logger: Logger(label: "SwiftHttpServerExample"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: config.host, port: config.port),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
    }

    // The package-provided `TrieRouteBuilder` is a `FinalizableHTTPServerRouteBuilder`: `WireMVC.apply`
    // registers routes onto it, and the generated entry point `finalize()`s it into the immutable
    // `FrozenTrieRouter` the server serves (build → freeze → serve).
    package func createRouteBuilder<Server: HTTPServer>(
        for server: borrowing Server
    ) -> some FinalizableHTTPServerRouteBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        TrieRouteBuilder(for: server)
    }

    package func mountIntrospectionAt() -> String? { "/wiring" }

    @NotFound
    @RawRoute
    package func noRoute<Sender: HTTPResponseSender & ~Copyable>(
        request: HTTPRequest,
        responseSender: consuming sending Sender
    ) async throws where Sender.Writer: ~Copyable {
        try await WireMVCOutcome.json(
            NoRoute(unmatched: request.path ?? "", method: request.method.rawValue),
            status: .notFound
        ).send(on: responseSender)
    }
}
```

Requires a Swift 6.4 toolchain; targets macOS 26 and Linux.

## Features

### Request-scoped controllers, middleware and error handlers

Alongside singleton-scoped controllers, wire-mvc lets you write request-scoped ones, which can inject
singleton and request-scoped bindings alike. Where an application has several request-scoped
controllers, swift-wire's compile-time reachability analysis means entering a request scope
instantiates only the bindings reachable from the controller that request actually hits.

Middleware and parameter bindings both sit between the request and the handler, and they are not
alternatives — they answer different questions.

**Middleware wraps.** It composes as a function of the request, so one middleware covers every route
in its scope: global on the composition root, controller-scope on the type, route-scope on the
method, nesting outside-in. It can transform what the route receives — enriching the request
context, replacing the reader or sender — and it can end the request before the handler runs. What
it cannot do is hand the handler a value: the handler's signature is unchanged whether a middleware
ran or not.

**A parameter binding produces a value.** It is consumed at one leaf — a single handler parameter —
and its result is that parameter's typed value, so the handler cannot run without it. A binding that
merely decodes (`@Path`, `@Query`, `@Header`, `@JSONBody`) needs nothing from the graph. One that has
to *resolve* — consulting a store, a policy, the caller the request scope authenticated — names a
request-scoped worker that does, and the worker is an ordinary binding with its own `@Inject`
members.

The distinction that matters when choosing: a middleware gate can be forgotten by the next route,
because nothing in a handler's signature records that it ran. A binding cannot, because the value it
produces is how the handler's argument comes into existence — a route taking an `AuthorizedTodo`
cannot skip the authorisation, since that check is what makes one. Reach for middleware for policy
that applies uniformly and hands nothing over; reach for a binding when the check produces something
the handler needs.

```swift
@Scoped(seed: HTTPRequest.self)
@Controller("/todos")
@Middleware(ControllerMiddleware.responseDefaults)  // controller-scope: .set + .setIfAbsent
@Middleware(ControllerMiddleware.logRequests)  // controller-scope: every route
@Middleware(ControllerMiddleware.audit)  // controller-scope, generic-with-deps, folded by factory key
@ErrorResponse(TodoNotFound.self, .notFound)  // a handler throw → 404, not the baseline 500
public struct TodosController<Repository: TodoRepository>: Sendable {
    @Inject let repository: Repository
    @Inject let logger: Logger // the logger for the current request

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    @Middleware(RouteMiddleware.requireAPIKey)  // route-scope gate — generic-with-deps, factory-lifted by key
    public func delete(@Path id: String) async throws {
        try await repository.delete(id: id)
    }
}
```

## Documentation

The user-facing documentation is a DocC catalog — build it with
`swift package generate-documentation --target WireMVC`, or read the articles under
[`Sources/WireMVC/WireMVC.docc`](Sources/WireMVC/WireMVC.docc):

- **Getting started** — adding WireMVC to a package, writing a controller, and the package traits
  that decide what gets resolved.
- **Routes** — request bindings, responses and headers, error handling, and coding.
- **Composition** — the `@WireMVCBootstrap` composition root, middleware, and request scope.
- **Running and testing** — what differs between the proposal-native runtime, Hummingbird and
  Vapor, and how to stand the real app up in a suite.

Design notes recording *why* each subsystem is shaped the way it is are in
[`Documentation/Notes`](Documentation/Notes).

## Status

Built, pre-1.0. The surface is shipped and exercised by the fixtures in this repository and by
[wire-mvc-examples](https://github.com/tachyonics/wire-mvc-examples) on three runtimes: routing,
the generated composition root, request scope, per-request logging, the testing harness, and one
routing model shared with OpenAPI operations.

The runtime differences worth knowing before you pick a host — method mismatches, percent
decoding, catch-all templates — are tabulated in the *What differs by runtime* article.

Known gaps are tracked as [issues](https://github.com/tachyonics/wire-mvc/issues).

Validated on macOS and Linux (see CI).

## Contributing

Building, testing, and the plugin type-check trap are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Related work

Vapor 5 has an experimental macro-based `@Controller` router of its own (behind
`#if MacroRouting`). The two overlap on the routing-annotation surface (controllers,
HTTP verbs, path params) but differ architecturally: Vapor centres per-request
context on the `Request` object, while WireMVC centres a DI container — so
`@Inject`/`@Singleton` dependency injection, request-scoped controllers, and
cross-runtime mounting are WireMVC concerns without a proposal-level equivalent. See
[Documentation/Notes/VaporMacroRouting-Overlap.md](Documentation/Notes/VaporMacroRouting-Overlap.md)
for the full comparison and how each relates to prior art.
