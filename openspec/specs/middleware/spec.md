# Middleware

## Purpose

How WireMVC folds `Middleware` around a request. It covers the box every chain carries
(`RequestResponseMiddlewareBox`), the rule that a middleware answers a request by writing rather than
by skipping `next`, the `@Middleware` annotation at global, controller and route scope, the three
forms it takes (by type, by binding key, by `@Factory` key), the `@MiddlewareFactory` role mapping,
and the global front layer (`GlobalMiddlewareHandler`) that wraps the finalized router.

Rationale: [WireMVCMiddleware](../../../Documentation/Notes/WireMVCMiddleware.md), [ScopeAwareMiddlewareAndBindings](../../../Documentation/Notes/ScopeAwareMiddlewareAndBindings.md), [LinearSenderErrorModel](../../../Documentation/Notes/LinearSenderErrorModel.md).
Documentation: [UsingMiddleware](../../../Sources/WireMVC/WireMVC.docc/UsingMiddleware.md).

## Requirements

### Requirement: The box is a two-state `~Copyable` value
`RequestResponseMiddlewareBox<RequestContext, Reader, ResponseSender>` SHALL be a `~Copyable` struct
that is explicitly not `Sendable`, whose state is either `pending` (the request, the request context,
the optional `RouteContext`, the reader, the one-shot response sender and the `ResponseHeaderRegistry`)
or `responded` (the request and the optional `RouteContext` only). `isPending` SHALL report which, and
`peekedRequest` and `peekedRoute` SHALL be readable in either state.

#### Scenario: a gate's response leaves the request and the route readable
- **WHEN** a pending box for route `/documents/{id}` is answered with `respondingWith(.status(.unauthorized))`
- **THEN** the returned box has `isPending == false`, `peekedRoute` still equals the matched route, and the recorded response head is `401`

Pinned by: `Tests/WireMVCResponsesTests/RouteContextTests.swift` (`aGatesOwnResponseKeepsTheRoute`, `withContentsYieldsTheRouteOnTheRespondedBranch`).

### Requirement: `pending(...)` requires the route and the registry
`RequestResponseMiddlewareBox.pending(request:requestContext:route:reader:responseSender:responseHeaders:)`
SHALL take `route: RouteContext?` and `responseHeaders: consuming sending ResponseHeaderRegistry` as
required arguments with no default, and `responded(request:route:)` SHALL take the route as well.

#### Scenario: the generated fold builds the base box
- **WHEN** a route at `/x/y` carries one `@Middleware`
- **THEN** its register closure contains `RequestResponseMiddlewareBox.pending(request: request, requestContext: wireMVCBaseContext, route: wireMVCRoute, reader: reader, responseSender: responseSender, responseHeaders: wireMVCFoldRegistry)`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`middlewareFactoryKeyFold`).

### Requirement: `peekedRoute` names the matched template, and is `nil` above the router
`RouteContext` SHALL carry `template`, the path the route was registered under, and `pathParameters`,
the router's match. A route fold SHALL build its box with `RouteContext(template:pathParameters:)` from
the registration path and the register closure's path parameters. The global front layer SHALL build
its box with `route: nil`, and a matched route with no parameters SHALL report a non-`nil`
`RouteContext` with empty `pathParameters`.

#### Scenario: one controller-scope fold on two routes
- **WHEN** a controller-scope middleware reports `peekedRoute?.template` and requests go to `/ping` and `/ping/echo/other`
- **THEN** it reports `/ping` and `/ping/echo/{name}` respectively

#### Scenario: the global tier
- **WHEN** a global middleware reports whether `peekedRoute` is `nil` for `/ping`, `/ping/echo/world`, `/gated` and `/no/such/route`
- **THEN** it reports `nil` for all four

