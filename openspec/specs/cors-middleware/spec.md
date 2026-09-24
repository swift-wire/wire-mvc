# CORS middleware

## Purpose

`CORSMiddleware`, the Cross-Origin Resource Sharing middleware the `WireMVCMiddleware` product ships
for the proposal-native path, and `CORSConfiguration`, the graph binding it reads its policy from. It
is a factory-form middleware, so an application folds it with
`@Middleware(CORSMiddlewareKeys.factory)`, typically at global scope. It contributes the
`Access-Control-*` response fields for a request that carries `Origin` and answers a preflight
itself.

## Requirements

### Requirement: `CORSMiddleware` is a factory-form middleware reading `CORSConfiguration` from the graph
`CORSMiddleware<Ctx, Reader, Sender>` SHALL be a public `Middleware` annotated
`@Factory(CORSMiddlewareKeys.factory) @MiddlewareFactory`, with `Input` and `NextInput` both
`RequestResponseMiddlewareBox<Ctx, Reader, Sender>`, and SHALL read its policy from `@Inject var
configuration: CORSConfiguration`. `CORSMiddlewareKeys.factory` SHALL be a `FactoryKey`.

#### Scenario: folded globally with the configuration provided by the root
- **WHEN** `FallbackBootstrap` is declared `@WireMVCBootstrap @Middleware(CORSMiddlewareKeys.factory)` and `@Provides package static let cors = CORSConfiguration(allowOrigin: .oneOf(["https://allowed.example"]), …)`
- **THEN** `GET /ping` with `Origin: https://allowed.example` answers `200` with `Access-Control-Allow-Origin: https://allowed.example`

Pinned by: `Fixtures/Sources/WireMVCFallbackExample/App.swift`, `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`anAllowedOriginGetsTheCORSFields`).

### Requirement: A request without `Origin` passes through untouched
When the request has no `Origin` field, `CORSMiddleware` SHALL call `next` with the box unchanged and
contribute no field.

#### Scenario: a same-origin request
- **WHEN** `GET /ping` is sent with no `Origin` to the fixture app
- **THEN** the response has no `Access-Control-Allow-Origin` and no `Vary` value `Origin`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aRequestWithoutOriginIsUntouched`, `aCacheableRouteIsNotReplayedForALaterRequest`).

### Requirement: `AllowOrigin` decides the `Access-Control-Allow-Origin` value
`CORSConfiguration.AllowOrigin` SHALL be a `Sendable, Equatable` enum whose value for a request origin
is: nothing for `.none`; `*` for `.all`; the request's origin for `.originBased`; the request's origin
for `.oneOf(list)` when `list` contains it, else nothing; the given string for `.custom(value)`. When
the value is not nothing, `CORSMiddleware` SHALL contribute `Access-Control-Allow-Origin` with it.

#### Scenario: `.oneOf` and an unlisted origin
- **WHEN** the policy is `.oneOf(["https://a.example", "https://b.example"])` and the origin is `https://evil.example`
- **THEN** the value is `nil`, and over a live server `GET /ping` with `Origin: https://evil.example` answers `200` without `Access-Control-Allow-Origin`

#### Scenario: `.originBased` echoes
- **WHEN** the policy is `.originBased` and the origin is `https://app.example`
- **THEN** the value is `https://app.example`

#### Scenario: the fixed policies
- **WHEN** the origin is `https://a.example`
- **THEN** `.all` yields `*` and `.none` yields `nil`

Pinned by: `Tests/WireMVCMiddlewareTests/CORSConfigurationTests.swift` (`originBasedEchoesTheRequestOrigin`, `oneOfEchoesOnlyListedOrigins`, `fixedPoliciesDoNotVaryByOrigin`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`anUnlistedOriginGetsNoAllowOrigin`).

### Requirement: Credentials are advertised when configured
When `configuration.allowCredentials` is `true` and the request carries `Origin`, `CORSMiddleware`
SHALL contribute `Access-Control-Allow-Credentials: true`.

#### Scenario: the fixture's credentialed policy
- **WHEN** `GET /ping` is sent with `Origin: https://allowed.example` to an app configured with `allowCredentials: true`
- **THEN** the response carries `Access-Control-Allow-Credentials: true`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`anAllowedOriginGetsTheCORSFields`).

### Requirement: `Vary: Origin` is appended exactly when the answer depends on the origin
`CORSMiddleware` SHALL contribute `.append(.vary, "Origin")` when `allowOrigin` is `.originBased` or
`.oneOf`, and SHALL NOT contribute `Vary` for `.none`, `.all` or `.custom`. `Vary` is not a
configuration field.

#### Scenario: a listed origin under `.oneOf`
- **WHEN** `GET /ping` is sent with `Origin: https://allowed.example` under `.oneOf`
- **THEN** the response's `Vary` values contain `Origin`

#### Scenario: an invariant policy
- **WHEN** the policy is `.all`, `.custom("https://a.example")` or `.none`
- **THEN** `variesByRequestOrigin` is `false`

Pinned by: `Tests/WireMVCMiddlewareTests/CORSConfigurationTests.swift` (`fixedPoliciesDoNotVaryByOrigin`, `originBasedEchoesTheRequestOrigin`, `oneOfEchoesOnlyListedOrigins`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`anAllowedOriginGetsTheCORSFields`).

