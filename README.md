# wire-mvc

`WireMVC` — a cross-runtime, declarative-routing [swift-wire](https://github.com/tachyonics/swift-wire)
adapter. Controllers are written with `@Controller` / HTTP-verb / parameter / response
annotations, and the `@Controller` macro generates their route registration onto a
`some ServerTransport` (swift-wire's collation surface). Because the target is
`ServerTransport` — and the package depends only on `OpenAPIRuntime`, no HTTP framework — the
same controller mounts on Hummingbird, Vapor, or Lambda unchanged.

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
}
```

The `@Controller` macro walks the routes and generates a `TransportContributor` witness — one
`transport.register` per route: decode the parameters, call the handler, encode the response.
Parameter bindings (`@Path` / `@Query` / `@JSONBody` / `@Header`) are property-wrapper markers
that host their extraction on a `RequestBound` protocol, so the macro stays a thin dispatcher
and bindings are user-extensible. See [WireMVCDesign.md](Documentation/Notes/WireMVCDesign.md) for the full design.

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
package's `WireMVCRouteGen` for the route witnesses — so a WireMVC target applies it **instead
of** swift-wire's `WireBuildPlugin`, not alongside it. The traits decide what gets resolved:
`NIOHTTPServer` for a live server, `ServerTransport` to mount on Hummingbird or Vapor,
`Elementary` for HTML responses. All are off by default.

Requires a Swift 6.4 toolchain; targets macOS 26 and Linux.

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