#### Scenario: no route versus no parameters
- **WHEN** one box is built with `route: nil` and another with `RouteContext(template: "/ping", pathParameters: [:])`
- **THEN** the first has `peekedRoute == nil` and the second has a non-`nil` route with empty `pathParameters`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aFoldedMiddlewareSeesTheMatchedTemplateAndParameters`, `oneFoldReportsADifferentRoutePerRoute`, `aRouteWithNoParametersIsNotTheSameAsNoRoute`, `theGlobalTierNeverSeesARoute`), `Tests/WireMVCResponsesTests/RouteContextTests.swift` (`aMatchedRouteCarriesItsTemplateAndParameters`, `noRouteIsNotTheSameAsARouteWithNoParameters`).

### Requirement: A middleware responds by writing, not by skipping `next`
A middleware that answers a request itself SHALL do so by calling `responding(_:)` or
`respondingWith(_:)` on the box, which consume the sender and return a `responded` box, and SHALL then
pass that box to `next`. Called on a box that is already `responded`, both SHALL return a `responded`
box without writing.

#### Scenario: a route-scope admin gate
- **WHEN** `DELETE /users/99` arrives without `x-admin: true` on a route carrying `@Middleware(RequireAdminKeys.factory)`, whose middleware calls `next(input.responding { … HTTPResponse(status: .forbidden) … })`
- **THEN** the response is `403` and the handler does not run

#### Scenario: the gate forwards
- **WHEN** the same route receives `x-admin: true`
- **THEN** the handler runs and the response is `204`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `DELETE /users/42` and `DELETE /users/99` checks, run by the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`), `Tests/WireMVCResponsesTests/RouteContextTests.swift` (`aRawResponseKeepsTheRoute`).

### Requirement: `respondingWith` drains contributed header fields; `responding` does not
`respondingWith(_ outcome: WireMVCOutcome)` SHALL drain the box's `ResponseHeaderRegistry` into the
outcome's header fields through `WireMVCResponseHeaders.resolved(returned:middleware:)` before sending
it. `responding(_:)` SHALL hand the raw sender to its closure and SHALL NOT drain the registry.

#### Scenario: a gate's 401 carries a global contribution
- **WHEN** a gate answers `GET /gated` with `respondingWith` and a global middleware contributed `x-stamp: global`
- **THEN** the response is `401` carrying both the gate's `WWW-Authenticate: Bearer realm="fixture"` and `x-stamp: global`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aGateResponseCarriesContributedFields`). The raw `responding(_:)` discarding the registry is pinned by nothing yet.

### Requirement: `contributing` adds header fields and forwards
`contributing(_:then:)` SHALL, on a `pending` box, hand the registry `inout` to its first closure and
pass a rebuilt `pending` box carrying the same request, context, route, reader and sender to `then`. On
a `responded` box it SHALL NOT call the first closure and SHALL pass the `responded` box to `then`
unchanged.

#### Scenario: the route survives the rebuild
- **WHEN** a pending box for `/documents/{id}` calls `contributing { headers in headers.add(.set(.init("x-test")!, "1")) } then: { $0.peekedRoute }`
- **THEN** the route returned equals the matched route

#### Scenario: two scopes both contribute
- **WHEN** a global middleware contributes `x-stamp` and a controller-scope middleware contributes `x-controller` on `GET /ping`
- **THEN** the response carries both fields

Pinned by: `Tests/WireMVCResponsesTests/RouteContextTests.swift` (`contributingCarriesTheRouteIntoTheRebuiltBox`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`globalAndControllerContributionsBothArrive`). The `responded` branch is pinned by nothing yet.

### Requirement: The terminal runs through `withPendingContents` and no-ops on `responded`
`withPendingContents(_:)` SHALL call its handler with the request, context, route, reader, sender and
registry of a `pending` box, and SHALL do nothing for a `responded` box. The generated route terminal
SHALL be reached only through `withPendingContents` on the chain's final box.

#### Scenario: the generated terminal
- **WHEN** a route carries one `@Middleware`
- **THEN** the register closure calls `try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in return try await wireMVCFinalBox.withPendingContents { … } }` and the handler call sits inside that closure

