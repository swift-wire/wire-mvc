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
and bindings are user-extensible. See
[swift-wire's WireMVCDesign.md](Documentation/Notes/WireMVCDesign.md)
for the full design and [M5_PLAN.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/M5_PLAN.md)
for the milestone.

## What differs by runtime

The controller is unchanged across runtimes; the **router in front of it** is not. On the proposal-native
path WireMVC's own router serves the routes. On Hummingbird and Vapor it *collates* onto the host's
router through `ServerTransport`, so the host decides what a miss means.

| | Proposal-native | Hummingbird | Vapor |
|---|---|---|---|
| Wrong method on an existing path | `405` + `Allow` | `404` | `404` |
| Percent-decoded path parameters | yes | **no** | yes |
| Trailing slash | policy — lenient (default) or strict | lenient | lenient |
| Duplicate route registration | fatal at startup | fatal at startup | logged, last wins |
| Catch-all `{name*}` | supported | refused at registration | refused at registration |
| Ambient (task-local) context in a handler | yes | yes | yes |

Rows 1, 2 and 6 are pinned by tests in all three runtimes of
[wire-mvc-examples](https://github.com/tachyonics/wire-mvc-examples); rows 3 and 4 are read from each
host's router source; row 5 is enforced by this package.

**Two kinds of difference, and they are not the same thing.**

*Convention.* Rows 1–4. Each runtime behaves the way its own ecosystem expects, and that is the point of
collating rather than owning — a Hummingbird app answering Hummingbird's `404` is correct, and imposing
WireMVC's `405` on it would be the wrong kind of consistency. Nothing here is a defect.

*Capability.* Row 5, and the reason it reads differently. Both hosts have wildcard routing of their own —
Hummingbird four forms, Vapor `.catchall` — but a WireMVC route template cannot reach it, because the path
crosses `ServerTransport.register` as an OpenAPI `{name}` template and each adapter interprets a wildcard
in it differently. So a catch-all controller serves on the native runtime only, and putting one in a
*shared* module breaks the others at startup. That is a gap on the bridge's side rather than a limit of
the runtime, and whether it closes is being measured — see
[CatchAllMountingProbe.md](Documentation/Notes/CatchAllMountingProbe.md).

The same shape applies to the rest of the `ServerTransport` ceiling: connection metadata, protocol upgrade
and non-`{name}` path syntax are unreachable through the bridge whatever the host supports.

## Status

Built, pre-1.0. The surface below is shipped and exercised by the fixtures in this repository
and by [wire-mvc-examples](https://github.com/tachyonics/wire-mvc-examples) on three runtimes.

- **Routing.** The member-walking `@Controller` macro, typed parameter/body/response bindings,
  `@RawRoute` for handlers that own the wire, and a generated route-contributor proxy that
  composes into the Wire graph through the `@Contributes` alias.
- **Composition root.** `@WireMVCBootstrap` generates the program entry point — no hand-written
  `main.swift` — folding in the `@NotFound` fallback, global `@ErrorResponse` tiers, an optional
  `introspect()` mount and global `@Middleware` as a front layer.
- **Request scope.** `@Scoped(seed: HTTPRequest.self)` controllers, each a per-request
  reachability root, with `@Teardown` firing at the end of the request.
- **Logging.** A per-request logger in two interchangeable targets, `WireMVCLogging` (mints a
  correlation id) and `WireMVCTaskLocalLogging` (adopts swift-log's task-local, so the
  framework's own lines share the id).
- **Testing.** `@Suite(.wiremvc())`, per-`TestingKey` variant app graphs, `@BindType` doubles and
  a typed client — a mocked suite runs without the real backends.
- **One routing model.** An `@Operation` from an OpenAPI document contributes to the same
  collation key as a `@Get`, so middleware, error mapping, request scope and encoding are
  expressed identically across both authoring styles.

Known gaps are tracked as [issues](https://github.com/tachyonics/wire-mvc/issues) and indexed in
swift-wire's KnownGaps.md.

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
