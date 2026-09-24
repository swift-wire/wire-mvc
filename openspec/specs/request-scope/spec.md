# Request scope

## Purpose

A controller declared `@Scoped(seed: HTTPRequest.self) @Controller` is constructed per request
rather than held. Its generated route-contributor proxy stays app-scoped and collated once; each route
of its witness enters the controller's request scope with the request as seed, dispatches on the
controller that entry returns, and tears the scope down when the terminal's `building:` closure ends. The seeded-scope
semantics themselves (what a scope entry constructs, teardown ordering, the generated names) are
swift-wire's and are specified there.

Rationale: [WireMVCAbstraction](../../../Documentation/Notes/WireMVCAbstraction.md), [ScopeAwareMiddlewareAndBindings](../../../Documentation/Notes/ScopeAwareMiddlewareAndBindings.md).
Documentation: [RequestScope](../../../Sources/WireMVC/WireMVC.docc/RequestScope.md).

## Requirements

### Requirement: A seeded controller enters its scope per request with the request as seed
For a controller carrying `@Scoped(seed: S.self)`, every typed route of the production witness SHALL
open its terminal body with `let wireMVCScopeEntry = try await self._wireEnterScope(request)`. On a
route with no `@Middleware`, `request` SHALL be the register closure's `request`. The variant witness a
keyed test harness generates enters scope with `_wireEnterScope(request, wireMVCDoubles)` instead, as
[testing-harness](../testing-harness/spec.md) specifies.

#### Scenario: a request-scoped sessions controller
- **WHEN** `@Scoped(seed: HTTPRequest.self) @Controller("/sessions") struct Sessions` declares `@Get("/{id}") @JSONResponse func get(@Path id: String) async throws -> Session`
- **THEN** the witness contains `let wireMVCScopeEntry = try await self._wireEnterScope(request)` and no diagnostic is reported

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerConstructsPerRequestViaScopeEntry`).

### Requirement: On a route with middleware, scope entry follows the middleware fold
On a typed route of a `@Scoped(seed:)` controller that carries `@Middleware`, the terminal body, and
with it the scope entry, SHALL run inside `wireMVCFinalBox.withPendingContents` after the whole
middleware fold, and the seed SHALL be the request the final middleware box carries, which a middleware
may have replaced through `RequestResponseMiddlewareBox.pending(request:...)`.

#### Scenario: a scoped controller behind a middleware
- **WHEN** a `@Scoped(seed: HTTPRequest.self) @Controller` carries `@Middleware(Gate.self)` and a request reaches one of its typed routes
- **THEN** `Gate` runs before `_wireEnterScope` is called, and the scope is seeded from the `request` that `wireMVCFinalBox.withPendingContents` yields

Pinned by: nothing yet.

### Requirement: The route dispatches on the per-request controller, never a held subject
The witness SHALL read the controller off the entry by name, `let wireMVCController =
wireMVCScopeEntry._wireSubject`, and call the handler on `wireMVCController`. A scoped controller's
witness SHALL NOT reference `self._wireSubject`. The names `_wireEnterScope`, `_wireSubject` and
`_wireScopeTeardown` SHALL be `contributorProxyScopeEntryAccessor`, `wireScopeEntrySubjectField` and
`wireScopeEntryTeardownField`.

#### Scenario: the handler call
- **WHEN** the `Sessions` witness is rendered
- **THEN** it contains `let wireMVCController = wireMVCScopeEntry._wireSubject` and `try await wireMVCController.get(id: id)`, and does not contain `self._wireSubject`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerConstructsPerRequestViaScopeEntry`).

### Requirement: An unscoped controller is held and enters no scope
The production witness of a controller with no `@Scoped(seed:)` attribute SHALL call the handler
through the proxy's held `self._wireSubject`, and SHALL contain no `_wireEnterScope` call. The variant
witness a keyed test harness generates for an app-`@Singleton` `@TestScopable` controller does enter
scope, with `_wireEnterScope(wireMVCDoubles)`, as [testing-harness](../testing-harness/spec.md)
specifies.

#### Scenario: a singleton controller
- **WHEN** `@Controller("/x") @Middleware(ControllerGate.self) struct Gated` declares `@Middleware(RouteGate.self) @Get("/y") @ResponseStatus(.noContent) func f() async throws`
- **THEN** the witness calls `try await self._wireSubject.f()`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`controllerAndRouteByTypeMiddlewareOrder`). The absence of a `_wireEnterScope` call is pinned by nothing yet.

### Requirement: Scope entry runs inside the mapped region
On a typed route, the scope-entry lines SHALL be emitted inside the terminal's `building:` closure,
ahead of the parameter binds and the handler call, so a throw from constructing a request-scoped
binding SHALL be mapped by the route's `errorMapping` like a handler throw.

