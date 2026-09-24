# Controllers and route annotations

## Purpose

The annotations a controller author writes: `@Controller` with an optional path prefix, the five
verb annotations, and `@Coding` at its three tiers. WireMVCRouteGen reads them at build time to
decide each route's method, full path template, handler call and coding settings; the annotations
themselves generate no code. What a route returns is specified in responses-and-modes, how its
parameters bind in request-bindings, and the witness and proxy shape in route-builder-contract.

Rationale: [WireMVCDesign](../../../Documentation/Notes/WireMVCDesign.md).
Documentation: [WritingAController](../../../Sources/WireMVC/WireMVC.docc/WritingAController.md), [Coding](../../../Sources/WireMVC/WireMVC.docc/Coding.md).

## Requirements

### Requirement: `@Controller` names an optional path prefix
WireMVCRouteGen SHALL take a controller's path prefix from the string-literal first argument of
`@Controller("/prefix")`, and SHALL use the empty prefix for `@Controller` and `@Controller()`. It
SHALL read the controller from a `struct`, `class` or `actor` declaration.

#### Scenario: a prefixed controller
- **WHEN** `@Singleton @Controller("/hello") struct HelloController` declares `@Get("/{name}")`
- **THEN** the route registers at `/hello/{name}` and `GET /hello/ci` is served by it

#### Scenario: a bare controller
- **WHEN** `@Controller struct C` declares `@Get("/x")`
- **THEN** the route's template is `/x`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`fileLevelDiagnosticCarriesLocation`, `generatesSortedExtensionsWithImports`), `Fixtures/Sources/WireMVCBootstrapExample/HelloController.swift` (probed by the `Run @WireMVCBootstrap example (boot, probe, stop)` step of the `BuildAndRun` job in `.github/workflows/build.yml`).

### Requirement: Five verb annotations name the route's method
`@Get`, `@Post`, `@Put`, `@Patch` and `@Delete` SHALL each be declared in two forms, `(_ path:
String)` and `()`, and WireMVCRouteGen SHALL register the route with `.get`, `.post`, `.put`,
`.patch` or `.delete` respectively. A member function with no verb annotation SHALL NOT be a route.

#### Scenario: a verb with a subpath
- **WHEN** a controller declares `@Get("/{id}") @JSONResponse func get(@Path id: String)`
- **THEN** the witness contains `builder.register(method: .get, path: "/todos/{id}")`

#### Scenario: a bare verb routes the prefix
- **WHEN** `@Controller("/ping")` declares `@Get @JSONResponse func ping()`
- **THEN** `GET /ping` answers `200`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`matchedRouteCarriesTheGlobalHeader`).

### Requirement: There is no `@Head` or `@Options` annotation
The package SHALL NOT declare a verb annotation for `HEAD` or `OPTIONS`; the verb-to-method mapping
SHALL recognise only `Get`, `Post`, `Put`, `Patch` and `Delete`.

#### Scenario: an attribute outside the five
- **WHEN** a member function carries an attribute named `Head` and no other verb
- **THEN** WireMVCRouteGen treats it as a helper and registers nothing for it

Pinned by: nothing yet.

### Requirement: The route and root annotations are markers that expand to nothing
The verb annotations, the response annotations, `@RawRoute`, `@Middleware`, `@ErrorResponse`,
`@ResponseHeader`, `@RequestBinding`, `@Coding`, `@NotFound` and `@WireMVCBootstrap` SHALL all be
attached peer macros implemented by `RouteMarkerMacro`, whose expansion SHALL return no peers.

#### Scenario: a route's markers are stripped
- **WHEN** a struct member carrying `@Get("/{id}")` and `@JSONResponse` is macro-expanded
- **THEN** the expanded source is the member with both attributes removed and nothing added

Pinned by: `Tests/WireMVCMacrosTests/ControllerMacroTests.swift` (`testControllerAddsNoPeer`, `testControllerWithMiddlewareAddsNoPeer`).

