# Error response tiers

## Purpose

How a throw from a typed route becomes an HTTP response. `@ErrorResponse` declares a mapping from an
error type to a response at route, controller or composition-root scope. WireMVCRouteGen folds the
mappings of all three tiers, the built-in `WireMVCBindingError` mapping, an optional `Swift.Error`
catch-all and a built-in `500` into one consultation chain, passed as the `errorMapping:` closure of
the route's generated terminal. The terminal writes the mapped response itself, so an unmapped throw
is answered rather than escaping to the server.

Rationale: [RouteErrorHandling](../../../Documentation/Notes/RouteErrorHandling.md), [LinearSenderErrorModel](../../../Documentation/Notes/LinearSenderErrorModel.md).
Documentation: [ErrorHandling](../../../Sources/WireMVC/WireMVC.docc/ErrorHandling.md).

## Requirements

### Requirement: The status form maps an error type to a status
`@ErrorResponse(E.self, .status)` SHALL add the chain element `(wireMVCError is E ?
WireMVCOutcome.status(.status) : nil)`, which answers a thrown `E` with that status and no body and
falls through for any other error.

#### Scenario: a controller-scope shorthand
- **WHEN** `@Controller("/users") @ErrorResponse(NotFound.self, .notFound) struct Users` declares `@Get("/{id}") @JSONResponse func get(@Path id: String)`
- **THEN** the route's `errorMapping: { wireMVCError in` closure contains `(wireMVCError is NotFound ? WireMVCOutcome.status(.notFound) : nil)` and no diagnostic is reported

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`controllerScopeStatusShorthandCoversRoute`).

### Requirement: The body form encodes the closure's value as JSON with the given status
`@ErrorResponse(E.self, .status, { e in Body })` SHALL add the chain element
`wireMVCRespond(to: wireMVCError, as: E.self, status: .status, (closure))`, which for a thrown `E`
returns `.json(body(e), status: status)` and otherwise returns `nil`.

#### Scenario: a user that is not found
- **WHEN** `UsersController` declares `@ErrorResponse(UserStore.NotFound.self, .notFound, { _ in APIError(message: "user not found") })` and a client requests `GET /users/999`
- **THEN** the response is `404` and its JSON body decodes to `APIError(message: "user not found")`

Pinned by: `Fixtures/Sources/WireMVCExample/main.swift` (the `GET /users/999` check, run by the `Run end-to-end example` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: The closure form maps through a typed-parameter closure returning an outcome
`@ErrorResponse({ (e: E) in … })` SHALL take `E` from the closure's annotated parameter type and add
the chain element `wireMVCRespond(to: wireMVCError, (closure))`, which returns the closure's
`WireMVCOutcome` for a thrown `E` and `nil` otherwise. A chain containing a closure element SHALL be
prefixed with `try`.

#### Scenario: a validation error
- **WHEN** a route declares `@ErrorResponse({ (e: ValidationError) in try .json(Problem(e.message), status: .unprocessableContent) })`
- **THEN** the witness contains `wireMVCRespond(to: wireMVCError, ({ (e: ValidationError) in`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`inlineClosureMapping`, `routeClosureOverridesController`, `catchAllClosureIsTerminal`). The `try` prefix is pinned only by `catchAllClosureIsTerminal`, whose closure element is a catch-all; for a chain whose only closure element is a typed mapping it is pinned by nothing yet.

### Requirement: An untyped closure parameter is diagnosed
A closure-form `@ErrorResponse` whose parameter has no type annotation SHALL be diagnosed with
`errorResponseClosureNeedsTypedParameter` and SHALL contribute no chain element.

#### Scenario: `{ e in … }`
- **WHEN** a route declares `@ErrorResponse({ e in .status(.internalServerError) })`
- **THEN** WireMVCRouteGen reports "@ErrorResponse closure needs a typed parameter — spell the error type, e.g. { (e: NotFound) in … }, so the mapping matches on it"

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`untypedClosureParameterIsDiagnosed`).

### Requirement: A named-function reference is diagnosed
An `@ErrorResponse` argument that is neither a closure nor an `E.self` type followed by a status
SHALL be diagnosed with `errorResponseUnresolvedMapping`, carrying the argument text, and SHALL
contribute no chain element.

#### Scenario: a static method reference
- **WHEN** a route declares `@ErrorResponse(SharedErrors.handleNotFound)`
- **THEN** WireMVCRouteGen reports "@ErrorResponse named-function reference 'SharedErrors.handleNotFound' is not supported yet — a reference to the controller's own method is a circular macro reference, and a separate type needs cross-module resolution. Use an inline typed-parameter closure: @ErrorResponse({ (e: SomeError) in … })"

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`unresolvedStaticReferenceIsDiagnosed`).

### Requirement: One mapping per error type per scope
Two `@ErrorResponse` entries naming the same error type at one scope SHALL be diagnosed with
`errorResponseDuplicateType`, carrying the type and the scope label (`route`, `controller` or
`bootstrap`). The same type at two different scopes SHALL NOT be diagnosed.

