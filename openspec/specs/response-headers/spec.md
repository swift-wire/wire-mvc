# Response headers

## Purpose

How a response's header fields are assembled from every contributor. There are four tiers:
controller `@ResponseHeader` constants, then route constants, then the fields a handler returns in its
response tuple, then middleware contributions, with the outermost middleware applied last. All four
use the same three verbs. Middleware contributions are collected in a linear `ResponseHeaderRegistry`,
carried from the top of the handler stack to each route by the `WireMVCContext` courier, and drained
exactly once by whatever writes the response: the typed terminal, a gate's `respondingWith(_:)`, the
synthesised 404 and 405 handlers, or the `ResponseHeaderApplyingSender` wrapped around a raw route's
untransformed sender. A gate's raw `responding(_:)` and a raw route whose sender slot is a transformed type
discard the contributions without draining them.

Rationale: [LinearResponseHeaderRegistry](../../../Documentation/Notes/LinearResponseHeaderRegistry.md), [WireMVCDesign](../../../Documentation/Notes/WireMVCDesign.md).
Documentation: [ResponsesAndHeaders](../../../Sources/WireMVC/WireMVC.docc/ResponsesAndHeaders.md).

## Requirements

### Requirement: Three verbs, none of which folds
`ResponseHeaderContribution` SHALL have the cases `.set(HTTPField.Name, String)`,
`.append(HTTPField.Name, String)` and `.setIfAbsent(HTTPField.Name, String)`, matching
`ResponseHeaderVerb`'s `.set`, `.append` and `.setIfAbsent`. `WireMVCResponseHeaders.apply(_:to:)` SHALL
replace every existing value of the field for `.set`, add a separate field line for `.append`, and write
the value for `.setIfAbsent` only when the field is absent.

#### Scenario: append keeps separate lines
- **WHEN** `resolved(statics: [.set(.setCookie, "sid=1"), .append(.setCookie, "consent=yes")])` is evaluated
- **THEN** `fields[values: .setCookie]` is `["sid=1", "consent=yes"]` and there are two `Set-Cookie` field lines

#### Scenario: set clears every earlier value
- **WHEN** the statics are `.set(.vary, "Accept-Encoding")`, `.append(.vary, "Origin")`, `.set(.vary, "Accept")`
- **THEN** there is one `Vary` field line, `Accept`

#### Scenario: setIfAbsent defers
- **WHEN** the statics are `.set(.cacheControl, "no-store")` then `.setIfAbsent(.cacheControl, "public")`
- **THEN** `Cache-Control` is `no-store`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`appendKeepsSeparateFieldLines`, `setIfAbsentDefersToWhatIsAlreadySet`, `resolvingNeverFolds`, `setReplacesEveryExistingValue`).

### Requirement: `.set` splits a `Cookie` value on its separator
`WireMVCResponseHeaders.apply(_:to:)` SHALL write `.set` and `.setIfAbsent` through the scalar `HTTPFields`
subscript, so a `Cookie` value is split on `"; "` into separate field lines rather than kept as written.

#### Scenario: a set of Cookie
- **WHEN** `resolved(statics: [.set(.cookie, "a=1; b=2")])` is evaluated
- **THEN** `fields[values: .cookie]` is `["a=1", "b=2"]`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`setOnCookieSplitsOnItsSeparator`). The `.setIfAbsent` case is pinned by nothing yet.

### Requirement: `resolved` applies statics, then returned fields, then middleware
`WireMVCResponseHeaders.resolved(statics:returned:middleware:)` SHALL apply each static contribution in
order, then the returned `HTTPFields`, then each middleware contribution in order. Returned fields
SHALL replace per name: the first occurrence of a name clears what the statics set for it, and later
occurrences of the same name are appended.

#### Scenario: a returned field beats a static one
- **WHEN** the statics set `Cache-Control: no-store` and `Vary: Accept-Encoding` and the returned fields are `[.cacheControl: "public"]`
- **THEN** `Cache-Control` is `public` and `Vary` is `Accept-Encoding`

#### Scenario: returned repeated fields replace as a whole
- **WHEN** the statics set `Set-Cookie: inherited=1` and the returned fields carry `Set-Cookie: a=1` and `Set-Cookie: b=2`
- **THEN** `fields[values: .setCookie]` is `["a=1", "b=2"]`

