# ``WireMVC``

Declarative routing for server-side Swift, wired at build time and mounted on any runtime.

## Overview

A controller is an ordinary type with annotations on it. WireMVC's build plugin reads them,
generates the route registrations, and composes the result into a swift-wire dependency graph —
so routing and dependency injection are validated together, at build time, with no registration
step and no runtime router configuration.

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
}
```

Two things make that more than annotation sugar.

**The controller is the unit of composition.** `@Singleton @Controller` is a swift-wire binding
like any other, so its dependencies are injected and its graph is validated at build time. A
missing binding is a compile error rather than a nil at first request.

**The target is a route builder, not a framework.** Routes register onto
`some HTTPServerRouteBuilder`, and the package depends on no HTTP server. The same controller
serves on WireMVC's own router, or collates onto Hummingbird or Vapor through
`ServerTransport`, unchanged. What that costs at the edges is written down in
<doc:WhatDiffersByRuntime> rather than glossed.

## Is WireMVC the right fit?

It suits an application that already wants build-time dependency injection, and whose routing
is naturally declarative — a set of controllers with typed parameters and encoded responses.

It is the wrong tool when you want the host framework's own routing idioms (Hummingbird's
`RouterGroup`, Vapor's route builders) — those are good, and collating onto them from here buys
nothing. It is also the wrong tool when your handlers mostly own the wire: streaming, proxying
and protocol upgrades reach for `@RawRoute`, and a service made mostly of those is fighting the
model rather than using it.

## Topics

### Getting started

- <doc:AddingWireMVCToAPackage>
- <doc:WritingAController>
- <doc:PackageTraits>

### Routes

- <doc:RequestBindings>
- <doc:ResponsesAndHeaders>
- <doc:ErrorHandling>
- <doc:Coding>

### Composition

- <doc:TheCompositionRoot>
- <doc:UsingMiddleware>
- <doc:RequestScope>

### Observability

- <doc:Logging>

### Running and testing

- <doc:WhatDiffersByRuntime>
- <doc:TestingAnApp>

### Route contribution

- ``RouteContributor``
- ``RouteContext``