#### Scenario: the terminal reads the final box's route
- **WHEN** `withPendingContents` is called on a pending box for `/documents/{id}`
- **THEN** its handler receives that `RouteContext` as the third argument

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`middlewareFactoryKeyFold`), `Tests/WireMVCResponsesTests/RouteContextTests.swift` (`withPendingContentsYieldsTheRoute`), `Fixtures/Sources/WireMVCExample/main.swift` (the `DELETE /users/99` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: Each route's chain is folded inline with `wireCompose`
`wireCompose(_:)` SHALL take a `@MiddlewareBuilder` closure and return the concrete composed
`Middleware` it builds. The generated register closure for a route with middleware SHALL bind
`let wireMVCChain = wireCompose { … }` listing one fold entry per `@Middleware`. A route with no
middleware SHALL register without a box, a chain or `withPendingContents`.

#### Scenario: a route with one factory middleware
- **WHEN** `@Controller("/x") @Middleware(Keys.session) struct C` declares `@Get("/y")` and `Keys.session` is a factory key
- **THEN** the witness binds `let wireMVCChain = wireCompose {` with the single entry `self._wireFactory_Keys_session.create(Builder.RequestContext.Base.self, Builder.Reader.self, Builder.ResponseSender.self)`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`middlewareFactoryKeyFold`).

### Requirement: Controller-scope middleware wraps route-scope middleware
The generated fold for a route SHALL list the controller's `@Middleware` entries, in written order,
before the route's own `@Middleware` entries, so that controller-scope middleware runs outside
route-scope middleware and both run outside the handler.

#### Scenario: a controller gate and a route gate
- **WHEN** `@Controller("/x") @Middleware(ControllerGate.self) struct Gated` declares `@Middleware(RouteGate.self) @Get("/y") func f()`
- **THEN** `self._wireControllerGate` appears before `self._wireRouteGate` in the witness, and the fold ends in `try await self._wireSubject.f()`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`controllerAndRouteByTypeMiddlewareOrder`).

### Requirement: The by-type form reads a graph binding off the proxy
On a controller or route, `@Middleware(T.self)` SHALL fold `self._wire<T>`, where `<T>` is the simple
type name with generics and namespace stripped and its first letter upper-cased, a field the build
plugin lifts onto the controller's route-contributor proxy. The middleware SHALL NOT be constructed
inline.

#### Scenario: a by-type route gate
- **WHEN** a route carries `@Middleware(RouteGate.self)`
- **THEN** the fold entry is `self._wireRouteGate`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`controllerAndRouteByTypeMiddlewareOrder`).

### Requirement: The binding-key form reads a keyed graph binding
On a controller or route, `@Middleware(key)` where `key` names no `@Factory` template SHALL fold
`self._wire<key>`, with every character of the key's text outside `[A-Za-z0-9_]` replaced by `_`, and
SHALL NOT call a factory's `create`.

#### Scenario: a dotted binding key
- **WHEN** `@Controller("/x") @Middleware(Gates.primary) struct C` is rendered with no factory keys
- **THEN** the witness contains `self._wireGates_primary` and contains neither `_wireFactory_` nor `.create(`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`middlewareBindingKeyFold`).

### Requirement: The factory-key form creates the middleware at the builder's box types
On a controller or route, `@Middleware(key)` where `key` names a `@Factory` template SHALL fold
`self._wireFactory_<key>.create(Builder.RequestContext.Base.self, Builder.Reader.self,
Builder.ResponseSender.self)`, with the key text sanitised as for the binding-key form.

#### Scenario: `Keys.session`
- **WHEN** a controller carries `@Middleware(Keys.session)` and `Keys.session` is a factory key
- **THEN** the fold entry is `self._wireFactory_Keys_session.create(Builder.RequestContext.Base.self, Builder.Reader.self, Builder.ResponseSender.self)`