#### Scenario: middleware applies over the handler
- **WHEN** the returned fields are `Content-Type: text/plain` and `Cache-Control: no-store` and middleware contributes `.set(.cacheControl, "public")` and `.setIfAbsent(.contentType, "application/json")`
- **THEN** `Cache-Control` is `public` and `Content-Type` is `text/plain`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`returnedFieldsBeatStatics`, `returnedRepeatedFieldReplacesAsAWhole`, `returnedFieldsSurviveWithNoStatics`, `middlewareAppliesOverReturnedWithNoStatics`, `routeSetReplacesControllerSet`).

### Requirement: `@ResponseHeader` constants are emitted in tier order
`@ResponseHeader(_ name: HTTPField.Name, _ value: String)` and `@ResponseHeader(_:_:_ verb:
ResponseHeaderVerb)` SHALL be attached peer macros accepted on a controller and on a typed route, the verb
defaulting to `.set`. WireMVCRouteGen SHALL emit a route's constants as the `statics:` literal of a
`WireMVCResponseHeaders.resolved` call, controller entries first and route entries after, each in
source order, with the verb as the contribution's case name.

#### Scenario: both scopes, with a verb
- **WHEN** a controller carries `@ResponseHeader(.cacheControl, "public")` and `@ResponseHeader(.vary, "Accept-Encoding")` and its route carries `@ResponseHeader(.cacheControl, "no-store")` and `@ResponseHeader(.vary, "Origin", .append)`
- **THEN** the route's outcome is built with `headerFields: WireMVCResponseHeaders.resolved(statics: [.set(.cacheControl, "public"), .set(.vary, "Accept-Encoding"), .set(.cacheControl, "no-store"), .append(.vary, "Origin")])`

#### Scenario: a bodiless route carries its constants
- **WHEN** `@Delete("/{id}") @ResponseStatus(.noContent) @ResponseHeader(.cacheControl, "no-store")` is generated
- **THEN** the witness contains `return .status(.noContent, headerFields: WireMVCResponseHeaders.resolved(statics: [.set(.cacheControl, "no-store")]))`

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`staticHeadersEmitInTierOrderWithVerbs`, `responseStatusRouteCarriesStaticHeaders`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`routeConstantsShipWithoutMiddleware`).

### Requirement: Two `.set`s of one field at one scope are diagnosed
WireMVCRouteGen SHALL report `responseHeaderDuplicateField` when one scope carries two `@ResponseHeader`
entries for the same field that are both `.set`, and SHALL accept a second entry that uses `.append`.

#### Scenario: two sets
- **WHEN** a route carries `@ResponseHeader(.vary, "Accept-Encoding")` and `@ResponseHeader(.vary, "Origin")`
- **THEN** the diagnostic is "@ResponseHeader sets '.vary' more than once at route scope, so which value was meant is undecidable. To *add* a value to a field that legitimately repeats (Set-Cookie, Vary), pass the verb: @ResponseHeader(.vary, \"…\", .append). To replace, keep one entry (a route entry already overrides a controller entry for the same field)."

#### Scenario: a set and an append
- **WHEN** a route carries `@ResponseHeader(.setCookie, "a=1")` and `@ResponseHeader(.setCookie, "b=2", .append)`
- **THEN** there are no diagnostics and the statics are `[.set(.setCookie, "a=1"), .append(.setCookie, "b=2")]`

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`twoSetsOfOneFieldAreDiagnosed`, `appendingASecondValueIsNotADuplicate`). `twoSetsOfOneFieldAreDiagnosed` asserts only that `responseHeaderDuplicateField` is reported; the message text and its field and scope arguments are pinned by nothing yet, tracked in https://github.com/swift-wire/wire-mvc/issues/240.

### Requirement: `@ResponseHeader` on a raw route is diagnosed
WireMVCRouteGen SHALL report `responseHeaderOnRawRoute` for a `@RawRoute` that carries `@ResponseHeader`,
or whose controller carries one.

#### Scenario: a constant on a raw route
- **WHEN** `@Get("/stream") @RawRoute @ResponseHeader(.cacheControl, "no-store") func stream(responseSender:)` is generated
- **THEN** the diagnostic is "@ResponseHeader does not apply to the @RawRoute handler 'stream' — a raw handler writes its own response head, so nothing here could set the field for it. Set it on the HTTPResponse the handler sends."

#### Scenario: a controller constant over a raw route
- **WHEN** a controller carries `@ResponseHeader(.cacheControl, "no-store")` and contains a `@RawRoute` with no `@ResponseHeader` of its own
- **THEN** `responseHeaderOnRawRoute` is reported for that raw route

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`responseHeaderOnARawRouteIsDiagnosed`), which asserts only that the route-scope case is reported. The message text and the controller-scope case are pinned by nothing yet, tracked in https://github.com/swift-wire/wire-mvc/issues/240; whether the controller-scope case should fail the build is open in https://github.com/swift-wire/wire-mvc/issues/241.

