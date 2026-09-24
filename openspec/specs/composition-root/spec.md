# Composition root

## Purpose

The `@WireMVCBootstrap` composition root and the program entry WireMVCRouteGen generates from it. The
root is a graph binding that supplies the concrete server and route builder, and may supply a
pre-graph `prepare()` step, an introspection path and a `@NotFound` fallback. The generated entry
bootstraps the graph, builds and finalises the router, and serves it with the graph's services. The
root's global `@Middleware` and `@ErrorResponse` tiers are specified in middleware and
error-response-tiers, its `@Coding` in controllers-and-routes, and the test-entry form in
testing-harness.

Rationale: [WireMVCAbstraction](../../../Documentation/Notes/WireMVCAbstraction.md).
Documentation: [TheCompositionRoot](../../../Sources/WireMVC/WireMVC.docc/TheCompositionRoot.md), [Logging](../../../Sources/WireMVC/WireMVC.docc/Logging.md).

## Requirements

### Requirement: `@WireMVCBootstrap` lifts the root's peers onto a global-middleware proxy
The package SHALL declare `wireMVCBootstrapAlias` as a `WireAdapterAnnotationV1` for annotation
`WireMVCBootstrap` with capability `.liftsPeersToProxy(proxyTypePrefix: "_WireGlobalMiddleware_",
proxyScope: .singleton)`, and `@WireMVCBootstrap()` SHALL be an attached peer macro implemented by
`RouteMarkerMacro`. The generated entry SHALL reach that proxy as
`graph._WireGlobalMiddleware_<Root>`.

#### Scenario: the proxy the entry wraps with
- **WHEN** `@Singleton @WireMVCBootstrap struct AppBootstrap` is rendered
- **THEN** the entry contains `let wireMVCServed = graph._WireGlobalMiddleware_AppBootstrap.wrapGlobalMiddleware(handler)`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`) for the `graph._WireGlobalMiddleware_<Root>` line. The `wireMVCBootstrapAlias` declaration and the `@WireMVCBootstrap()` macro declaration are pinned only by `Fixtures/Sources/WireMVCBootstrapExample/Bootstrap.swift`, built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`, whose generated entry names `graph._WireGlobalMiddleware_AppBootstrap` and so compiles only when the alias lifts the proxy.

### Requirement: The root is read off the graph by its binding name
The generated entry SHALL bind `let bootstrap = graph.<name>`, where `<name>` is the root's type name
with its first character lowercased, and SHALL call the root's methods on that local.

#### Scenario: a root named `AppBootstrap`
- **WHEN** `App.swift` declares `@Singleton @WireMVCBootstrap struct AppBootstrap` and WireMVCRouteGen runs
- **THEN** the output contains `let bootstrap = graph.appBootstrap`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`generateEmitsBootstrapEntryAndWireImport`).

### Requirement: Only the first root in the input is composed
WireMVCRouteGen SHALL find `@WireMVCBootstrap` on a `struct`, `class` or `actor` at any nesting depth,
and SHALL generate the entry, the global-middleware extension, the global `@ErrorResponse` tier and
the fallback from the first such declaration in input order only.

#### Scenario: two roots
- **WHEN** two files each declare a `@WireMVCBootstrap` type
- **THEN** one entry is generated, from the root in the earlier file, and no diagnostic is reported

Pinned by: nothing yet.

### Requirement: `createServer()` supplies the server, wrapped for request context
The root SHALL declare `createServer()`. The generated entry SHALL bind `let server =
WireMVCContextServer(bootstrap.createServer())`, prefixing the call with `try` exactly when
`createServer` is declared `throws`.

#### Scenario: a throwing factory
- **WHEN** the root declares `func createServer() throws -> NIOHTTPServer`
- **THEN** the entry contains `let server = WireMVCContextServer(try bootstrap.createServer())`

