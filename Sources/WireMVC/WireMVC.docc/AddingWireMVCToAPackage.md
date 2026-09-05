# Adding WireMVC to a package

The manifest, the build plugin that replaces swift-wire's, and the first controller that serves.

## Overview

WireMVC is a swift-wire adapter, so an application using it composes two things: a dependency
graph and a set of routes. One build plugin generates both, which is the detail most worth
knowing before you start — a WireMVC target applies `WireMVCBuildPlugin` **instead of**
swift-wire's `WireBuildPlugin`, not alongside it.

## The manifest

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

`WireMVCBuildPlugin` runs two code generators over your sources: swift-wire's `WireGen` for the
graph, the key checks and the contributor proxies, and this package's `WireMVCRouteGen` for the
route witnesses. Both emit into the same module, which is why one plugin covers both jobs and
why adding swift-wire's plugin as well would generate the graph twice.

Traits decide what the package resolves — `NIOHTTPServer` above is what makes a live server
available. They are off by default so that a consumer serving no HTML, and not on NIO, resolves
neither. See <doc:PackageTraits>.

WireMVC requires a Swift 6.4 toolchain and targets macOS 26 or Linux.

## A controller that serves

Three declarations: a binding, a controller, and a composition root.

```swift
import Wire
import WireMVC

@Provides let repository = InMemoryUserRepository()

@Singleton
@Controller("/users")
struct UsersController {
    @Inject var repository: InMemoryUserRepository

    @Get("/{id}")
    @JSONResponse
    func user(@Path id: String) async throws -> User {
        try repository.find(id)
    }
}
```

```swift
@Singleton
@WireMVCBootstrap
struct AppBootstrap {
    @Inject let config: ServerConfig

    func createServer() throws -> NIOHTTPServer { … }
    func createRouteBuilder<Server: HTTPServer>(for server: borrowing Server) -> some … { … }
}
```

There is no `main.swift` and no hand-written `@main`. The plugin generates the entry point from
the composition root: it bootstraps the graph, constructs the root, registers every collated
route onto the builder it returns, and serves. `swift run MyApp` is the whole command.

`@Singleton` on both types is required rather than decorative — it is what makes each one a
graph binding. A `@Controller` without it is not in the graph, so nothing constructs it.

## Where to go next

- <doc:WritingAController> — verbs, paths, and what the macro generates.
- <doc:TheCompositionRoot> — what the generated entry point does, in order.
- <doc:TestingAnApp> — serving the same app in a test suite.