### Requirement: A route names `headerFields:` only for what it states itself
The generated outcome SHALL pass `headerFields: WireMVCResponseHeaders.resolved(…)` naming `statics:`
when the route or controller has constants and `returned: wireMVCReturn.headers` when the response
tuple has `headers`, and SHALL omit `headerFields:` entirely when it has neither. Middleware
contributions SHALL NOT appear in that call.

#### Scenario: a route that states nothing
- **WHEN** `@Get("/{id}") @JSONResponse func get(@Path id: String) async throws -> Thing` is generated
- **THEN** the witness contains no `headerFields:` and still passes `responseHeaders: wireMVCResponseHeaderDrain` to the terminal

#### Scenario: constants and a returned field list
- **WHEN** a route with `@ResponseHeader(.cacheControl, "no-store")` returns `(status:headers:body:)`
- **THEN** the outcome passes `headerFields: WireMVCResponseHeaders.resolved(statics: [.set(.cacheControl, "no-store")], returned: wireMVCReturn.headers)`

Pinned by: `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`routeDeclaringNothingStillResolvesMiddlewareContributions`, `fullResponseTupleProjectsEveryElement`).

### Requirement: Constants and returned fields apply to the success outcome only
`@ResponseHeader` constants and handler-returned fields SHALL be applied only to the outcome `building`
produces. An outcome returned by `errorMapping` SHALL carry its own fields plus the drained middleware
contributions, and no route or controller constants.

#### Scenario: a mapped error on a route with a constant
- **WHEN** a route carrying `@ResponseHeader(.cacheControl, "no-store")` throws and its mapping returns `.status(.badRequest)`
- **THEN** the `400` carries no `Cache-Control`

Pinned by: nothing yet.

### Requirement: `ResponseHeaderRegistry` is a linear list of registrations drained newest first
`ResponseHeaderRegistry` SHALL be a `~Copyable`, non-`Sendable` struct with `add(_:)` for one
contribution, `add(_:...)` for several, `with(_:)` returning the registry with one more contribution,
and `onSend(_:)` taking an `@escaping () async throws -> [ResponseHeaderContribution]`. Its consuming
`drain()` and `drain(into:)` SHALL evaluate registrations from the most recent to the earliest,
preserving order within one registration, and SHALL agree with each other past the four registrations
held inline.

#### Scenario: the earliest registration wins
- **WHEN** a registry receives `.set(x-contested, "0")` through `.set(x-contested, "6")` in seven `add` calls and is drained into empty fields
- **THEN** `x-contested` is `0` and has one value

#### Scenario: the two drain spellings
- **WHEN** two registries each receive six `add` calls and one `onSend` returning `.set(x-deferred, "late")`, and one is drained with `drain(into:)` while the other's `drain()` result is applied in order
- **THEN** the two field sets are equal and `x-deferred` is `late`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`everyRegistrationSurvivesRegardlessOfCount`, `theFirstRegistrationWinsAcrossTheOverflowBoundary`, `bothDrainSpellingsAgree`). Preserving order within one registration is pinned by nothing yet, tracked in https://github.com/swift-wire/wire-mvc/issues/240.

### Requirement: On a typed route, a deferred contribution runs in the terminal, after the handler
An `onSend` closure SHALL NOT run at registration. When a typed route's terminal drains the registry, each
closure SHALL run exactly once, after `building` has returned or thrown and before the response head is
written.

#### Scenario: a session cookie read from what the handler did
- **WHEN** `StampMiddleware` registers an `onSend` that reads the name the handler recorded, and `GET /hello/stamped/Ada` is served
- **THEN** the response carries `Set-Cookie: greeted=Ada; Path=/`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`middlewareContributionsBeatRouteConstantsAndSeeTheHandler`), `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`aSucceedingDrainRunsOnceAndReachesTheResponse`).

### Requirement: On a raw route, a deferred contribution runs when the handler writes its head
On a `@RawRoute` whose sender is wrapped in `ResponseHeaderApplyingSender`, an `onSend` closure SHALL run
when the handler calls `send(_:)` or `sendAndFinish(_:buffer:trailer:)` on the wrapper, while the handler is
still running, and SHALL NOT run if the handler never writes a head.

