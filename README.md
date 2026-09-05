# wire-mvc

🚧 🚧 🚧 Status: experimental. Expect a lot of rough edges and public API to change without warning. Don't put it anywhere near production until further notice. 🚧 🚧 🚧

wire-mvc is a declarative-routing adapter for [swift-wire](https://github.com/swift-wire/swift-wire),
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

    @Get("/events")
    @RawRoute
    func events<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming sending Sender
    ) async throws where Sender.Writer: ~Copyable {
        var body = UniqueArray<UInt8>(copying: Array("data: hello\n\n".utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
}
```

[wire-open-api](https://github.com/swift-wire/wire-open-api) is a similar adaptor for OpenAPI routes.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/swift-wire/wire-mvc.git", branch: "main",
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
swift-wire's `WireBuildPlugin`, not alongside it.

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

@Scoped(seed: HTTPRequest.self)
@Controller("/documents")
@ErrorResponse(Unauthenticated.self, .unauthorized)  // the scope failed to build — no known principal
@ErrorResponse(AccessDenied.self, .forbidden, { $0.denial })
@ErrorResponse(DocumentNotFound.self, .notFound)
public struct DocumentsController: Sendable {
    @Get
    @JSONResponse
    public func list(@AuthorizedDocuments("read") documents: [Document]) -> [Document] {
        documents
    }
```

### Request-scoped controllers

Alongside singleton-scoped controllers, wire-mvc lets you write request-scoped ones, which can inject
singleton and request-scoped bindings alike. Where an application has several request-scoped
controllers, swift-wire's compile-time reachability analysis means entering a request scope
instantiates only the bindings reachable from the controller that request actually hits.

### Error Handlers

Error handlers can be specified globally, per controller or per route and specify how to transform
any thrown errors from the handler into a response.

### Middleware and Parameter Bindings

Middleware and parameter bindings both sit between the request and the handler, and they are not
alternatives — they answer different questions.

**Middleware wraps.** It composes as a function of the request, so one middleware covers every route
in its scope: global on the composition root, controller-scope on the type, route-scope on the
method, nesting outside-in. It can transform what the route receives — enriching the request
context, replacing the reader or sender — and it can end the request before the handler runs. Middleware
are not part of the request scope itself and cannot inject request-scope bindings, nor can their thrown
errors be caught by Error Handlers.

Middleware currently uses the swift-http-api-proposal's `Middleware` protocol with a 
custom `RequestResponseMiddlewareBox`.

**A parameter binding produces a value.** It is consumed at one leaf — a single handler parameter —
and its result is that parameter's typed value, so the handler cannot run without it. A binding that
merely decodes (`@Path`, `@Query`, `@Header`, `@JSONBody`) needs nothing from the graph. One that has
to *resolve* — consulting a store, a policy, the caller the request scope authenticated — names a
request-scoped worker that does, and the worker is an ordinary binding with its own `@Inject`
members.

Parameter bindings can currently support both streamed and collated request use cases. Response handlers 
can currently support collated response use cases. Currently full duplex use cases (a streaming request
and response) is only possible with a `@RawRoute`.

### Background Services

wire-mvc provides an easy way to declare background services that run alongside the main http server by using the
`@BackgroundService` annotation. The binding must conform to the `Service` protocol from [swift-service-lifecycle](https://github.com/swift-server/swift-service-lifecycle).

```swift
@Provides
@BackgroundService
func provideValkeyClient(
    @ConfigProperty(forKey: "valkey.host", default: "localhost") host: String,
    @ConfigProperty(forKey: "valkey.port", default: 6379) port: Int
) -> ValkeyClient {
    ValkeyClient(.hostname(host, port: port), logger: Logger(label: "valkey"))
}
```

## Examples

The [wire-mvc-examples](https://github.com/swift-wire/wire-mvc-examples) repo have a range of use cases demonstrating
wire-mvc's features.

## Documentation

The user-facing documentation is a DocC catalog — build it with
`swift package generate-documentation --target WireMVC`, or read the articles under
[`Sources/WireMVC/WireMVC.docc`](Sources/WireMVC/WireMVC.docc):

## Contributing

Building, testing, and the plugin type-check trap are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

Apache-2.0. See [LICENSE](LICENSE).

**Generated output is yours.** Code that this package generates into your build — whatever its build
plugin writes, and the expansion of its macros — is not a derivative work of this package and carries
no licence obligation to it. Use it as you would code you wrote yourself. Nothing this package emits
carries a licence header for that reason.
