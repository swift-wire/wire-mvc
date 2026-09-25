# Route builder contract

## Purpose

The router-agnostic core that wire-open-api, wire-mvc-hummingbird and application code build on. It
is the registration surface a generated route witness targets (`HTTPServerRouteBuilder`), the
refinement a composition root serves from (`FinalizableHTTPServerRouteBuilder`), the protocol a
controller's generated proxy conforms to (`RouteContributor`), the two collation keys the graph
fills (`WireMVCKeys.routeContributors`, `WireMVCKeys.services`), the conformance the generated
graph gains (`WireMVCComposable`), and the `WireMVC` entry points that apply and serve a graph.
The swift-wire side of the contract, the annotation capabilities and the generated proxy names, is
specified in swift-wire and linked below rather than restated.

Rationale: [WireMVCDesign](../../../Documentation/Notes/WireMVCDesign.md), [WireMVCAbstraction](../../../Documentation/Notes/WireMVCAbstraction.md), [WireMVCRouter](../../../Documentation/Notes/WireMVCRouter.md).
Documentation: [WritingAController](../../../Sources/WireMVC/WireMVC.docc/WritingAController.md), [TheCompositionRoot](../../../Sources/WireMVC/WireMVC.docc/TheCompositionRoot.md).

## Requirements

### Requirement: `HTTPServerRouteBuilder` is the registration surface
`HTTPServerRouteBuilder<RequestContext, Reader, ResponseSender>` SHALL be a protocol refining
`SendableMetatype` with three associated types: `RequestContext: HTTPServerCapability.RequestContext,
~Copyable`; `Reader: AsyncReader, ~Copyable, SendableMetatype` with `ReadElement == UInt8` and
`FinalElement == HTTPFields?`; and `ResponseSender: HTTPResponseSender, ~Copyable, SendableMetatype`
with `Writer: ~Copyable`. Its one requirement SHALL be
`mutating func register(method: HTTPRequest.Method, path: String, handler:)`.

#### Scenario: a hand-written contributor registers on any builder
- **WHEN** a `RouteContributor` written by hand is generic over `Builder: HTTPServerRouteBuilder` and calls `builder.register(method: .get, path: "/users/{id}") { … }`
- **THEN** it compiles against every conforming builder, and the `ServerTransport` bridge's builder serves `GET /users/42` from that registration

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`servesProposalRoutesOnServerTransport`).

### Requirement: The route handler has one fixed parameter shape
The `handler` passed to `register(method:path:handler:)` SHALL be an `@escaping @Sendable` closure of
type `(HTTPRequest, consuming RequestContext, [String: Substring], consuming sending Reader,
consuming sending ResponseSender) async throws -> Void`, in that order. The third parameter SHALL be
the path parameters the router matched from the route's template.

#### Scenario: the generated witness registers a JSON route
- **WHEN** `@Controller("/todos")` declares `@Get("/{id}") @JSONResponse func get(@Path id: String)`
- **THEN** the generated witness calls `builder.register(method: .get, path: "/todos/{id}") { request, requestContext, pathParameters, _, responseSender in … }` and binds `id` from `pathParameters`

#### Scenario: a hand-written route reads the matched parameter
- **WHEN** a hand-written contributor registers `/users/{id}` and reads `pathParameters["id"]`
- **THEN** a request for `/users/42` reaches the handler with `pathParameters["id"] == "42"`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`), `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`servesProposalRoutesOnServerTransport`).

### Requirement: `FinalizableHTTPServerRouteBuilder` adds the fallbacks and the freeze
`FinalizableHTTPServerRouteBuilder` SHALL refine `HTTPServerRouteBuilder` with an associated
`ServingHandler: HTTPServerRequestHandler` whose `RequestContext`, `Reader` and `ResponseSender` equal
the builder's, and three requirements: `mutating func registerNotFound(handler:)` taking the same
handler shape as `register`, `mutating func registerMethodNotAllowed(handler:)` whose third parameter
is `[HTTPRequest.Method]` in place of the path parameters, and `consuming func finalize() ->
ServingHandler`.