#### Scenario: a raw handler writes its head
- **WHEN** a middleware registers an `onSend` returning `.set(x-deferred, "late")` in front of a raw route whose handler writes `200` through the wrapped sender
- **THEN** the closure runs once, inside the handler's write, and the `200` head carries `x-deferred: late`

Pinned by: nothing yet, tracked in https://github.com/swift-wire/wire-mvc/issues/240.

### Requirement: The typed terminal drains the registry exactly once, on every path
`wireMVCBufferedTerminal` and `wireMVCStreamingTerminal`, in all three overloads each, SHALL take the
registry as `responseHeaders: consuming ResponseHeaderRegistry`, drain it once after `building`
completes or throws and before anything is sent, and apply the contributions last onto the fields of
whichever outcome is sent, the built one or the one `errorMapping` returned.

#### Scenario: middleware beats a route constant
- **WHEN** the registry holds `.set(cache-control, "no-store")` and `building` returns `.status(.ok, headerFields: resolved(statics: [.set(cache-control, "public")]))`
- **THEN** the head carries one `Cache-Control`, `no-store`

#### Scenario: a mapped error keeps the contributions
- **WHEN** `building` throws, `errorMapping` returns `.status(.unauthorized)`, and the registry holds a deferred `.set(x-deferred, "late")`
- **THEN** the closure ran once and the `401` carries `x-deferred: late`

#### Scenario: over the wire
- **WHEN** `GET /hello/refused/Ada` folds `StampMiddleware` and throws an error the composition root maps to `400`
- **THEN** the `400` carries `x-stamp: middleware` and `Set-Cookie: greeted=Ada; Path=/`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`aSucceedingDrainRunsOnceAndReachesTheResponse`, `aMappedErrorStillCarriesTheContributions`, `theLateFoldMatchesOneResolvedCall`, `aMiddlewareContributionWinsOverTheRoutesOwn`, `aSucceedingDrainReachesTheStreamedHead`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`middlewareContributionsBeatRouteConstantsAndSeeTheHandler`, `middlewareContributionsSurviveAMappedRefusal`), `Fixtures/Tests/WireMVCBootstrapExampleTests/HTMLResponseOverTheWireTests.swift` (`globalMiddlewareContributesToAStreamedHead`).

### Requirement: A throwing `onSend` discards every contribution and maps like a route error
When draining throws, the terminal SHALL discard every contribution from that drain, including those
already computed, and SHALL send the outcome `errorMapping` returns for the drain's error. When
`building` also threw, `errorMapping` SHALL be called with the route's error instead. A streaming
route whose drain throws SHALL send the mapped buffered outcome and never run its producer.

#### Scenario: a later closure throws
- **WHEN** the registry holds an `onSend` that throws and a later-registered `onSend` that records a side effect and returns `.set(x-deferred, "late")`, and `errorMapping` returns `.status(.internalServerError)`
- **THEN** the side effect ran once, the head is `500`, and it carries no `x-deferred`

#### Scenario: the same on a streaming route
- **WHEN** the same registry is handed to `wireMVCStreamingTerminal` with a producer that would write `streamed`
- **THEN** the head is `500`, it carries no `x-deferred`, and the body is empty

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`TerminalDrainsOnceTests.aDeferredContributionRunsOnceWhenALaterOneThrows`, `StreamingTerminalDrainsOnceTests.aDeferredContributionRunsOnceWhenALaterOneThrows`). The route error taking precedence over a drain error is pinned by nothing yet.

### Requirement: The courier carries the registry across `handle`
`ResponseHeaderCarrying` SHALL refine `HTTPServerCapability.RequestContext`, `SendableMetatype` and
`~Copyable`, with an associated `Base` context, `consuming func takeContents() ->
WireMVCContextContents<Base>` and `init(base:responseHeaders:)`. `WireMVCContextContents<Base>` SHALL
be a `@frozen`, `~Copyable` struct with public stored properties `responseHeaders:
WireDisconnected<ResponseHeaderRegistry>` and `base: Base`. `WireMVCContext<Base>` SHALL conform to
`ResponseHeaderCarrying`. A generated fold-less typed route SHALL destructure the courier once and hand
the registry to its terminal.