### Requirement: `Access-Control-*` fields are contributed with `.set`
`CORSMiddleware` SHALL contribute `Access-Control-Allow-Origin`, `Access-Control-Allow-Credentials` and
`Access-Control-Expose-Headers` through `input.contributing` with the `.set` verb, and `Vary` with the
`.append` verb, in one `contributing` pass.

#### Scenario: a route that sets its own CORS field
- **WHEN** a route behind `CORSMiddleware` returns its own `Access-Control-Allow-Origin` and the request carries an allowed `Origin`
- **THEN** the middleware's `.set` value is the one on the response

Pinned by: nothing yet.

### Requirement: `Expose-Headers` is sent on an actual request only
When the request is not a preflight and `configuration.exposedHeaders` is not empty, `CORSMiddleware`
SHALL contribute `Access-Control-Expose-Headers` with the names' `rawName`s joined by `", "`. A
preflight SHALL NOT receive it.

#### Scenario: the fixture exposes one field
- **WHEN** `exposedHeaders` is `[.init("x-stamp")!]` and `GET /ping` carries `Origin: https://allowed.example`
- **THEN** the response carries `Access-Control-Expose-Headers: x-stamp`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`anAllowedOriginGetsTheCORSFields`). The preflight's omission is pinned by nothing yet.

### Requirement: A preflight is answered `204` with the preflight fields and the drained contributions
A request whose method is `OPTIONS` and which carries `Access-Control-Request-Method` SHALL be a
preflight. `CORSMiddleware` SHALL answer it with `input.respondingWith(.status(.noContent,
headerFields:))` carrying `Access-Control-Allow-Methods` (the methods' raw values joined by `", "`),
`Access-Control-Allow-Headers` (the names' `rawName`s joined by `", "`) when `allowHeaders` is not
empty, and `Access-Control-Max-Age` (the whole seconds of `maxAge`) when `maxAge` is set, and SHALL
then pass the responded box to `next`.

#### Scenario: the fixture's preflight
- **WHEN** `OPTIONS /ping` carries `Origin: https://allowed.example` and `Access-Control-Request-Method: POST`, under `allowMethods: [.get, .post]`, `allowHeaders: [.contentType]`, `maxAge: .seconds(600)`
- **THEN** the response is `204` with `Access-Control-Allow-Methods: GET, POST`, `Access-Control-Allow-Headers` equal to `content-type` ignoring case, `Access-Control-Max-Age: 600`, `Access-Control-Allow-Origin: https://allowed.example` and `Access-Control-Allow-Credentials: true`

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aPreflightIsAnsweredWithBothFieldSets`).

### Requirement: `OPTIONS` alone is not a preflight
An `OPTIONS` request without `Access-Control-Request-Method` SHALL NOT be answered by the middleware;
`CORSMiddleware` SHALL contribute its shared fields and call `next`, so the request routes as usual.

#### Scenario: a plain `OPTIONS`
- **WHEN** `OPTIONS /ping` carries `Origin: https://allowed.example` and no `Access-Control-Request-Method`
- **THEN** the request reaches the router rather than receiving the middleware's `204`

Pinned by: nothing yet.

### Requirement: `.all` with credentials traps at construction
`CORSConfiguration.init` SHALL fail a `precondition` when `allowCredentials` is `true` and
`allowOrigin == .all`, with the message ``CORS: allowCredentials cannot be combined with .all — the Fetch standard forbids `Access-Control-Allow-Origin: *` alongside credentials, and browsers reject the response. Use .originBased to allow any origin with credentials.``. Every other combination SHALL construct.

#### Scenario: the legal combinations
- **WHEN** `CORSConfiguration` is constructed with `.all` and `allowCredentials: false`, or with `.originBased`, `.oneOf(["https://a.example"])` or `.custom("https://a.example")` and `allowCredentials: true`
- **THEN** each construction returns

#### Scenario: the illegal combination
- **WHEN** `CORSConfiguration(allowOrigin: .all, allowCredentials: true)` is evaluated
- **THEN** the process traps with the message above

Pinned by: `Tests/WireMVCMiddlewareTests/CORSConfigurationTests.swift` (`legalCombinationsConstruct`). The trap is pinned by nothing yet.

### Requirement: The configuration has fixed defaults
`CORSConfiguration.init` SHALL default `allowOrigin` to `.originBased`, `allowMethods` to `[.get, .post,
.head, .options]`, `allowHeaders` to `[.accept, .authorization, .contentType, .origin]`,
`allowCredentials` to `false`, `exposedHeaders` to `[]` and `maxAge` to `nil`, and SHALL store each as
a public `let` of the same name, with `maxAge` a `Duration?`.

#### Scenario: a default configuration's preflight
- **WHEN** `CORSConfiguration()` is provided and a preflight arrives
- **THEN** it answers `Access-Control-Allow-Methods: GET, POST, HEAD, OPTIONS` and no `Access-Control-Max-Age`

Pinned by: nothing yet.

## Related specifications

- [middleware](../middleware/spec.md)
- [response-headers](../response-headers/spec.md)
- [composition-root](../composition-root/spec.md)
- [package-traits](../package-traits/spec.md)