#### Scenario: the generated entry point drives all three
- **WHEN** WireMVCRouteGen renders the `@main` for a `@WireMVCBootstrap` root
- **THEN** the entry calls `builder.registerNotFound { … }`, then `builder.registerMethodNotAllowed { _, requestContext, wireMVCAllowed, _, responseSender in … }`, then `let handler = builder.finalize()`

#### Scenario: a hand-written program freezes before serving
- **WHEN** `WireMVCExample` calls `WireMVC.apply(graph, to: &builder)` on a `TrieRouteBuilder` and then `builder.finalize()`
- **THEN** the returned handler is what `serve(handler:)` is given

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`), `Fixtures/Sources/WireMVCExample/main.swift` (built and run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `RouteContributor` is generic on the method, not the type
`RouteContributor` SHALL be a `Sendable` protocol with no associated types and one requirement:
`func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder, coding:
WireMVCCoding) throws` constrained by `Builder.RequestContext: ~Copyable & ResponseHeaderCarrying`,
`Builder.Reader: ~Copyable`, `Builder.ResponseSender: ~Copyable` and
`Builder.ResponseSender.Writer: ~Copyable`, so that `any RouteContributor` boxes while the builder
never does.

#### Scenario: the generated witness spells the signature
- **WHEN** WireMVCRouteGen renders a controller's witness
- **THEN** it emits `func registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder, coding wireMVCAppCoding: WireMVCCoding) throws` with exactly the four `where` constraints above

#### Scenario: contributors are collated as existentials
- **WHEN** a hand-written `WireMVCComposable` returns `[HelloController()]` as `routeContributors`
- **THEN** the array's element type is `any RouteContributor` and `WireMVC.apply` registers it

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`), `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`servesProposalRoutesOnServerTransport`).

### Requirement: Two collation keys live under `WireMVCKeys`
`WireMVCKeys` SHALL be an empty namespace enum carrying `static let routeContributors =
CollectedKey<any RouteContributor>()` and `static let services = CollectedKey<any Service>()`, where
`Service` is `ServiceLifecycle.Service`.

#### Scenario: a service contributed through the key is collated
- **WHEN** a `@Provides @BackgroundService func makeHeartbeat() -> Heartbeat` is in the graph
- **THEN** `graph.services` contains the `Heartbeat` instance

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `@BackgroundService` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `WireMVCComposable` is the graph's facade
`WireMVCComposable` SHALL declare `var routeContributors: [any RouteContributor] { get }` and
`var services: [any Service] { get }`. The package SHALL declare `wireMVCComposition` as a
`WireGraphConformanceV1` conforming the generated graph to `(any WireMVCComposable).self` with member
`routeContributors` drawn from `WireMVCKeys.routeContributors` and member `services` drawn from
`WireMVCKeys.services`, so a graph with controllers but no services, or the reverse, still conforms.

#### Scenario: a hand-written graph conforms
- **WHEN** a test declares `struct TestGraph: WireMVCComposable` returning one contributor and no services
- **THEN** it is accepted by `WireMVCServerTransport.apply(_:to:)` and its route serves

#### Scenario: the generated graph conforms
- **WHEN** a target applying `WireMVCBuildPlugin` depends on the `WireMVC` product and calls `Wire.bootstrap()`
- **THEN** the returned graph is accepted by `WireMVC.apply(_:to:coding:)` as `some WireMVCComposable`

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`servesProposalRoutesOnServerTransport`), `Fixtures/Sources/WireMVCExample/main.swift` (the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`). The controllers-but-no-services case is pinned by `Fixtures/Sources/WireMVCBootstrapExample`, a generated graph with controllers and no `@BackgroundService`, built by the same `Build fixtures` step. The services-but-no-controllers case is pinned by nothing yet.

### Requirement: `WireMVC.apply` registers every contributor and returns the services
`WireMVC.apply<Builder: HTTPServerRouteBuilder>(_ graph: some WireMVCComposable, to builder: inout
Builder, coding: WireMVCCoding = .default) throws -> [any Service]` SHALL call
`registerWireRoutes(on: &builder, coding: coding)` on each of `graph.routeContributors` in order and
return `graph.services`. The result SHALL be `@discardableResult`. It SHALL carry the same four
`where` constraints as `registerWireRoutes`.