#### Scenario: the generated destructure
- **WHEN** `@Get("/{id}") @JSONResponse func get(@Path id: String)` is generated with no middleware
- **THEN** the register closure begins `let wireMVCContextContents = requestContext.takeContents()` and `let wireMVCResponseHeaderDrain = wireMVCContextContents.responseHeaders.take()`, and the witness constrains `Builder.RequestContext: ~Copyable & ResponseHeaderCarrying`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`), `Tests/WireMVCCodegenTests/ResponseHeaderGenerationTests.swift` (`routeDeclaringNothingStillResolvesMiddlewareContributions`).

### Requirement: The courier is put on once per request at the top of the stack
`WireMVCContextHandler<Inner, Base>` SHALL have `RequestContext == Base` and SHALL wrap each request's
context in a `WireMVCContext` with a new empty `ResponseHeaderRegistry` before calling its inner
handler. `WireMVCContextServer<Base: HTTPServer>` SHALL present `WireMVCContext<Base.RequestContext>`
as its `RequestContext` and SHALL serve a handler by passing `WireMVCContextHandler(inner: handler)` to
`base.serve(handler:)`. The generated entry SHALL wrap the server it creates in `WireMVCContextServer`.

#### Scenario: the generated entry
- **WHEN** WireMVCRouteGen renders the `@main` for a `@WireMVCBootstrap` root whose `createServer()` is declared `throws`
- **THEN** it contains `let server = WireMVCContextServer(try bootstrap.createServer())`

#### Scenario: a global contribution on a route with no middleware
- **WHEN** the global `AccessLog` middleware contributes `x-served-by: wire-mvc` and `GET /hello/cached/Ada` has no `@Middleware` of its own
- **THEN** the `200` carries `x-served-by: wire-mvc`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryGeneratesMain`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`globalContributionReachesARouteWithNoMiddleware`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`globalAndControllerContributionsBothArrive`).

### Requirement: `ResponseHeaderApplyingSender` applies contributions onto the head a raw handler writes
`ResponseHeaderApplyingSender<Base>` SHALL, in `send(_:)` and `sendAndFinish(_:buffer:trailer:)`, drain
its registry into the head the handler wrote, so the handler's own fields come first and contributions
apply over them, and SHALL forward `sendInformational(_:)` without applying anything.

#### Scenario: handler fields survive
- **WHEN** a raw route writes `Content-Type: text/plain`, `Cache-Control: no-store` and two `Set-Cookie` lines through a wrapper whose registry holds `.set(x-trace, "abc")`
- **THEN** the head carries both of the handler's fields, both `Set-Cookie` lines, and `x-trace: abc`

#### Scenario: set beats the handler, setIfAbsent does not
- **WHEN** the registry holds `.set(.cacheControl, "public")` and `.setIfAbsent(.contentType, "application/json")` and the handler wrote `Cache-Control: no-store` and `Content-Type: text/plain`
- **THEN** the head carries one `Cache-Control: public` and `Content-Type: text/plain`

#### Scenario: the `@NotFound` fallback
- **WHEN** a global middleware contributes `x-served-by: wire-mvc` and `GET /no/such/route` reaches the raw `@NotFound` handler
- **THEN** the `404` carries `x-served-by: wire-mvc`

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`handlerFieldsSurviveAContribution`, `repeatedHandlerFieldsSurviveAContribution`, `setIfAbsentDefersToAHandlerWrittenField`, `setOverridesAHandlerWrittenField`, `headIsUnchangedWhenNothingContributes`, `contributedHeadersStillReachARawHead`), `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`globalContributionReachesARawRoute`, `globalContributionReachesTheNotFoundFallback`). Every cited test writes through the two-argument `sendAndFinish`, which reaches the wrapper's `send(_:)`; the drain in `sendAndFinish(_:buffer:trailer:)` and the forwarding of `sendInformational(_:)` are pinned by nothing yet, tracked in https://github.com/swift-wire/wire-mvc/issues/240.

### Requirement: The outermost middleware's contribution applies last
Because the registry drains newest first, a contribution registered by an outer middleware on the way
in SHALL be applied after any contribution registered by a middleware inside it, and so SHALL win for
`.set`.

#### Scenario: the outer registration wins
- **WHEN** an outer middleware registers `.set(x-contested, "outer")` on the way in, an inner middleware then registers `.set(x-contested, "inner")`, and the registry is drained into empty fields
- **THEN** `x-contested` is `outer` and has one value

Pinned by: `Tests/WireMVCResponsesTests/ResponsesTests.swift` (`theFirstRegistrationWinsAcrossTheOverflowBoundary`). Over the wire it is pinned by nothing yet: the fallback fixture's `GateTests` give the same result under either drain order, tracked in https://github.com/swift-wire/wire-mvc/issues/239.

## Related specifications

- [responses-and-modes](../responses-and-modes/spec.md)
- [middleware](../middleware/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [composition-root](../composition-root/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
- [testing-harness](../testing-harness/spec.md)