### Requirement: The full path joins the prefix and the subpath
WireMVCRouteGen SHALL form each route's template with `routeJoinPath(prefix, sub)`: one trailing `/`
is dropped from the prefix, a non-empty subpath gains a leading `/` if it lacks one, the two are
concatenated, and an empty result SHALL become `/`. A bare verb annotation SHALL contribute the
empty subpath.

#### Scenario: prefix and subpath
- **WHEN** the prefix is `/todos` and the verb is `@Get("/{id}")`
- **THEN** the template is `/todos/{id}`

#### Scenario: a bare verb under a prefix
- **WHEN** `@Controller("/users")` declares a bare `@Get` whose handler takes `@Path id: String`
- **THEN** the template is `/users`, and the diagnostic reads `@Path 'id' has no matching '{id}' placeholder in the route path "/users"`

#### Scenario: nothing at all
- **WHEN** a bare `@Controller` declares a bare `@Get`
- **THEN** the template is `/`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`plainJSONRouteWithPathBinding`, `pathPlaceholderMismatchIsDiagnosed`). The empty and slash-normalising cases are pinned by nothing yet.

### Requirement: A wildcard segment other than the trailing catch-all is an error
WireMVCRouteGen SHALL report `wildcardPathSegment` for a joined template containing a segment that
is exactly `*` or `**`, anchored at the handler's name, and SHALL generate no registration for that
route. The message SHALL read `route path "<path>" uses '<segment>': the only wildcard WireMVC route
templates express is the trailing catch-all, '{name*}'`.

#### Scenario: a bare star
- **WHEN** `@Controller("/files")` declares `@Get("/*")`
- **THEN** exactly one diagnostic is reported and it contains `{name*}`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`unexpressibleWildcardIsDiagnosed`).

### Requirement: A catch-all before the last segment is an error
WireMVCRouteGen SHALL report `catchAllNotLastSegment` when a `{name*}` segment is followed by any
other segment, anchored at the handler's name, and SHALL generate no registration for that route.
The message SHALL read `route path "<path>": '<segment>' claims the rest of the path, so the
segments after it can never match — a catch-all must be the last segment`.

#### Scenario: a catch-all in the middle
- **WHEN** `@Controller("/files")` declares `@Get("/{path*}/edit")`
- **THEN** exactly one diagnostic is reported and it contains `must be the last segment`

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`misplacedCatchAllIsDiagnosed`).

### Requirement: A trailing catch-all and an ordinary placeholder are not diagnosed
WireMVCRouteGen SHALL accept a template whose last segment is `{name*}` and a template of ordinary
`{name}` placeholders without a diagnostic; whether a runtime serves a catch-all is decided at
registration, not by codegen.

#### Scenario: a trailing catch-all
- **WHEN** `@Controller("/files")` declares `@Get("/{path*}") @JSONResponse func serve(@Path path: String)`
- **THEN** no diagnostic is reported