#### Scenario: a scoped controller with an error mapping
- **WHEN** `@Scoped(seed: HTTPRequest.self) @Controller("/me") @ErrorResponse(Unauthenticated.self, .unauthorized) struct Me` is rendered
- **THEN** `let wireMVCScopeEntry = try await self._wireEnterScope(request)` appears after `building: {`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerScopeEntryInsideDoWhenMapped`), `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theBindComesAfterTheScopeEntryThatProducesIt`, for a bind following the entry). That a throw from scope entry is actually mapped by `errorMapping` at runtime is pinned by nothing yet.

### Requirement: Teardown runs in an async `defer` when the `building:` closure ends
Immediately after scope entry the witness SHALL bind `let wireMVCScopeTeardown =
wireMVCScopeEntry._wireScopeTeardown` and declare `defer { _ = await wireMVCScopeTeardown() }`. On a
typed route this `defer` SHALL sit in the `building:` closure, so the teardown SHALL run when that
closure returns or throws, before the terminal drains the response headers and sends the response.
Because the `defer` is declared after entry, a throw from entry itself SHALL skip it. The teardown's
result SHALL be discarded.

#### Scenario: the generated teardown
- **WHEN** the `Sessions` witness is rendered
- **THEN** it contains `let wireMVCScopeTeardown = wireMVCScopeEntry._wireScopeTeardown`, `defer {` and `_ = await wireMVCScopeTeardown()`

#### Scenario: `@Teardown` fires once per request
- **WHEN** `WhoAmIController` injects a `@Scoped(seed: HTTPRequest.self)` `RequestResource` whose `@Teardown func close()` increments a probe, and the example sends two `GET /whoami` requests
- **THEN** the probe reads at least `2`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerConstructsPerRequestViaScopeEntry`), `Fixtures/Sources/WireMVCExample/main.swift` (the `@Teardown on a @Scoped binding` check, run by the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`). The ordering of teardown before the send and the skip on a throwing entry are pinned by nothing yet.

### Requirement: A streamed body is written after the request scope is torn down
On a streaming route of a `@Scoped(seed:)` controller, `building:` returns a `WireMVCStreamingOutcome`
and the terminal writes the body through its producer only after that, so the request scope, including
any `@Teardown` on a request-scoped binding, SHALL already be torn down while the body is written. This
is tracked for investigation in https://github.com/swift-wire/wire-mvc/issues/234.

#### Scenario: a producer that captured a request-scoped value
- **WHEN** a streaming handler on a `@Scoped(seed: HTTPRequest.self)` controller returns a producer that captured a request-scoped binding with a `@Teardown`
- **THEN** that `@Teardown` runs when `building:` returns, before `producer.writeBody(into:terminatedBy:)` is called

Pinned by: nothing yet.

### Requirement: Request-scoped values are fresh per request, singletons are shared
A scoped controller's request-scoped dependencies SHALL be constructed from each request's seed, and
its `@Singleton` dependencies SHALL resolve to the one app-scoped instance.

#### Scenario: two requests to `/whoami`
- **WHEN** the example sends `GET /whoami?who=ada` and `GET /whoami?who=grace`
- **THEN** both answer `200`, each `RequestInfo.path` is its own request's path, and both resolve the `@Singleton` `UserStore`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `@Scoped(seed:) @Controller` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`). That both requests receive the same `UserStore` instance is pinned by nothing yet: `UserStore` is stateless, so the check cannot tell one instance from two.

### Requirement: Entering one controller's scope constructs only its reachable subgraph
The `_wireEnterScope` a scoped controller's witness calls is swift-wire's generated scope-entry thunk,
which constructs only the request-scoped bindings reachable from that controller (see
[swift-wire seeded-scopes](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/seeded-scopes/spec.md)).
In a WireMVC application, a sibling controller seeded on the same type SHALL therefore NOT have its
request-scoped bindings constructed or torn down by another controller's requests.

#### Scenario: two controllers sharing the `HTTPRequest` seed
- **WHEN** the example serves two `GET /whoami` requests and then one `GET /other`, where only `OtherController` reaches `OtherResource` and only `WhoAmIController` reaches `RequestResource`
- **THEN** `OtherResource`'s teardown probe is `0` after the `/whoami` requests and `1` after `/other`, and `RequestResource`'s probe is unchanged by `/other`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `@Scoped per-root reachability` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: The unkeyed `Logger` in request scope is the request logger
When the target depends on the WireMVCLogging product, an unkeyed `@Inject var logger: Logger` on a
`@Scoped(seed: HTTPRequest.self)` controller SHALL resolve to the request-scoped logger WireMVCLogging binds, carrying that request's id under
`WireMVCLogMetadata.requestID`.

#### Scenario: two requests, two ids
- **WHEN** `WhoAmIController` reads `logger[metadataKey: WireMVCLogMetadata.requestID]` on two requests and also injects `@Inject(WireMVCRequest.id) var requestID: String`
- **THEN** each logger's request id is non-empty, equals that request's injected id, and differs between the two requests

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `WireMVCLogging` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

## Related specifications

- [controllers-and-routes](../controllers-and-routes/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
- [graph-aware-bindings](../graph-aware-bindings/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [middleware](../middleware/spec.md)
- [logging](../logging/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [swift-wire seeded-scopes](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/seeded-scopes/spec.md)
- [swift-wire scope-entry-and-generated-names](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/scope-entry-and-generated-names/spec.md)