#### Scenario: a non-throwing factory
- **WHEN** the root declares `func createServer() -> NIOHTTPServer`
- **THEN** the entry contains `let server = WireMVCContextServer(bootstrap.createServer())`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`, `bootstrapEntryOmitsTryForNonThrowingCreateServer`).

### Requirement: `createRouteBuilder(for:)` supplies the route builder
The root SHALL declare `createRouteBuilder(for:)`, and the generated entry SHALL bind `var builder =
bootstrap.createRouteBuilder(for: server)` over the wrapped server. The builder it returns SHALL be a
`FinalizableHTTPServerRouteBuilder`, since the entry registers the fallbacks on it and finalises it.

#### Scenario: the fixture's trie router
- **WHEN** `WireMVCBootstrapExample`'s root returns `TrieRouteBuilder(for: server)` as `some FinalizableHTTPServerRouteBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>`
- **THEN** the generated program builds and serves `GET /hello/ci`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`), `Fixtures/Sources/WireMVCBootstrapExample/Bootstrap.swift` (built and probed by the `Run @WireMVCBootstrap example (boot, probe, stop)` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: A value-returning `prepare()` runs first and supplies the graph's inputs
When the root declares `static func prepare()` returning a type other than `Void` or `()`, the
generated entry SHALL call it before `Wire.bootstrap`, as `let wireMVCInputs = <effects><Root>.prepare()`
with the effect markers the declaration states, and SHALL call `Wire.bootstrap(inputs: wireMVCInputs)`.

#### Scenario: an async throwing pre-step
- **WHEN** the root declares `static func prepare() async throws -> AppInputs`
- **THEN** the entry contains `let wireMVCInputs = try await AppBootstrap.prepare()` followed by `let graph = try await Wire.bootstrap(inputs: wireMVCInputs)`

#### Scenario: the fixture's inputs reach the graph under the test entry
- **WHEN** a `.wiremvc(.swiftHttpServer)` suite runs against `WireMVCBootstrapExample`, whose generated test entry routes the call as `let wireMVCInputs = try await WireMVCTesting.preparedOnce { try await AppBootstrap.prepare() }` rather than the bare `@main` call, and `prepare()` returns `AppInputs(serverConfig: ServerConfig(host: "127.0.0.1", port: 8080), releaseChannel: "stable")`
- **THEN** a binding constructed from those inputs reports `127.0.0.1:8080|stable`, and `prepare()` ran before any binding was constructed

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`preparePreStepSuppliesTheGraphsInputs`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`inputsFromPrepareReachedTheGraph`, `prepareRanBeforeAnyBindingWasConstructed`) for the test entry. The `@main` path is pinned end to end only by `.github/workflows/build.yml` (`BuildAndRun`, step `Run @WireMVCBootstrap example (boot, probe, stop)`), where the binary binds `127.0.0.1:8080` from the `ServerConfig` that `prepare()` supplies.

### Requirement: A `Void` `prepare()` runs first and supplies nothing
When the root's `prepare()` declares no return type, `Void` or `()`, the generated entry SHALL call it
for its effects before `Wire.bootstrap` and SHALL call `Wire.bootstrap()` with no arguments. When the
root declares no `prepare()`, the entry SHALL contain no pre-step.

#### Scenario: a side-effect-only pre-step
- **WHEN** the root declares `static func prepare() { }`
- **THEN** the entry contains `AppBootstrap.prepare()` and `let graph = try await Wire.bootstrap()`, and no `wireMVCInputs`

#### Scenario: no pre-step
- **WHEN** the root declares no `prepare()`
- **THEN** the entry contains `let graph = try await Wire.bootstrap()` and no `prepare()`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`voidPreparePreStepRunsWithoutSupplyingInputs`, `bootstrapEntryOmitsPreStepWhenAbsent`).