#### Scenario: the services come back from apply
- **WHEN** `let services = try WireMVC.apply(graph, to: &builder)` runs over a graph holding a `@BackgroundService` `Heartbeat`
- **THEN** `services.contains { $0 is Heartbeat }` is true

#### Scenario: the generated entry passes the app coding
- **WHEN** WireMVCRouteGen renders the `@main` for a root that declares no `@Coding`
- **THEN** the entry contains `let wireMVCServices = try WireMVC.apply(graph, to: &builder, coding: WireMVCCoding.default)`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (run by the `BuildAndRun` job in `.github/workflows/build.yml`), `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`).

### Requirement: `WireMVC.mountIntrospection` serves the wiring model as JSON
`WireMVC.mountIntrospection<Builder: HTTPServerRouteBuilder>(for graph: some Introspectable, into
builder: inout Builder, at path: String = "/wiring") throws` SHALL encode `graph.introspect()` once,
at mount time, into a `WireMVCResponse.json` with status `200`, and register a `GET` route at `path`
that sends that prepared outcome.

#### Scenario: the default path
- **WHEN** `WireMVCExample` calls `try WireMVC.mountIntrospection(for: graph, into: &builder)` and a client requests `GET /wiring`
- **THEN** the response is `200` and its JSON body lists the collated `UsersController` under `bindings`

#### Scenario: the generated entry mounts an unguarded path
- **WHEN** a `@WireMVCBootstrap` root declares `func mountIntrospectionAt() -> String? { "/wiring" }` with no `@Middleware` on it
- **THEN** the rendered entry contains `try WireMVC.mountIntrospection(for: graph, into: &builder, at: wireMVCIntrospectionPath)`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (run by the `BuildAndRun` job in `.github/workflows/build.yml`), `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryMountsIntrospection`).

### Requirement: `WireMVC.serve` serves in the body and runs services in a child task
`WireMVC.serve<Server: HTTPServer, Handler: HTTPServerRequestHandler>(on server: Server, handler:
Handler, services: [any Service]) async throws`, constrained so the handler's `RequestContext`,
`Reader` and `ResponseSender` equal the server's, SHALL open a throwing task group, add one child task
that calls `WireMVC.runServices(services)`, call `server.serve(handler:)` in the group body, and
cancel the group when serving returns.

#### Scenario: the generated entry hands the locals to serve
- **WHEN** WireMVCRouteGen renders the `@main` for a `@WireMVCBootstrap` root
- **THEN** its last statement is `try await WireMVC.serve(on: server, handler: wireMVCServed, services: wireMVCServices)`