#### Scenario: `NotFound` twice on a controller
- **WHEN** a controller declares `@ErrorResponse(NotFound.self, .notFound)` and `@ErrorResponse(NotFound.self, .gone)`
- **THEN** WireMVCRouteGen reports "@ErrorResponse maps 'NotFound' more than once at controller scope — each error type needs a distinct mapping at a scope (a route entry overrides a controller entry for the same type)"

#### Scenario: the same type on a route and its controller
- **WHEN** a controller maps `NotFound` to `.notFound` and one of its routes maps `NotFound` with a closure
- **THEN** no diagnostic is reported

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`duplicateErrorTypeAtOneScopeIsDiagnosed`, `routeClosureOverridesController`).

### Requirement: A catch-all must be the last entry at its scope
A mapping whose error type's last component, after any `any ` prefix, is `Error` SHALL be a
catch-all. An `@ErrorResponse` entry written after a catch-all at the same scope SHALL be diagnosed
with `errorResponseCatchAllNotLast`, carrying the scope label.

#### Scenario: a typed entry after the catch-all
- **WHEN** a controller declares `@ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })` followed by `@ErrorResponse(NotFound.self, .notFound)`
- **THEN** WireMVCRouteGen reports "the @ErrorResponse Swift.Error catch-all must be the last error entry at controller scope — a mapping listed after it can never be reached"

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`catchAllNotLastIsDiagnosed`).

### Requirement: Typed mappings are consulted route, then controller, then global
The chain SHALL list the non-catch-all mappings of the route, then of the controller, then of the
`@WireMVCBootstrap` root, each in written order, joined with `??` so the first non-`nil` element
answers.

#### Scenario: a route closure ahead of the controller's status
- **WHEN** a controller maps `NotFound` to `.notFound` and its route maps `NotFound` with `{ (e: NotFound) in .status(.gone) }`
- **THEN** `wireMVCRespond(to: wireMVCError, ({ (e: NotFound) in` appears before `(wireMVCError is NotFound ? WireMVCOutcome.status(.notFound) : nil)`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`routeClosureOverridesController`). Controller-before-global ordering is pinned by nothing yet.

### Requirement: The composition root's `@ErrorResponse` folds into every typed route
WireMVCRouteGen SHALL read the `@ErrorResponse` entries of the `@WireMVCBootstrap` root once, under
scope label `bootstrap`, and append them to every typed route's chain, including routes whose route
and controller declare no `@ErrorResponse`.

#### Scenario: a controller with no mappings
- **WHEN** the root declares `@ErrorResponse(TenantMissing.self, .badRequest)` and `ThingsController` declares none
- **THEN** its route's chain contains `(wireMVCError is TenantMissing ? WireMVCOutcome.status(.badRequest) : nil)`

#### Scenario: over the wire
- **WHEN** `GET /hello/tenant` throws `TenantMissing` and neither its route nor `HelloController` maps it
- **THEN** the response is `400`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`globalErrorResponseFoldsIntoEveryRoute`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`globalErrorTierMapsToBadRequest`), `.github/workflows/build.yml` (`BuildAndRun`, step `Run @WireMVCBootstrap example (boot, probe, stop)`).

### Requirement: `WireMVCBindingError` follows the typed mappings on a route with bindings
On a route with at least one parameter binding, the chain SHALL include
`(wireMVCError as? WireMVCBindingError).map { WireMVCOutcome.status($0.status) }` after every typed
mapping and before the catch-all. A route with no bindings SHALL NOT include it.

#### Scenario: a bound route
- **WHEN** a route binds `@Path id` under a controller mapping `NotFound`
- **THEN** its chain contains `(wireMVCError as? WireMVCBindingError).map` after the `NotFound` element

#### Scenario: a route with no bindings
- **WHEN** `@Get @JSONResponse @ErrorResponse(NotFound.self, .notFound) func list()` takes no parameters
- **THEN** its witness contains `errorMapping: { wireMVCError in` and does not contain `as? WireMVCBindingError`

#### Scenario: malformed input over the wire
- **WHEN** `POST /users` arrives with `Content-Type: text/plain`, and again with the body `{bad`
- **THEN** the responses are `415` and `422`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`controllerScopeStatusShorthandCoversRoute`, `noBindsRouteGainsCatchForErrorResponse`), `Fixtures/Sources/WireMVCExample/main.swift` (the `415` and `422` checks, run by the `BuildAndRun` job in `.github/workflows/build.yml`). `controllerScopeStatusShorthandCoversRoute` asserts only that the element is present; its position after the typed mappings and before the catch-all is pinned by nothing yet.

### Requirement: The innermost catch-all follows the binding built-in
When any tier declares a catch-all, the chain SHALL end in the first catch-all found in route,
controller, global order, as a non-optional element: `WireMVCOutcome.status(.status)` for the status
form, `wireMVCRespondAny(to: wireMVCError, (closure))` for the closure form, or
`wireMVCRespondAny(to: wireMVCError, status: .status, (closure))` for the body form.