Pinned by: `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`catchAllTemplateIsNotDiagnosed`, `ordinaryParameterIsNotDiagnosed`).

### Requirement: The handler call carries exactly the handler's declared effects
The generated call to a route handler SHALL be prefixed with `try ` when the handler declares
`throws` (typed or untyped), `await ` when it declares `async`, `try await ` when both, and nothing
when neither. The same rule SHALL apply to `@RawRoute` handlers.

#### Scenario: four handlers on one controller
- **WHEN** a controller declares `plain() -> Int`, `throwing() throws -> Int`, `asynchronous() async -> Int` and `both() async throws -> Int`, each `@Get … @JSONResponse`
- **THEN** the witness calls `self._wireSubject.plain()`, `try self._wireSubject.throwing()`, `await self._wireSubject.asynchronous()` and `try await self._wireSubject.both()`

#### Scenario: a typed throw
- **WHEN** the handler is declared `func f() throws(MyError)`
- **THEN** its call is prefixed `try `

Pinned by: `Tests/WireMVCCodegenTests/EffectMarkerTests.swift` (`plain`, `throwing`, `asynchronous`, `both`, `rawRoute`, `markerOrder`, `readsTheDeclaration`).

### Requirement: A controller's routes register in declaration order
The generated witness SHALL emit one `builder.register` call per route in the order the route
functions are declared in the controller body. The order of controllers within the generated file
is specified in build-plugins-and-routegen-cli.

#### Scenario: two routes on one controller
- **WHEN** a controller declares `@Get("/{id}")` and then `@Get("/{id}/raw")`
- **THEN** the witness's register call for `/todos/{id}` precedes the one for `/todos/{id}/raw`

Pinned by: nothing yet.

### Requirement: `@Coding` names a coding binding by key or by type
`@Coding` SHALL be declared in two forms, `@Coding(_ key: BindingKey<WireMVCCoding>)` and
`@Coding(_ type: WireMVCCoding.Type)`, and the package SHALL declare `wireMVCCodingAlias` as a
`WireAdapterAnnotationV1` for annotation `Coding` with capability `.injectsFromGraph`, so the named
binding is lifted onto the annotated scope's proxy. The witness SHALL read `WireMVCCoding.self` through
the by-type field `_wireWireMVCCoding` and a key through `_wire` followed by the sanitised key.

#### Scenario: the unkeyed binding
- **WHEN** a controller carries `@Coding(WireMVCCoding.self)`
- **THEN** its routes pass `coding: self._wireWireMVCCoding` and no `_wireWireMVCCoding_` field is read

#### Scenario: a keyed binding
- **WHEN** a route carries `@Coding(WireMVCCoding.reports)`
- **THEN** it passes `coding: self._wireWireMVCCoding_reports`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`codingSelectsTheUnkeyedBindingByType`, `overridingWithADifferentBindingIsNotDiagnosed`).

### Requirement: Coding resolves route, then controller, then application
Each route SHALL encode and decode with its own `@Coding` if it declares one, else its controller's,
else the witness's `coding wireMVCAppCoding` parameter. A route's `@Coding` SHALL NOT affect sibling
routes.

#### Scenario: a controller tier and a route override
- **WHEN** `@Coding(WireMVCCoding.controller)` is on the controller and `@Coding(WireMVCCoding.route)` on its `/todos/{id}/raw` route only
- **THEN** the `/todos/{id}` block reads `self._wireWireMVCCoding_controller` and nothing else, and the `/todos/{id}/raw` block reads `self._wireWireMVCCoding_route` and not the controller's

#### Scenario: no inner tier
- **WHEN** neither the controller nor the route carries `@Coding`
- **THEN** the route passes `coding: wireMVCAppCoding`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`codingTiersResolveInnermostFirst`, `routesWithoutCodingUseTheAppTier`).

### Requirement: The composition root's `@Coding` is the application tier
The generated entry SHALL pass the application tier to `WireMVC.apply` as `coding:`. When the
`@WireMVCBootstrap` root carries `@Coding`, that SHALL be `graph._WireGlobalMiddleware_<Root>.<field>`,
read off the root's proxy; otherwise it SHALL be `WireMVCCoding.default`.

#### Scenario: a declared application coding
- **WHEN** `@Singleton @WireMVCBootstrap @Coding(WireMVCCoding.app) struct AppBootstrap` is rendered
- **THEN** the entry contains `coding: graph._WireGlobalMiddleware_AppBootstrap._wireWireMVCCoding_app` and not `WireMVCCoding.default`

#### Scenario: none declared
- **WHEN** the root carries no `@Coding`
- **THEN** the entry contains `WireMVC.apply(graph, to: &builder, coding: WireMVCCoding.default)`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`bootstrapEntryReadsDeclaredCodingOffTheGraph`, `bootstrapEntryGeneratesMain`).

### Requirement: Repeating the controller's coding on a route is an error
WireMVCRouteGen SHALL report `redundantCodingOverride` at the route's `@Coding` argument when it names
the same reference as the controller's `@Coding`. A route naming a different binding SHALL NOT be
diagnosed, and a controller repeating the application tier SHALL NOT be diagnosed. The message SHALL
read `@Coding(<reference>) on this route names the binding the enclosing scope already selected, so it
overrides nothing. Name a different binding — a BindingKey<WireMVCCoding> distinguishes several codings
of the same type — or drop the annotation.`

#### Scenario: the unkeyed form at both scopes
- **WHEN** the controller and one of its routes both carry `@Coding(WireMVCCoding.self)`
- **THEN** a `redundantCodingOverride` diagnostic is reported

#### Scenario: a genuine override
- **WHEN** the controller carries `@Coding(WireMVCCoding.self)` and the route `@Coding(WireMVCCoding.reports)`
- **THEN** no diagnostic is reported

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`repeatingOneCodingAcrossScopesIsDiagnosed`, `overridingWithADifferentBindingIsNotDiagnosed`). The controller-versus-application case is pinned by nothing yet.

### Requirement: The default coding writes dates as ISO8601
`WireMVCCoding.default` SHALL be `WireMVCCoding()`, whose `dates` is `ISO8601DateTranscoder()` and
whose `json` is `JSONCoding()`. `ISO8601DateTranscoder` SHALL encode with `date.formatted(.iso8601)`
and decode with `Date(string, strategy: .iso8601)`.

#### Scenario: a date in a response body
- **WHEN** `WireMVCCoding.default.encoder()` encodes a value holding `Date(timeIntervalSince1970: 1_700_000_000)`
- **THEN** the JSON contains `2023-11-14` and not the reference-date number `721692800`

#### Scenario: a round trip
- **WHEN** the default encoder's output is decoded by the default decoder
- **THEN** the date comes back equal to the second

Pinned by: `Tests/WireMVCCodingTests/WireMVCCodingTests.swift` (`defaultDateFormat`, `roundTrip`).

### Requirement: The date transcoder governs both directions as a JSON string
`WireMVCCoding.encoder()` SHALL encode every `Date` as a single string produced by `dates.encode`, and
`WireMVCCoding.decoder()` SHALL decode every `Date` from a single string through `dates.decode`.

#### Scenario: an epoch-seconds transcoder
- **WHEN** `WireMVCCoding(dates: Epoch())` encodes a value whose date is `1700000000` seconds since 1970
- **THEN** the output is `{"at":"1700000000"}` and decoding it yields the same value

Pinned by: `Tests/WireMVCCodingTests/WireMVCCodingTests.swift` (`customTranscoder`).

### Requirement: `JSONCoding` maps onto the encoder's output formatting
`JSONCoding` SHALL default to `sortsKeys: false`, `escapesSlashes: true` and `prettyPrints: false`.
`encoder()` SHALL insert `.sortedKeys` when `sortsKeys` is true, `.withoutEscapingSlashes` when
`escapesSlashes` is false, and `.prettyPrinted` when `prettyPrints` is true.

#### Scenario: the defaults
- **WHEN** `WireMVCCoding.default.encoder()` encodes a string `/x`
- **THEN** the output contains `\/x`

#### Scenario: sorted keys and unescaped slashes
- **WHEN** `WireMVCCoding(json: .init(sortsKeys: true, escapesSlashes: false))` encodes `b = "/x"` and `a = 1`
- **THEN** the output is exactly `{"a":1,"b":"/x"}` with no newline

Pinned by: `Tests/WireMVCCodingTests/WireMVCCodingTests.swift` (`jsonSettings`).

## Related specifications

- [route-builder-contract](../route-builder-contract/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [request-bindings](../request-bindings/spec.md)
- [request-scope](../request-scope/spec.md)
- [middleware](../middleware/spec.md)
- [error-response-tiers](../error-response-tiers/spec.md)
- [trie-router](../trie-router/spec.md)
- [composition-root](../composition-root/spec.md)
- [build-plugins-and-routegen-cli](../build-plugins-and-routegen-cli/spec.md)
- [swift-wire adapter-annotations](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/adapter-annotations/spec.md)