#### Scenario: the generated program serves
- **WHEN** CI boots the `WireMVCBootstrapExample` binary and polls `GET /hello/ci`
- **THEN** the route answers `{"message":"Hello, ci!"}` while the process stays alive until killed

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`), `.github/workflows/build.yml` (`BuildAndRun`, step `Run @WireMVCBootstrap example (boot, probe, stop)`).

### Requirement: `WireMVC.runServices` is a no-op for an empty list
`WireMVC.runServices(_ services: [any Service]) async throws` SHALL return immediately when
`services` is empty, and otherwise SHALL run them in a `ServiceGroup` constructed with
`Logger(label: "WireMVC")` until the group ends.

#### Scenario: a test mode with the run policy starts a service
- **WHEN** `WireMVCTesting.runSuite` is given `services: [service]` and `servicePolicy: .run`
- **THEN** `WireMVC.runServices` is invoked in a sibling task and the service's `run()` is observed to have started

#### Scenario: no services
- **WHEN** `WireMVC.runServices([])` is awaited
- **THEN** it returns without constructing a `ServiceGroup`

Pinned by: `Tests/WireMVCTestingTests/ServicePolicyTests.swift` (`servicePolicyRunStartsThem`). The empty-list scenario is pinned by nothing yet.

### Requirement: `@Controller` contributes its proxy, not the controller
The package SHALL declare `wireMVCControllerAlias` as a `WireAdapterAnnotationV1` for annotation
`Controller` with capability `.contributesProxy(to: WireMVCKeys.routeContributors, proxyTypePrefix:
"_WireRouteContributor_", proxyScope: .singleton)`, so that WireGen synthesises an app-scoped
`_WireRouteContributor_<Controller>` and collates that into `WireMVCKeys.routeContributors`. The
controller itself SHALL NOT enter the collection.

#### Scenario: a controller declared with only two annotations
- **WHEN** a type is declared `@Singleton @Controller("/hello") struct HelloController`
- **THEN** the generated graph's `routeContributors` holds a `_WireRouteContributor_HelloController`, and `GET /hello/ci` serves through it

Pinned by: `Fixtures/Sources/WireMVCBootstrapExample/HelloController.swift` (built by the `Build fixtures` step and probed by the `Run @WireMVCBootstrap example` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: The `@Controller` macro expands to nothing
`@Controller(_ path: String)` and `@Controller()` SHALL be attached peer macros implemented by
`ControllerMacro`, whose expansion SHALL return no peers and emit no diagnostics. Route-shape
validation SHALL happen in WireMVCRouteGen at build time, not in the macro.

#### Scenario: a controller with a route
- **WHEN** `@Controller("/todos")` is expanded over `struct Todos` carrying a `@Get("/{id}") @JSONResponse func get(@Path id: String)` route, with `@Get` and `@JSONResponse` expanded by `RouteMarkerMacro`
- **THEN** the expanded source is `struct Todos` with the `@Get` and `@JSONResponse` markers removed, `@Path` kept, and no added declaration

#### Scenario: a controller with type-level middleware
- **WHEN** `@Controller("/x") @Middleware(Keys.session)` is expanded over `struct C`
- **THEN** the expanded source is `struct C` with no added declaration, and in particular no proxy holding `_wireFactory_Keys_session`

#### Scenario: a malformed route in the macro's view
- **WHEN** `@Controller` is expanded over a route whose parameter has no binding annotation
- **THEN** the macro reports no diagnostic

#### Scenario: the same route in WireMVCRouteGen's view
- **WHEN** WireMVCRouteGen renders the witness for a route `func f(id: String) -> Int` whose parameter has no binding annotation
- **THEN** it reports exactly one diagnostic, `handler parameter 'id' needs a binding annotation — one of @Path, @Query, @JSONBody, @Header`

Pinned by: `Tests/WireMVCMacrosTests/ControllerMacroTests.swift` (`testControllerAddsNoPeer`, `testControllerWithMiddlewareAddsNoPeer`, `testMarkerDoesNotDiagnoseRouteShape`), `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`unannotatedParameterIsDiagnosed`).

### Requirement: The witness is an extension on the proxy, calling the subject through `_wireSubject`
WireMVCRouteGen SHALL emit each controller's witness into `_WireRoutes.swift` as `extension
_WireRouteContributor_<Controller>: RouteContributor { … }`, with no access keyword on the extension.
Its `registerWireRoutes` method SHALL carry `public ` when the controller is `public` or `open`,
`package ` when it is `package`, and no access keyword otherwise. The witness body SHALL reach the controller through the
stored field `_wireSubject`. `contributorProxySubjectAccessor` SHALL equal `"_wireSubject"`, and the
witness body SHALL differ from one rendered against any other accessor only in that name.

#### Scenario: the proxy extension for a controller named `Todos`
- **WHEN** WireMVCRouteGen renders the witness for `@Controller("/todos") struct Todos`
- **THEN** the source begins `extension _WireRouteContributor_Todos: RouteContributor {` and the route calls `self._wireSubject.get(id: id)`

#### Scenario: the accessor is the only variable
- **WHEN** the same controller's witness is rendered with `subjectAccessor: "_wireSubject"` and with `subjectAccessor: "controller"`
- **THEN** replacing `self._wireSubject` with `self.controller` in the first yields the second exactly

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`, `subjectAccessorIsTheStructuralHalfContract`, `witnessVariesOnlyBySubjectAccessor`).

### Requirement: Lifted field names are derived by the same rule on both sides
The witness SHALL name the proxy's WireGen-emitted fields by these rules, each applied to the
annotation's canonical argument text: a `@Middleware(key)` naming a `@Factory` template reads
`_wireFactory_<key>` with every character that is not a letter, a digit or `_` (by Swift's
`Character.isLetter` and `isNumber`, so non-ASCII letters and digits are kept) replaced by `_`; a `@Middleware(key)`
naming any other binding key reads `_wire<key>` sanitised the same way; a `@Middleware(T.self)` reads
`_wire<T>` where `<T>` is the simple type name with generics and namespace stripped and its first
letter upper-cased; and a scoped controller's per-request entry calls `self._wireEnterScope(request)`.

