# wire-mvc

`WireMVC` — a cross-runtime, declarative-routing [swift-wire](https://github.com/tachyonics/swift-wire)
adapter. Controllers are written with `@Controller` / HTTP-verb / parameter / response
annotations, and the `@Controller` macro generates their route registration onto a
`some ServerTransport` (swift-wire's M3 collation surface). Because the target is
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
and bindings are user-extensible. See
[swift-wire's WireMVCDesign.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/WireMVCDesign.md)
for the full design and [M5_PLAN.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/M5_PLAN.md)
for the milestone.

## Status

Under construction (M5.1).

- **M5.1a** — the member-walking `@Controller` macro + the `RequestBound` bindings + the
  generated witness, served through a `ServerTransport` in `WireMVCExample`. **Done.**
- **M5.1b** — swift-wire graph integration: `@Singleton` + the `@Contributes` alias +
  `TransportComposable` conformance + `Wire.bootstrap()` + `WireMVC.apply`. **Done** —
  `WireMVCExample` now bootstraps the graph, which constructs `UserStore`, injects it into the
  collated `UsersController`, and applies its routes onto the transport.
- **M5.1c** — example ports (`hello`, `todos`) + live cross-runtime on Hummingbird + Vapor.
  **Current.**
- **M5.1d** — extract the shared `ServerTransport` collation surface so WireMVC and WireOpenAPI
  fold into one key (migrating wire-open-api onto it).

Validated on macOS and Linux (see CI).

## Building and testing

Two packages, and both need running:

```sh
swift test              # the core: codegen, router, testing runtime
cd Fixtures && swift test   # the runnable examples and their integration suites
```

`Fixtures/` is a separate package with a path dependency on the root (`.package(path: "..")`). It exists
because its targets serve on `NIOHTTPServer`, and it is **the only place `WireMVCBuildPlugin` actually runs** —
no root target applies it. A change to the plugin, or to what the two codegen tools emit, is unverified until
the fixtures build. `WireMVCBootstrapExampleBindTests` is the one that exercises the keyed `TestingKey`
harness end to end.

Both packages are tools-version 6.4, so they need a 6.4 toolchain.

One trap worth knowing: **`swift build --target WireMVCBuildPlugin` does not type-check the plugin.** SwiftPM
compiles a build-tool plugin only when some target applies it, and the flag no-ops silently rather than
erroring — a type error in the plugin will pass that command and then fail in CI on the fixtures. To check it
directly:

```sh
xcrun swiftc -typecheck -parse-as-library -swift-version 6 \
  -I "$(xcrun --show-sdk-platform-path)/../../Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/PluginAPI" \
  -Xfrontend -disable-availability-checking \
  Plugins/WireMVCBuildPlugin/WireMVCBuildPlugin.swift
```

## Related work

Vapor 5 has an experimental macro-based `@Controller` router of its own (behind
`#if MacroRouting`). The two overlap on the routing-annotation surface (controllers,
HTTP verbs, path params) but differ architecturally: Vapor centres per-request
context on the `Request` object, while WireMVC centres a DI container — so
`@Inject`/`@Singleton` dependency injection, request-scoped controllers, and
cross-runtime mounting are WireMVC concerns without a proposal-level equivalent. See
[Documentation/Notes/VaporMacroRouting-Overlap.md](Documentation/Notes/VaporMacroRouting-Overlap.md)
for the full comparison and how each relates to prior art.