### Requirement: The generated entry runs a fixed sequence
The generated `@main` SHALL run, in this order: the `prepare()` pre-step if declared; `let graph = try
await Wire.bootstrap(…)`; `let bootstrap = graph.<name>`; the `WireMVCContextServer` server; `var
builder = bootstrap.createRouteBuilder(for: server)`; `let wireMVCServices = try WireMVC.apply(graph, to:
&builder, coding: …)`; the introspection mount if `mountIntrospectionAt` is declared;
`builder.registerNotFound`; `builder.registerMethodNotAllowed`; `let handler = builder.finalize()`;
`let wireMVCServed = graph._WireGlobalMiddleware_<Root>.wrapGlobalMiddleware(handler)`; and `try await
WireMVC.serve(on: server, handler: wireMVCServed, services: wireMVCServices)`.

#### Scenario: a root with no optional members
- **WHEN** the entry is rendered for `@Singleton @WireMVCBootstrap struct AppBootstrap` declaring `@Inject let config: ServerConfig` and `func createServer() throws -> NIOHTTPServer`, with no `prepare()`, `mountIntrospectionAt()` or `@NotFound` method (the renderer emits the `createRouteBuilder(for:)` call by name without reading its declaration, so the rendering fixture omits it; a root that compiles declares it)
- **THEN** the rendered `struct _WireMVCBootstrapEntry` body is exactly the bootstrap, root, server, builder and `apply` lines, the synthesised `registerNotFound` and `registerMethodNotAllowed` blocks, `finalize()`, `wrapGlobalMiddleware` and `WireMVC.serve`, in that order

#### Scenario: the generated program serves
- **WHEN** CI boots the `WireMVCBootstrapExample` binary and requests `/hello/ci`, `/hello/tenant`, `/nope` and `/wiring`
- **THEN** the answers are a `200` greeting, a `400` from the global `@ErrorResponse`, the `@NotFound` body `no route here` with `404`, and a `200` wiring model

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`), `.github/workflows/build.yml` (`BuildAndRun`, step `Run @WireMVCBootstrap example (boot, probe, stop)`).

### Requirement: `mountIntrospectionAt()` optionally mounts the wiring model
When the root declares `mountIntrospectionAt() -> String?`, the generated entry SHALL mount
introspection only inside `if let wireMVCIntrospectionPath = bootstrap.mountIntrospectionAt() { … }`.
When the method carries no `@Middleware` whose argument is a `@Factory` key, it SHALL call `try
WireMVC.mountIntrospection(for: graph, into: &builder, at: wireMVCIntrospectionPath)`; when it carries
at least one, it SHALL precompute `let
wireMVCIntrospectionResponse = try WireMVCResponse.json(graph.introspect(), status: .ok)` and call
`graph._WireGlobalMiddleware_<Root>.registerIntrospection(into: &builder, at: wireMVCIntrospectionPath,
response: wireMVCIntrospectionResponse)`. A `@Middleware` on the method whose argument is not a factory
key (a by-type `T.self` or a keyed graph binding) is diagnosed `globalMiddlewareUnsupportedArgument` and
contributes nothing, so on its own it leaves the mount unguarded. Without the method, the entry SHALL
mount nothing.

#### Scenario: an unguarded mount
- **WHEN** the root declares `func mountIntrospectionAt() -> String? { "/wiring" }` with no `@Middleware`
- **THEN** the entry calls `WireMVC.mountIntrospection` and the global-middleware extension has no `registerIntrospection`

#### Scenario: a guarded mount
- **WHEN** the method carries `@Middleware(AdminKeys.gate)` and `AdminKeys.gate` is a factory key
- **THEN** the entry calls `graph._WireGlobalMiddleware_AppBootstrap.registerIntrospection(…)` and does not call `WireMVC.mountIntrospection`

#### Scenario: served in a suite
- **WHEN** a `.wiremvc(.inProcess)` suite requests `GET /wiring` against `WireMVCBootstrapExample`
- **THEN** the response is `200` and its body names `HelloController`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryMountsIntrospection`, `bootstrapEntryOmitsIntrospectionWhenAbsent`, `guardedIntrospectionFoldsGuardMiddleware`, `unguardedIntrospectionOmitsRegisterIntrospection`), `Fixtures/Tests/WireMVCBootstrapExampleReplaceTests/ReplaceTests.swift` (`guardedIntrospectionRouteServes`).