#### Scenario: a factory key with a dotted reference
- **WHEN** a route carries `@Middleware(Keys.session)` and `Keys.session` is a declared `@Factory` template key
- **THEN** the witness calls `self._wireFactory_Keys_session.create(Builder.RequestContext.Base.self, Builder.Reader.self, Builder.ResponseSender.self)`

#### Scenario: a binding key that is not a factory
- **WHEN** a route carries `@Middleware(Gates.primary)` and no `@Factory(Gates.primary)` template exists
- **THEN** the witness reads `self._wireGates_primary` and contains no `_wireFactory_`

#### Scenario: a scoped controller
- **WHEN** the controller is `@Scoped(seed: HTTPRequest.self)`
- **THEN** each route's terminal body enters the scope with `let wireMVCScopeEntry = try await self._wireEnterScope(request)`, dispatches on `wireMVCController` bound from `wireMVCScopeEntry._wireSubject`, and never reads `self._wireSubject`

#### Scenario: by-type middleware
- **WHEN** a controller carries `@Middleware(ControllerGate.self)` and its route carries `@Middleware(RouteGate.self)`
- **THEN** the witness reads `self._wireControllerGate` and `self._wireRouteGate`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`middlewareFactoryKeyFold`, `middlewareBindingKeyFold`, `scopedControllerConstructsPerRequestViaScopeEntry`, `factoryKeyDeclaredInAnotherFileIsClassifiedAsFactory`, `controllerAndRouteByTypeMiddlewareOrder`). The placement of the scope entry inside the terminal body, the stripping of generics and namespace from a by-type name, and the upper-casing of its first letter are pinned by nothing yet.

### Requirement: `@BackgroundService` aliases a contribution to the services key
The package SHALL declare `wireMVCServiceAlias` as a `WireAdapterAnnotationV1` for annotation
`BackgroundService` with capability `.contributes(to: WireMVCKeys.services)`. `@BackgroundService()`
SHALL be an attached peer macro implemented by `BackgroundServiceMacro` whose expansion returns no
peers, so it attaches to a `@Singleton` or `@Scoped` type or to a `@Provides` function. Only a
default-graph contribution (a `@Singleton` type or a `@Provides` function) SHALL reach `graph.services`
and the result of `WireMVC.apply`; a `@Scoped(seed:)` type contributes to its seed scope's
`WireMVCKeys.services` aggregate instead, which is tracked as a possible defect in
https://github.com/swift-wire/wire-mvc/issues/237. The marker SHALL NOT add a `Service` conformance.

#### Scenario: the provider form
- **WHEN** `@Provides @BackgroundService func makeHeartbeat() -> Heartbeat` is declared and `Heartbeat: Service` states its own conformance
- **THEN** `WireMVC.apply` returns a services array containing the `Heartbeat`

Pinned by: `Fixtures/Sources/WireMVCExample/Heartbeat.swift` and `Fixtures/Sources/WireMVCExample/main.swift` (run by the `BuildAndRun` job in `.github/workflows/build.yml`). The macro's empty expansion and the `@Scoped(seed:)` case are pinned by nothing yet.

## Related specifications

- [controllers-and-routes](../controllers-and-routes/spec.md)
- [composition-root](../composition-root/spec.md)
- [middleware](../middleware/spec.md)
- [request-scope](../request-scope/spec.md)
- [trie-router](../trie-router/spec.md)
- [server-transport-bridge](../server-transport-bridge/spec.md)
- [build-plugins-and-routegen-cli](../build-plugins-and-routegen-cli/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [swift-wire adapter-annotations](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/adapter-annotations/spec.md)
- [swift-wire scope-entry-and-generated-names](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/scope-entry-and-generated-names/spec.md)
- [wire-open-api route-mounting](https://github.com/swift-wire/wire-open-api/blob/main/openspec/specs/route-mounting/spec.md)