#### Scenario: three factory middleware on a served controller
- **WHEN** `UsersController` carries `@Middleware(RequestLogMiddlewareKeys.factory)`, `@Middleware(SessionMiddlewareKeys.factory)` and `@Middleware(AuditMiddlewareKeys.factory)`
- **THEN** the request-log and audit probes each count at least one request after the example has driven its routes

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`middlewareFactoryKeyFold`), `Fixtures/Sources/WireMVCExample/main.swift` (run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: `@MiddlewareFactory` requires `@Factory` on the same type
`@MiddlewareFactory` SHALL be an attached peer macro implemented by `MiddlewareFactoryMacro` that
expands to nothing. When the type it is attached to carries no `@Factory` attribute it SHALL emit the
error `middlewareFactoryRequiresFactory`.

#### Scenario: with `@Factory`
- **WHEN** `@Factory(Keys.factory) @MiddlewareFactory struct Mw {}` is expanded
- **THEN** the result is `@Factory(Keys.factory) struct Mw {}` with no diagnostic

#### Scenario: without `@Factory`
- **WHEN** `@MiddlewareFactory(.responseSender) struct Mw {}` is expanded
- **THEN** the macro reports at line 1, column 1: "@MiddlewareFactory requires @Factory on the same type — it supplies the box-role mapping for a factory template. Add @Factory(key) to make this a Wire factory template."

Pinned by: `Tests/WireMVCMacrosTests/MiddlewareFactoryMacroTests.swift` (`testNoOpWhenFactoryPresent`, `testDiagnosesWithoutFactory`).

### Requirement: `@MiddlewareFactory` maps assisted generic parameters to box roles
`MiddlewareRole` SHALL have the cases `requestContext`, `reader` and `responseSender`. Bare
`@MiddlewareFactory` SHALL map a factory template's assisted generic parameters positionally to
request context, reader and response sender, and `@MiddlewareFactory(.role, …)` SHALL map them to the
listed roles in order.

#### Scenario: a reordered middleware
- **WHEN** `AuditMiddleware<Sender, Reader, Ctx>` is declared `@MiddlewareFactory(.responseSender, .reader, .requestContext)` and folded on `UsersController`
- **THEN** the example builds, and its audit probe counts at least one request

Pinned by: `Fixtures/Sources/WireMVCExample/AuditMiddleware.swift` and `Fixtures/Sources/WireMVCExample/main.swift` (the `@MiddlewareFactory` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: Global `@Middleware` must be factory-form
On a `@WireMVCBootstrap` root, a `@Middleware` whose argument is not a declared `@Factory` key SHALL
be diagnosed with `globalMiddlewareUnsupportedArgument`, carrying the argument text, and SHALL
contribute no fold entry.

#### Scenario: a by-type global middleware
- **WHEN** `@WireMVCBootstrap @Middleware(AccessLog.self) struct AppBootstrap` is rendered with no factory keys
- **THEN** one diagnostic is reported, "global @Middleware on a @WireMVCBootstrap root must be factory-form (@Middleware(Key), a generic-over-box @Factory @MiddlewareFactory) — a by-type or keyed-binding middleware ('AccessLog.self') is concrete over a fixed box and can't compose in the global chain (the router is fixed on its box type). Write it generic (factory-form), or scope it to a @Controller.", and the rendered source contains no `GlobalMiddlewareHandler`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`globalMiddlewareByTypeFormIsDiagnosed`).

### Requirement: Global middleware folds once around the finalized router
WireMVCRouteGen SHALL emit `extension _WireGlobalMiddleware_<Root>` with a
`wrapGlobalMiddleware<Handler: HTTPServerRequestHandler>(_ inner: Handler)` that returns
`GlobalMiddlewareHandler(inner: inner, chain: wireCompose { … })` over the root's factory entries in
written order, each `self._wireFactory_<key>.create(Handler.RequestContext.Base.self,
Handler.Reader.self, Handler.ResponseSender.self)`, or returns `inner` when there are none. The
generated entry SHALL call it once, on the result of `builder.finalize()`.

#### Scenario: two global factories
- **WHEN** `@WireMVCBootstrap @Middleware(LoggingKeys.accessLog) @Middleware(LoggingKeys.requestID) struct AppBootstrap` is rendered
- **THEN** the extension contains `GlobalMiddlewareHandler(inner: inner, chain: wireCompose {` with both `create` calls and no diagnostic

#### Scenario: no global middleware
- **WHEN** the root carries no `@Middleware`
- **THEN** `wrapGlobalMiddleware` is still emitted and the source contains no `GlobalMiddlewareHandler`

#### Scenario: the entry wraps the frozen router
- **WHEN** WireMVCRouteGen renders the `@main` for `AppBootstrap`
- **THEN** it contains `let wireMVCServed = graph._WireGlobalMiddleware_AppBootstrap.wrapGlobalMiddleware(handler)`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`globalMiddlewareProxyWrapsRouterWithFactories`, `globalMiddlewareProxyIdentityWhenEmpty`, `bootstrapEntryGeneratesMain`).

### Requirement: Global middleware is non-transforming
`GlobalMiddlewareHandler<Inner, Chain>` SHALL require `Chain.Input ==
RequestResponseMiddlewareBox<Inner.RequestContext.Base, Inner.Reader, Inner.ResponseSender>` and
`Chain.NextInput == Chain.Input`. Its `handle` SHALL build the box from the courier's base and
registry, run the chain, and in the terminal rebuild the courier from the final box's base and registry
and call `inner.handle`.