### Requirement: A `@NotFound @RawRoute` method is the fallback
When the root declares a method carrying `@NotFound` and `@RawRoute`, the generated entry SHALL
register it with `builder.registerNotFound`, calling `bootstrap.<method>(…)` with its parameters bound
as a raw route's are, the response sender wrapped as `ResponseHeaderApplyingSender(wrapping:
responseSender, registry: wireMVCResponseHeaderRegistry)`.

#### Scenario: the rendered fallback
- **WHEN** the root declares `@NotFound @RawRoute func handleNotFound<Sender: HTTPResponseSender & ~Copyable>(request: HTTPRequest, responseSender: consuming sending Sender) async throws`
- **THEN** the output contains `builder.registerNotFound` and `try await bootstrap.handleNotFound(request: request, responseSender: ResponseHeaderApplyingSender(wrapping: responseSender, registry: wireMVCResponseHeaderRegistry))`

#### Scenario: an unmatched path
- **WHEN** a suite requests `GET /no/such/route` against `WireMVCBootstrapExample`
- **THEN** the response is `404` and its body contains `no route here`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`notFoundHandlerRegistersAsFallback`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`notFoundFallbackServes`), `Fixtures/Tests/WireMVCBootstrapExampleReplaceTests/ReplaceTests.swift` (`notFoundFallbackServes`).

### Requirement: A `@NotFound` method that is not raw is an error
WireMVCRouteGen SHALL report `notFoundNotRaw` at the method's name when a `@NotFound` method lacks
`@RawRoute`. The message SHALL read `@NotFound handler '<name>' must be @RawRoute — the fallback writes
the response directly (no matched route to decode/encode against). Add @RawRoute and take the
response sender.`

#### Scenario: a typed fallback
- **WHEN** the root declares `@NotFound @JSONResponse func handleNotFound() -> Greeting`
- **THEN** the diagnostics contain `notFoundNotRaw`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`notFoundHandlerMustBeRaw`) for the `notFoundNotRaw` case only. The location at the method's name and the message text are pinned by nothing yet.

### Requirement: Without `@NotFound` a 404 is synthesised that drains the registry
When the root declares no `@NotFound` method, the generated entry SHALL register a fallback that takes
the context's response-header registry and sends `WireMVCOutcome.status(.notFound, headerFields:
WireMVCResponseHeaders.resolved(middleware: try await <registry>.drain()))`.

#### Scenario: a miss under global middleware
- **WHEN** the `WireMVCFallbackExample` root declares a global `@Middleware` that contributes `x-stamp: global` and no `@NotFound`, and a client requests `GET /no/such/route`
- **THEN** the response is `404` with `x-stamp: global`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`synthesisedNotFoundCarriesTheGlobalHeader`).

### Requirement: A 405 is always synthesised with `Allow` and the registry drained
The generated entry SHALL always register `builder.registerMethodNotAllowed`, whose handler sets
`Allow` to the allowed methods' raw values joined by `", "` and sends `WireMVCOutcome.status(
.methodNotAllowed, headerFields: WireMVCResponseHeaders.resolved(returned: <Allow fields>, middleware:
try await <registry>.drain()))`. No annotation SHALL exist to author a custom 405.

#### Scenario: a wrong method on a real route
- **WHEN** `/ping` answers only `GET` and a client sends `DELETE /ping` to `WireMVCFallbackExample`
- **THEN** the response is `405` with `Allow: GET` and `x-stamp: global`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aWrongMethodOnARealRouteIsMethodNotAllowed`, `aMethodNotAllowedCarriesTheGlobalHeader`).

## Related specifications

- [route-builder-contract](../route-builder-contract/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [middleware](../middleware/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [response-headers](../response-headers/spec.md)
- [trie-router](../trie-router/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [build-plugins-and-routegen-cli](../build-plugins-and-routegen-cli/spec.md)
- [swift-wire adapter-annotations](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/adapter-annotations/spec.md)
