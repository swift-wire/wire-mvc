# Request scope

## Purpose

A controller declared `@Scoped(seed: HTTPRequest.self) @Controller` is constructed per request
rather than held. Its generated route-contributor proxy stays app-scoped and collated once; each route
of its witness enters the controller's request scope with the request as seed, dispatches on the
controller that entry returns, and tears the scope down when the route's work ends. The seeded-scope
semantics themselves (what a scope entry constructs, teardown ordering, the generated names) are
swift-wire's and are specified there.

Rationale: [WireMVCAbstraction](../../../Documentation/Notes/WireMVCAbstraction.md), [ScopeAwareMiddlewareAndBindings](../../../Documentation/Notes/ScopeAwareMiddlewareAndBindings.md).
Documentation: [RequestScope](../../../Sources/WireMVC/WireMVC.docc/RequestScope.md).

## Requirements

### Requirement: A seeded controller enters its scope per request with the request as seed
For a controller carrying `@Scoped(seed: S.self)`, every typed route of the generated witness SHALL
begin its per-request work with `let wireMVCScopeEntry = try await self._wireEnterScope(request)`,
passing the register closure's `request`.

#### Scenario: a request-scoped sessions controller
- **WHEN** `@Scoped(seed: HTTPRequest.self) @Controller("/sessions") struct Sessions` declares `@Get("/{id}") @JSONResponse func get(@Path id: String)`
- **THEN** the witness contains `let wireMVCScopeEntry = try await self._wireEnterScope(request)` and no diagnostic is reported

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerConstructsPerRequestViaScopeEntry`).

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
A controller with no `@Scoped(seed:)` attribute SHALL be called through the proxy's held
`self._wireSubject`, and its witness SHALL contain no `_wireEnterScope` call.

#### Scenario: a singleton controller
- **WHEN** `@Controller("/x") @Middleware(ControllerGate.self) struct Gated` declares `@Get("/y") func f()`
- **THEN** the witness calls `try await self._wireSubject.f()`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`controllerAndRouteByTypeMiddlewareOrder`).

### Requirement: Scope entry runs inside the mapped region
On a typed route, the scope-entry lines SHALL be emitted inside the terminal's `building:` closure,
ahead of the parameter binds and the handler call, so a throw from constructing a request-scoped
binding SHALL be mapped by the route's `errorMapping` like a handler throw.

#### Scenario: a scoped controller with an error mapping
- **WHEN** `@Scoped(seed: HTTPRequest.self) @Controller("/me") @ErrorResponse(Unauthenticated.self, .unauthorized) struct Me` is rendered
- **THEN** `let wireMVCScopeEntry = try await self._wireEnterScope(request)` appears after `building: {`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerScopeEntryInsideDoWhenMapped`).

### Requirement: Teardown runs in an async `defer` when the route's work ends
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

### Requirement: Request-scoped values are fresh per request, singletons are shared
A scoped controller's request-scoped dependencies SHALL be constructed from each request's seed, and
its `@Singleton` dependencies SHALL resolve to the one app-scoped instance.

#### Scenario: two requests to `/whoami`
- **WHEN** the example sends `GET /whoami?who=ada` and `GET /whoami?who=grace`
- **THEN** both answer `200`, each `RequestInfo.path` is its own request's path, and both report the shared `UserStore`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `@Scoped(seed:) @Controller` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: Entering one controller's scope constructs only its reachable subgraph
Scope entry for a scoped controller SHALL construct only the request-scoped bindings reachable from
that controller. A sibling controller seeded on the same type SHALL NOT have its request-scoped
bindings constructed or torn down by another controller's requests.

#### Scenario: two controllers sharing the `HTTPRequest` seed
- **WHEN** the example serves two `GET /whoami` requests and then one `GET /other`, where only `OtherController` reaches `OtherResource` and only `WhoAmIController` reaches `RequestResource`
- **THEN** `OtherResource`'s teardown probe is `0` after the `/whoami` requests and `1` after `/other`, and `RequestResource`'s probe is unchanged by `/other`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `@Scoped per-root reachability` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: The unkeyed `Logger` in request scope is the request logger
An unkeyed `@Inject var logger: Logger` on a `@Scoped(seed: HTTPRequest.self)` controller SHALL
resolve to the request-scoped logger WireMVCLogging binds, carrying that request's id under
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