#### Scenario: a non-transforming access log
- **WHEN** `AccessLog<Ctx, Reader, Sender>` declares `typealias NextInput = Input` and is the root's `@Middleware(AccessLogKeys.factory)`
- **THEN** the `WireMVCBootstrapExample` fixture builds and serves

Pinned by: `Fixtures/Sources/WireMVCBootstrapExample/AccessLog.swift` (built by the `Build fixtures` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: Global middleware covers matched routes, 404 and 405
Because the front layer wraps the router's `handle`, a global middleware SHALL run, and its header
contributions SHALL reach the response, for a matched route, for the `@NotFound` or synthesised 404
fallback, and for a 405 answered by `registerMethodNotAllowed`.

#### Scenario: the boot probe
- **WHEN** CI boots `WireMVCBootstrapExample` and requests `/hello/ci` and `/nope`
- **THEN** the server log contains `access: GET /hello/ci` and `access: GET /nope`

#### Scenario: synthesised 404 and 405
- **WHEN** the fallback fixture receives `GET /no/such/route` and `DELETE /ping`
- **THEN** the responses are `404` and `405` (with `Allow: GET`), each carrying `x-stamp: global`

Pinned by: `.github/workflows/build.yml` (`BuildAndRun`, step `Run @WireMVCBootstrap example (boot, probe, stop)`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`matchedRouteCarriesTheGlobalHeader`, `synthesisedNotFoundCarriesTheGlobalHeader`, `aMethodNotAllowedCarriesTheGlobalHeader`).

### Requirement: `@Middleware` on `mountIntrospectionAt` guards only the introspection route
A `@Middleware` factory on the root's `mountIntrospectionAt()` SHALL be folded only around the
introspection route, through a generated `registerIntrospection<Builder>(into:at:response:)` on the
global-middleware proxy, and SHALL NOT be folded around other routes.

#### Scenario: the guard fires on `/wiring` only
- **WHEN** CI boots `WireMVCBootstrapExample`, whose `mountIntrospectionAt` carries `@Middleware(IntrospectionGuardKeys.factory)`, and requests `/hello/ci` and `/wiring`
- **THEN** the log contains `introspection-guard: /wiring` and no `introspection-guard: /hello` line

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`guardedIntrospectionFoldsGuardMiddleware`), `.github/workflows/build.yml` (`BuildAndRun`, step `Run @WireMVCBootstrap example (boot, probe, stop)`).

### Requirement: A middleware throw is not mapped by `@ErrorResponse`
The route's error mapping SHALL be applied only inside the terminal reached through
`withPendingContents`. An error thrown from a middleware's `intercept` SHALL propagate out of the
register closure without passing through any `@ErrorResponse` mapping.

#### Scenario: the mapping sits inside the terminal
- **WHEN** a route with one `@Middleware` is rendered
- **THEN** the `errorMapping:` closure appears only inside the `withPendingContents` closure, not around `wireMVCChain.intercept`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`middlewareFactoryKeyFold`).

### Requirement: Global factory middleware does not thread per-request doubles
The global fold SHALL emit the box-role-only `create(…)` for every factory key, including one whose
factory consumes a `@BindType`'d slot under a keyed test suite. This gap is tracked by
https://github.com/swift-wire/wire-mvc/issues/165.

#### Scenario: a global factory under a variant
- **WHEN** a root's global `@Middleware(key)` names a factory whose `create` would take doubles under a keyed harness
- **THEN** `wrapGlobalMiddleware` still emits `self._wireFactory_<key>.create(Handler.RequestContext.Base.self, Handler.Reader.self, Handler.ResponseSender.self)`

Pinned by: nothing yet.

## Related specifications

- [controllers-and-routes](../controllers-and-routes/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
- [composition-root](../composition-root/spec.md)
- [response-headers](../response-headers/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [request-scope](../request-scope/spec.md)
- [graph-aware-bindings](../graph-aware-bindings/spec.md)
- [testing-harness](../testing-harness/spec.md)
- [swift-wire adapter-annotations](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/adapter-annotations/spec.md)