#### Scenario: a controller catch-all closure
- **WHEN** a controller declares `@ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })` and its route binds `@Path id`
- **THEN** the chain contains `wireMVCRespondAny(to: wireMVCError, ({ (e: Swift.Error) in`, the closure body reads `return try (`, and nothing is rethrown

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`catchAllClosureIsTerminal`), which asserts the closure-form element is present. Its position after the binding built-in and at the end of the chain, the status-form and body-form terminal elements, and selection of the route's catch-all over a controller's are pinned by nothing yet.

### Requirement: An unmapped throw becomes a written `500`
When no tier declares a catch-all, the chain SHALL end in `WireMVCOutcome.status(.internalServerError)`,
and the generated terminal SHALL send it rather than rethrow the error. A route with no mappings and no
bindings SHALL have the chain `WireMVCOutcome.status(.internalServerError)` alone.

#### Scenario: the controller shorthand without a catch-all
- **WHEN** a controller maps only `NotFound`
- **THEN** the chain ends `?? WireMVCOutcome.status(.internalServerError)` and the witness contains no `throw wireMVCError`

#### Scenario: an unmapped handler throw over the wire
- **WHEN** `GET /boom` throws an error no tier maps and the route has no bindings
- **THEN** the client receives `500` rather than a dropped connection

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`controllerScopeStatusShorthandCoversRoute`, `middlewareFactoryKeyFold`), `Fixtures/Sources/WireMVCExample/main.swift` (the `GET /boom` check, run by the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: The mapped region covers scope entry, binding, the handler and buffered encoding
The generated `building:` closure passed to the terminal SHALL contain the scoped controller's scope
entry, every parameter bind, the handler call and, for a buffered route, the response encoding, so a
throw from any of them SHALL be mapped by `errorMapping`. Body collection by the terminal's `collectingBodyFrom:` overload
SHALL run inside the same mapped region.

#### Scenario: a scoped controller with a mapping
- **WHEN** `@Scoped(seed: HTTPRequest.self) @Controller("/me") @ErrorResponse(Unauthenticated.self, .unauthorized) struct Me` is rendered
- **THEN** `let wireMVCScopeEntry = try await self._wireEnterScope(request)` appears after `building: {`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`scopedControllerScopeEntryInsideDoWhenMapped`).

### Requirement: A throw while a streamed body is produced is not mapped
On a streaming route, `wireMVCStreamingTerminal` SHALL send the head and produce the body only after
`building` returns and the outcome is settled, so a throw from the producer SHALL NOT be mapped by
`errorMapping`; it SHALL propagate and the response SHALL be aborted without `finish`.

#### Scenario: a producer that fails after two chunks
- **WHEN** `building` returns a producer that writes `<html>` and `<p>ok</p>` and then throws `BoomError`, with an `errorMapping` that answers `.status(.internalServerError)`
- **THEN** the head already sent is `200`, the terminal rethrows `BoomError`, and the response is aborted rather than finished

Pinned by: `Fixtures/Tests/StreamingTierTests/TierTests.swift` (`midBodyFailureAborts`).

### Requirement: A mapped response still carries middleware header contributions
The terminal SHALL drain the response header registry after `building` returns or throws, and SHALL
apply the drained contributions to the outcome `errorMapping` produced, exactly as to a successful
outcome. A throw from the drain itself SHALL be mapped through `errorMapping` unless `building` also
threw, in which case the route's error SHALL be the one mapped.

#### Scenario: a refusal mapped by the global tier
- **WHEN** `GET /hello/refused/Ada` passes a middleware that contributes `x-stamp: middleware` and a deferred `Set-Cookie`, and the handler throws `TenantMissing`, which the root maps to `400`
- **THEN** the response is `400` carrying `x-stamp: middleware` and `Set-Cookie: greeted=Ada; Path=/`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`middlewareContributionsSurviveAMappedRefusal`), `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`aDeferredContributionRunsOnceWhenALaterOneThrows`, `aMappedErrorStillCarriesTheContributions`). Precedence of the route error over a failed drain is pinned by nothing yet.

### Requirement: Raw routes and the fallback consult no `@ErrorResponse`
A `@RawRoute` handler, including the root's `@NotFound` fallback, SHALL be called directly from its
register closure with no `errorMapping`, and the global tier SHALL NOT be folded into the fallback.

#### Scenario: a raw route under a mapped controller
- **WHEN** a controller carrying `@ErrorResponse(NotFound.self, .notFound)` declares a `@RawRoute` handler
- **THEN** that route's registration calls the handler with no `errorMapping:` closure

Pinned by: nothing yet.

## Related specifications

- [controllers-and-routes](../controllers-and-routes/spec.md)
- [request-bindings](../request-bindings/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [response-headers](../response-headers/spec.md)
- [middleware](../middleware/spec.md)
- [request-scope](../request-scope/spec.md)
- [composition-root](../composition-root/spec.md)
