# Testing harness

## Purpose

`WireMVCTesting` stands a `@WireMVCBootstrap` application up inside a Swift Testing suite and drives it
through a client, over an in-process transport or a live loopback server. `WireMVCRouteGen` feeds it: for a
test consumer it emits the `.wiremvc(…)` suite-trait factory in place of the `@main`, a typed client per
controller, the `withClient` accessors, and, when the target declares a `TestingKey`, the keyed harness
that supplies per-request doubles. This spec covers the suite trait and its modes, the typed and untyped
clients, the keyed harness, the in-process transport, and the runtime errors.

Rationale: [TestingArchitecture](../../../Documentation/Notes/TestingArchitecture.md), [ControllerScopedTesting](../../../Documentation/Notes/ControllerScopedTesting.md), [WireMVCTesting](../../../Documentation/Notes/WireMVCTesting.md).
Documentation: [TestingAnApp](../../../Sources/WireMVC/WireMVC.docc/TestingAnApp.md).

## Requirements

### Requirement: The suite-trait factory is generated for a test consumer in place of the `@main`
For a `@WireMVCBootstrap` root, `WireMVCRouteGen` invoked with `--test-entry` SHALL emit
`static func wiremvc<WireMVCTestServerType: HTTPServer>(_ mode: WireMVCTestMode<WireMVCTestServerType>, environment: (@Sendable () throws -> [String: String])? = nil, services: WireMVCTestServices? = nil) -> WireMVCSuiteTrait`
in `extension SuiteTrait where Self == WireMVCSuiteTrait`, together with `import WireMVCTesting` and
`import Testing`, and SHALL NOT emit a `@main`. Without `--test-entry` it SHALL emit the `@main` and no
`wiremvc` factory. `WireMVCBuildPlugin` SHALL pass `--test-entry` to a target that depends on the
`WireMVCTesting` product.

#### Scenario: a test consumer
- **WHEN** `generateRouteContributors` runs with `testEntry: true` over sources declaring a `@WireMVCBootstrap`
- **THEN** the output contains `static func wiremvc<WireMVCTestServerType: HTTPServer>(` and no `static func main()`

#### Scenario: a program consumer
- **WHEN** `generateRouteContributors` runs with `testEntry: false` over the same sources
- **THEN** the output contains `struct _WireMVCBootstrapEntry {` and neither `import WireMVCTesting` nor `import Testing`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`generateEmitsTestServerEntryUnderTestEntryGate`, `generateEmitsBootstrapEntryAndWireImport`, `bootstrapEntryGeneratesMain`). The absence of the `wiremvc` factory without `--test-entry` is pinned by nothing yet: `generateEmitsBootstrapEntryAndWireImport` checks for `static func wiremvc()`, a spelling no output contains (https://github.com/swift-wire/wire-mvc/issues/250). The plugin's `--test-entry` pass is pinned by `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` compiling against the generated factory.

### Requirement: The app's `createServer()` is never called under test
The generated suite factory SHALL create the app's route builder over `mode.makeTestServer()`, wrapped in
`WireMVCContextServer`, and SHALL NOT call the bootstrap's `createServer()`. The `@main` SHALL remain the
one generated entry that calls `createServer()`.

#### Scenario: a bootstrap declaring `createServer()`
- **WHEN** the test entry is rendered for a `@WireMVCBootstrap` that declares `func createServer() throws -> NIOHTTPServer`
- **THEN** the rendered entry contains `let server = WireMVCContextServer(mode.makeTestServer())` and does not contain `createServer()`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`testEntryNeverCallsCreateServer`).

### Requirement: The mode carries the server and the client that reaches it
`WireMVCTestMode<Server>` SHALL hold a server factory, a client factory and a default services policy.
`.inProcess` SHALL build an `InProcessServer` with default services `.skip`. `.server(_:)` SHALL require
`Server: WireMVCTestServer`, build the client from `server.wireMVCBoundPort` on `127.0.0.1`, and default
services to `.run`. `.server(_:on:)` SHALL build the client on the given port with no read-back and
default services to `.run`.

#### Scenario: the in-process default policy
- **WHEN** `WireMVCTestMode.inProcess.defaultServices` is read
- **THEN** it is `.skip`

#### Scenario: an ephemeral live server
- **WHEN** a suite is declared `@Suite(.wiremvc(.server(SomeServer())))` with `SomeServer: WireMVCTestServer`
- **THEN** the client is built from `wireMVCBoundPort` once the server is serving, and the graph's services start unless the suite passes `services: .skip`

Pinned by: `Tests/WireMVCTestingTests/ServicePolicyTests.swift` (`explicitSkipOverridesALiveModeDefault`) for the in-process default only. The `.run` default of the live modes and a `services: .skip` override of it are pinned by nothing yet (https://github.com/swift-wire/wire-mvc/issues/250). `.server(_:)` is exercised through `.swiftHttpServer` by `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`servesHelloRouteOverEphemeralPort`). `.server(_:on:)` is pinned by nothing yet.

### Requirement: `.swiftHttpServer` is a harness-owned plaintext HTTP/1.1 loopback server behind the `NIOHTTPServer` trait
Under `#if NIOHTTPServer`, `WireMVCTestMode` where `Server == NIOHTTPServer` SHALL offer `swiftHttpServer`,
which is `.server(_:)` over a harness-built `NIOHTTPServer` bound to port `0`, and `swiftHttpServer(on:)`,
which is `.server(_:on:)` over one bound to the given port. Both SHALL construct the server with
`bindTarget: .hostAndPort(host: "127.0.0.1", port:)`, `supportedHTTPVersions: [.http1_1]` and
`transportSecurity: .plaintext`. With the trait off, neither
factory nor the `NIOHTTPServer: WireMVCTestServer` conformance SHALL exist.

#### Scenario: an ephemeral loopback suite
- **WHEN** a suite is declared `@Suite(.wiremvc(.swiftHttpServer))` in a package that enables the `NIOHTTPServer` trait
- **THEN** `GET /hello/Alice` through the typed client answers `Hello, Alice!` over a real HTTP round-trip

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`servesHelloRouteOverEphemeralPort`, `notFoundFallbackServes`).

### Requirement: The server is built at suite entry, not when the attribute is evaluated
`WireMVCTestMode` SHALL hold `makeServer` as a closure and `server(_:)` and `server(_:on:)` SHALL take the
server as an `@autoclosure`, so no server exists until the generated factory calls `makeTestServer()`
inside `WireMVCSuiteTrait`'s serve closure. `WireMVCSuiteTrait.provideScope` SHALL run that closure only
when `testCase == nil`, so the app is built once per suite and each test case runs against it; the trait
SHALL declare `isRecursive = false`.

#### Scenario: a filtered-out suite
- **WHEN** a bundle evaluates `@Suite(.wiremvc(.server(NIOHTTPServer(…))))` for a suite the run filters out
- **THEN** no `NIOHTTPServer` is constructed for it

#### Scenario: a test case inside the suite
- **WHEN** `provideScope` is called with a non-`nil` `testCase`
- **THEN** it executes the test directly without serving again

Pinned by: nothing yet.

### Requirement: The services policy decides whether the graph's collated services run
`WireMVCTesting.runSuite` SHALL start the graph's collated `ServiceLifecycle` services through
`WireMVC.runServices` only when `servicePolicy ?? mode.defaultServices == .run`, and SHALL cancel them with
the server after `runTests` returns.

#### Scenario: in-process with no policy stated
- **WHEN** `runSuite(.inProcess, …, services: [service])` runs without `servicePolicy`
- **THEN** the service does not run

#### Scenario: an explicit `.run`
- **WHEN** `runSuite(.inProcess, …, services: [service], servicePolicy: .run)` runs
- **THEN** the service is running while the tests execute

Pinned by: `Tests/WireMVCTestingTests/ServicePolicyTests.swift` (`inProcessSkipsServicesByDefault`, `servicePolicyRunStartsThem`).

### Requirement: `prepare()` runs once per process under the suite factory
When the bootstrap declares `prepare()`, the generated suite factory SHALL call it as
`try await WireMVCTesting.preparedOnce { … prepare() }`, and `preparedOnce` SHALL memoise the first
caller's `Task` under a mutex so every later suite entry awaits the same result. The `@main` SHALL call
`prepare()` bare.

#### Scenario: several `.wiremvc()` suites in one bundle
- **WHEN** a test bundle with more than one `@Suite(.wiremvc(…))` runs against a bootstrap whose `prepare()` counts its calls
- **THEN** the count is `1` after all suites have run, and the value `prepare()` returned reached the graph as its `inputs:`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/WithTestServerTests.swift` (`prepareRanOnlyOncePerProcess`, `prepareRanBeforeAnyBindingWasConstructed`, `inputsFromPrepareReachedTheGraph`).

### Requirement: The `environment:` provider is applied around the bootstrap and restored on exit
The generated factory SHALL wrap its build in `WireMVCTesting.withEnvironment(environment) { … }`.
`withEnvironment` SHALL evaluate the provider at suite entry, `setenv` each value before the body runs,
and on every exit restore each variable's previous value or `unsetenv` one that had none. A `nil`
provider SHALL run the body untouched.

#### Scenario: a suite declaring an environment
- **WHEN** a suite is declared `@Suite(.wiremvc(.inProcess, environment: { ["DEPLOYMENT_SETTING": "from-the-suite"] }))` and a `@Provides` reads that variable
- **THEN** the route serving the bound value answers `from-the-suite`

#### Scenario: a variable that had no value
- **WHEN** `withEnvironment(["K": "applied"]) { … }` runs and `K` was unset before
- **THEN** `K` is `applied` inside the body and unset again afterwards, including when the body throws

#### Scenario: a variable that had a value
- **WHEN** `withEnvironment(["K": "overridden"]) { … }` runs and `K` was `original` before
- **THEN** `K` is `original` again afterwards

Pinned by: `Tests/WireMVCTestingTests/TestEnvironmentTests.swift` (`appliesValuesForTheBodyAndUnsetsAfter`, `restoresAPreviousValueRatherThanUnsetting`, `restoresWhenTheBodyThrows`, `nilProviderRunsTheBodyUntouched`), `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedHarnessEmitsDoublesAwareDispatchAndFactory`), `Fixtures/Tests/WireMVCBootstrapExampleTests/SuiteEnvironmentTests.swift` (`suppliedEnvironmentReachesTheBootstrap`).

### Requirement: The harness is marked active for the whole serving window
`runSuite` SHALL hold `WireMVCTesting.harnessActivity` for its duration, so `WireMVCTesting.harnessIsActive`
reads `true` while any suite is serving in the process and `false` otherwise. The mark SHALL be a count,
released in a `defer`, so overlapping suites each keep it and a throwing body still clears its own hold.

#### Scenario: outside any suite
- **WHEN** no `runSuite` is in flight
- **THEN** `harnessIsActive` is `false`

#### Scenario: two overlapping holds
- **WHEN** one hold ends while another is still open
- **THEN** the mark stays active until the second ends

Pinned by: `Tests/WireMVCTestingTests/TestBindStoreTests.swift` (`inactiveUntilABodyIsHeld`, `activeOnlyForTheDurationOfTheBody`, `overlappingHoldsEachKeepTheMark`, `aThrowingBodyStillClearsItsHold`, `theGlobalMarkIsHeldInsideWithActiveHarness`) for the count, the `defer` and the global mark's wiring to `withActiveHarness`. That `runSuite` takes the hold is pinned by nothing yet (https://github.com/swift-wire/wire-mvc/issues/250).

### Requirement: A typed client is generated per controller with one method per typed route
For each `@Controller` in a test consumer, `WireMVCRouteGen` SHALL emit `struct <Name>Client { let client: TestClient }`
with one method per verb-annotated route, named after the handler, whose parameters are the route's
bindings (an optional binding stays optional) plus `headers: [String: String] = [:]`, and whose return
is the route's response body type decoded through the mode's own codec. A `@ResponseStatus` route SHALL
return nothing. Every method SHALL funnel through `TestClient.routeResponse`, which SHALL throw
`WireMVCRouteError(status:body:route:)` for any status whose kind is not `.successful`, with `route`
spelled `"<METHOD> <resolved path>"`. The client SHALL NOT be emitted for a program consumer.

#### Scenario: a JSON route
- **WHEN** `NotesController` declares `@Get("/{id}") @JSONResponse func fetch(@Path("id") id: String) async throws -> Note`
- **THEN** `NotesControllerClient` has `func fetch(id: String, headers: [String: String] = [:]) async throws -> Note`

#### Scenario: a route answering 401
- **WHEN** a typed method drives a route that answers `401` with body `nope`
- **THEN** the call throws `WireMVCRouteError` with `status == .unauthorized`, `bodyText == "nope"` and `route == "GET /fail"`

#### Scenario: a program consumer
- **WHEN** `generateRouteContributors` runs with `testEntry: false`
- **THEN** the output contains no `<Name>Client`

Pinned by: `Tests/WireMVCCodegenTests/ControllerClientGenerationTests.swift` (`aTypedRouteBecomesATypedMethod`, `headerAndBodyBindingsBecomeArguments`, `aStatusOnlyRouteReturnsVoid`, `anOptionalQueryDoesNotSwallowLaterItems`, `theClientIsOnlyEmittedForATestConsumer`), `Tests/WireMVCTestingTests/TypedRouteClientTests.swift` (`nonSuccessThrowsWithStatusAndBody`), `Fixtures/Tests/WireMVCBootstrapExampleReplaceTests/ReplaceTests.swift` (`globalErrorTierMapsToBadRequest`). The failure side is untyped: https://github.com/swift-wire/wire-mvc/issues/171.

### Requirement: A text-mode route's method returns the body as `String`
A route whose response mode declares `client: .text`, `@HTMLResponse` included, SHALL get a method
returning `String`, the undecoded `bodyText` of the response, after the non-2xx rule has applied.

#### Scenario: an HTML page
- **WHEN** `PagesController` declares `@Get("/home") @HTMLResponse func home() async throws -> some HTML`
- **THEN** `PagesControllerClient.home()` returns the rendered markup as a `String` beginning `<!DOCTYPE html>`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/HTMLResponseOverTheWireTests.swift` (`theClientHandsBackTheRenderedMarkup`, `aNonSuccessStatusThrows`), `Tests/WireMVCCodegenTests/HTMLResponseGenerationTests.swift` (`noRouteIsSilentlyDropped`).

### Requirement: A `@RawRoute` gets a shim over `performRawRoute`
For a `@RawRoute`, the client SHALL emit a generic method `<name><WireMVCRawReturn: ~Copyable>` whose
parameters are one `String` per `{placeholder}` in the path template (in order, de-duplicated, with the
parameter name camel-cased from the placeholder), `headers:`, `body: consuming HTTPClientRequestBody<TestRequestWriter>? = nil`
and `responseHandler: (HTTPResponse, consuming TestResponseReader) async throws -> WireMVCRawReturn`.
The shim SHALL call `TestClient.performRawRoute`, hand the response head and a body reader to the handler,
apply no status rule, and return the handler's value.

#### Scenario: a raw route with a placeholder
- **WHEN** `HelloController` declares `@Get("/raw/{name}") @RawRoute func rawGreeting(…)`
- **THEN** `hello.rawGreeting(name: "Alice") { response, reader in try await reader.collectText() }` returns the route's body and `response.status` is assertable inside the closure

#### Scenario: a raw route answering 401
- **WHEN** `performRawRoute(method: "GET", path: "/fail") { … }` drives a route answering `401`
- **THEN** the closure still runs with `response.status == .unauthorized` and no error is thrown

Pinned by: `Tests/WireMVCCodegenTests/ControllerClientGenerationTests.swift` (`rawRoutesGetAnUntypedShim`, `aRawRoutesPlaceholdersBecomeParameters`, `placeholdersAreReadInOrderAndSanitised`), `Tests/WireMVCTestingTests/TypedRouteClientTests.swift` (`theRawFormHandsOverTheHeadAndReader`, `aStreamedRequestBodyReachesTheRoute`), `Fixtures/Tests/WireMVCBootstrapExampleReplaceTests/ReplaceTests.swift` (`rawRouteShimDerivesThePath`).

### Requirement: `@NotFound` gets no typed surface and an empty client is not emitted
The `@NotFound` fallback SHALL have no method on any client. A controller with no route of derivable
shape SHALL produce no client type at all.

#### Scenario: the fallback
- **WHEN** a test drives an unmatched path
- **THEN** it does so through the untyped `withClient { client in client.get("/no/such/route") }` and reads `status == 404`

#### Scenario: a controller with no routes
- **WHEN** `@Controller("/exports") struct ExportController { func notARoute() {} }` is rendered
- **THEN** `renderControllerClient` returns a `nil` source

Pinned by: `Tests/WireMVCCodegenTests/ControllerClientGenerationTests.swift` (`aControllerWithNoRouteEmitsNothing`), `Fixtures/Tests/WireMVCBootstrapExampleReplaceTests/ReplaceTests.swift` (`notFoundFallbackServes`).

### Requirement: A declared `@Header` beats the `headers:` bag
A typed method SHALL build its header set as `headers.merging(wireMVCRequest.headers) { _, declared in declared }`,
so a header the route binds with `@Header` is sent from the typed parameter when the caller also names
it in `headers:` with the same spelling, and headers the route does not declare travel from the bag unchanged.
The merge is case-sensitive: a bag key differing from the `@Header` name only in case survives beside the
declared one, and which value is sent then depends on dictionary order, which is tracked as a defect in
https://github.com/swift-wire/wire-mvc/issues/248.

#### Scenario: a collision
- **WHEN** `pages.tenant(tenant: "declared", headers: ["x-tenant": "caller"])` drives a route binding `@Header("x-tenant")`
- **THEN** the route sees `declared`

#### Scenario: an undeclared header
- **WHEN** `pages.tenant(tenant: "acme", headers: ["x-trace": "abc123"])` is called
- **THEN** the request carries `x-trace: abc123`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleTests/HTMLResponseOverTheWireTests.swift` (`aDeclaredHeaderBeatsTheCallersBag`). The undeclared-header scenario is pinned by nothing yet: `theBagStillCarriesUndeclaredHeaders` asserts only the declared header's effect (https://github.com/swift-wire/wire-mvc/issues/250).

### Requirement: A route with a graph-aware binding is omitted from the client with a warning
When a route parameter's binding is declared `isScopeResolved`, the client SHALL omit that route and
`WireMVCRouteGen` SHALL report `routeOmittedFromClient` as a warning at the parameter:
`'<route>' is omitted from the generated client: '@<binding> <parameter>' resolves from the request scope, so a client has no value to send for it — the handler's parameter type is what the *scope* produced, not what the caller supplies. The route stays drivable through the untyped client`.
The controller's other routes SHALL still get methods. A route whose binding carries the `.bodyStream`
obligation SHALL be omitted without a diagnostic.

#### Scenario: a controller whose only route is scope-resolved
- **WHEN** `DocumentsController`'s one route takes a `@Document`-style graph-aware parameter
- **THEN** no client is emitted and the diagnostics contain one `routeOmittedFromClient`

Pinned by: `Tests/WireMVCCodegenTests/GraphAwareBindingTests.swift` (`theRouteIsOmittedFromTheClientAndSaidSo`, `theControllersOtherRoutesStillGetAClient`), `Tests/WireMVCCodegenTests/BindingObligationsTests.swift` (`lentStreamRouteOmitted`) for the lent-stream route's omission. That it is omitted without a diagnostic is pinned by nothing yet (https://github.com/swift-wire/wire-mvc/issues/250).

### Requirement: Typed sending goes through `RequestSendable` and `RequestBodySendable`
A typed method SHALL build a `WireMVCOutgoingRequest` and, per binding, call
`<Wrapper><T>.send(name:value:into:coding:)` or, for a body binding,
`let wireMVCBody = try <Wrapper><T>.sendBody(name:value:into:coding:)`, then pass
`wireMVCRequest.pathParameters`, `wireMVCRequest.query`, and for a body `wireMVCBody.bytes` with
`wireMVCBody.contentType` to `routeResponse`. `Path`, `Query` and `Header` SHALL conform to
`RequestSendable` where `T: LosslessStringConvertible`; `JSONBody` SHALL conform to `RequestBodySendable`
where `T: Decodable & Encodable`. Conformance SHALL be on the underlying type, never the optional; an
optional binding SHALL be sent only when non-`nil`.

#### Scenario: the built-ins
- **WHEN** `Path<String>.send(name: "id", value: "42", into: &request, coding: .default)` runs
- **THEN** `request.pathParameters == ["id": "42"]`; `Query` appends to `query` and `Header` writes `headers`

#### Scenario: a JSON body
- **WHEN** `JSONBody<Payload>.sendBody(…)` runs
- **THEN** it returns the encoded bytes and content type `application/json`

Pinned by: `Tests/WireMVCTestingTests/RequestSendingTests.swift` (`builtInsPlaceThemselves`, `conformanceIsOnTheUnderlyingType`, `bodyBindingSuppliesBoth`), `Tests/WireMVCCodegenTests/ControllerClientGenerationTests.swift` (`headerAndBodyBindingsBecomeArguments`).

### Requirement: Path templating and percent-encoding are the runtime's
`TestClient.resolve(template:pathParameters:query:)` SHALL substitute each `{name}` with the
percent-encoded value and append `?name=value&…` in declaration order, encoding every character outside
RFC 3986's unreserved set (`A-Z a-z 0-9 - . _ ~`). No query items SHALL leave the path without a `?`.
A trailing catch-all `{name*}` is not substituted: the typed client keys a catch-all binding's value under
the bare `name`, so `resolve` finds no `{name}` and the template text is sent as written, which is tracked
as a defect in https://github.com/swift-wire/wire-mvc/issues/247.

#### Scenario: a path value containing a slash and a space
- **WHEN** `resolve(template: "/notes/{id}", pathParameters: ["id": "a/b c"], query: [])` is called
- **THEN** it returns `/notes/a%2Fb%20c`

#### Scenario: a query value containing an ampersand
- **WHEN** `resolve(template: "/todos", pathParameters: [:], query: [("q", "a&b"), ("page", "2")])` is called
- **THEN** it returns `/todos?q=a%26b&page=2`

Pinned by: `Tests/WireMVCTestingTests/TypedRouteClientTests.swift` (`placeholdersAreSubstituted`, `pathValuesArePercentEncoded`, `queryItemsAreAppendedAndEncoded`, `noQueryLeavesThePathAlone`, `theResolvedPathReachesTheRoute`).

### Requirement: The untyped client offers the verbs and a general `send`
`TestClient` SHALL offer `get(_:headers:)`, `post(_:json:headers:)`, `patch(_:json:headers:)`,
`delete(_:headers:)` and `send(_ method:_ path:body:headers:)`. `post` and `patch` SHALL encode `json`
with `JSONEncoder` and set `Content-Type: application/json`. Every verb SHALL return a `TestResponse`
carrying the response head, the body `Data`, `bodyText` and `json(_:)`. In process the head is the
handler's own `HTTPResponse`; on the loopback transport it is rebuilt from `HTTPURLResponse.allHeaderFields`,
so header field order and repeated fields are not preserved.

#### Scenario: a CORS preflight
- **WHEN** `client.send("OPTIONS", "/ping", headers: ["Origin": …, "Access-Control-Request-Method": "POST"])` is called
- **THEN** the route answers `204` and the response head's CORS fields are readable

#### Scenario: a request with a body and headers
- **WHEN** `client.post("/notes", json: Payload(note: "hi"), headers: ["X-Echo": "seen"])` is driven in process
- **THEN** the handler receives `POST /notes`, the body `{"note":"hi"}` and the `X-Echo` header

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aPreflightIsAnsweredWithBothFieldSets`), `Tests/WireMVCTestingTests/InProcessTransportTests.swift` (`driverBindsClientAndRoutesMethodAndPath`, `requestBodyAndHeadersReachTheHandler`). The `Content-Type: application/json` header and the `patch` verb are pinned by nothing yet (https://github.com/swift-wire/wire-mvc/issues/250).

### Requirement: An unanswered route is distinguishable from any status in process
On the in-process transport, when a handler returns without sending a response, the untyped verbs SHALL return a `TestResponse` whose
`head` is `nil` and whose `status` is `TestResponse.unanswered`, which is `-1`. The typed paths
(`routeResponse` and `performRawRoute`) SHALL throw `WireMVCTestingError.routeDidNotRespond("<METHOD> <path>")`
instead. The loopback transport makes no such distinction: the outcome is whatever `URLSession.data(for:)`
produces for the connection.

#### Scenario: a silent handler driven in process
- **WHEN** `TestClient.forSuite.get("/anything")` drives a handler that returns without responding
- **THEN** `response.status == -1` and `response.body.isEmpty`

Pinned by: `Tests/WireMVCTestingTests/InProcessTransportTests.swift` (`handlerThatNeverRespondsIsDistinguishable`). The `routeDidNotRespond` throw is pinned by nothing yet.

### Requirement: A client is reached only through `withClient`
For every test consumer whose composed sources declare a `@WireMVCBootstrap`, `WireMVCRouteGen` SHALL emit a module-scope `withClient<R>(_ body: (TestClient) async throws -> R)`
and, per controller with a client, `withClient<R>(for _: <Name>Client.Type, _ body: (<Name>Client) async throws -> R)`,
both `@discardableResult` and both handing out a client carrying no doubles. No ambient accessor SHALL be
emitted. A test consumer without a `@WireMVCBootstrap` still gets its `<Name>Client` types but no
`withClient`, which is tracked in https://github.com/swift-wire/wire-mvc/issues/249. `TestClient.forSuite` SHALL be non-public and SHALL trap outside a suite the trait scopes with
`A WireMVC test client is only available inside an @Suite(.wiremvc(…)) suite — reach it through withClient(supplying:) or withClient(for:)`.

#### Scenario: a keyless test consumer
- **WHEN** `generateRouteContributors` runs with `testEntry: true` over a bootstrap and `NotesController`
- **THEN** the output contains `for _: NotesControllerClient.Type,` and neither `var notesController:` nor `static var current`

Pinned by: `Tests/WireMVCCodegenTests/ControllerClientGenerationTests.swift` (`theClientIsOnlyEmittedForATestConsumer`). The `forSuite` trap is pinned by nothing yet.

### Requirement: Each `withClient` scope gets a fresh loopback session with cookies and cache disabled
On the loopback transport, `withClient` and `withClient(supplying:)` SHALL hand the body a client over a
fresh `URLSession` built by `TestClient.makeSession()`, with `httpCookieStorage = nil`,
`httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never`, `urlCache = nil` and
`requestCachePolicy = .reloadIgnoringLocalCacheData`, and SHALL invalidate it on exit. Every rendered
`URLRequest` SHALL set `httpShouldHandleCookies = false`. The in-process transport holds no session.

#### Scenario: an explicit cookie header
- **WHEN** a request is rendered with `headers: ["Cookie": "session=first"]`
- **THEN** the `URLRequest` carries exactly that `Cookie` value and `httpShouldHandleCookies == false`

#### Scenario: a cacheable route
- **WHEN** a route answers with a freshness directive and a later identical `GET` is driven
- **THEN** the second response comes from the server, not a cache

Pinned by: `Tests/WireMVCTestingTests/TestBindStoreTests.swift` (`doesNotLetURLSessionManageCookies`), `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aCacheableRouteIsNotReplayedForALaterRequest`).

### Requirement: One `TestingKey` per target, and only the consumer module's key is served
For a test consumer, `discoverTestingKeys` SHALL find every `static let`/`let` initialised with
`TestingKey()` or annotated `: TestingKey` in the composed sources, read its `@BindType` markers in both
the metatype and the `BindingKey` forms, and serve the first key found in the consumer module's own
sources. Every further key in those sources SHALL be reported as an error at its declaration:
`the keyed test harness serves one TestingKey per target, and '<first>' is already this target's key — a suite passing '<reference>' would be served '<first>''s variant graph instead, silently. Move '<reference>' to its own test target, or fold its @BindType markers into '<first>'. (Serving several variants from one target is deferred — see swift-wire/swift-wire#336.)`.
A key in a source attributed to another module SHALL be skipped without a diagnostic. No key SHALL be no
error.

#### Scenario: a second key in the same target
- **WHEN** the composed sources declare `Binds.mock` and `OtherBinds.mock`, both `TestingKey()`
- **THEN** exactly one `multipleTestingKeys` diagnostic is reported

#### Scenario: a dependency's key
- **WHEN** `Lib.swift` (module `SharedLib`) declares `LibBinds.mock` and `App.swift` (module `MyTests`) declares `Binds.mock`, with `consumerModule: "MyTests"`
- **THEN** no diagnostic is reported, `enum _WireMVCKeyed_Binds_mock` is emitted, and nothing named `LibBinds_mock` is

#### Scenario: no key
- **WHEN** a test consumer declares only a `@WireMVCBootstrap`
- **THEN** no diagnostic is reported and the keyless factory alone is emitted

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`aSecondTestingKeyIsRejected`, `aDependencysTestingKeyIsNotServed`, `withoutModuleAttributionEveryKeyIsStillEligible`, `noTestingKeyIsNotAnError`, `testingKeyDiscoveryDerivesNames`, `testingKeyDiscoveryReadsKeyedBindTypeForm`, `testingKeyDiscoveryResolvesBindingKeyOnExtension`). In the no-key scenario, `noTestingKeyIsNotAnError` pins only the absence of a diagnostic; `generateEmitsTestServerEntryUnderTestEntryGate` pins the keyless factory, and `keyedHarnessImportsWireTestingAndKeylessDoesNot` pins that keyless output names no `TestingKey`. Multi-key is tracked at https://github.com/swift-wire/wire-mvc/issues/170 and https://github.com/swift-wire/swift-wire/issues/336.

### Requirement: The keyed factory bootstraps the variant graph and registers each subject's variant proxy
When a test consumer declares a `TestingKey` with at least one variant subject, `WireMVCRouteGen` SHALL emit
a second factory `wiremvc(_ key: TestingKey, _ mode: WireMVCTestMode<WireMVCTestServerType>, environment:, services:)`
alongside the keyless one, and SHALL add `import WireTesting`. Its build SHALL call
`Wire.bootstrap<Variant>()`, then for each subject `let wireMVCVariantProxy_<Subject> = Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph: graph)`
and `try wireMVCVariantProxy_<Subject>.registerWireRoutes(on: &builder, coding: …)` before `finalize()`.
A program consumer SHALL get none of this and its scoped dispatch SHALL be the production scope entry.

#### Scenario: a keyed test consumer
- **WHEN** the composed sources declare `Binds.mock` with `@BindType(NoteBackend.self, MockNoteBackend.self)` and a `@Scoped(seed:)` `NotesController`
- **THEN** the output contains `_ key: TestingKey, _ mode: WireMVCTestMode<WireMVCTestServerType>,`, `let graph = try await Wire.bootstrapBinds_mock()`, `Wire.bootstrapBinds_mock_NotesControllerContributor(wireGraph: graph)` and `import WireTesting`

#### Scenario: the same sources as a program consumer
- **WHEN** `generateRouteContributors` runs with `testEntry: false`
- **THEN** the output contains `let wireMVCScopeEntry = try await self._wireEnterScope(request)` and nothing named `wireMVCVariantProxy`, `_WireMVCKeyed_` or `wiremvc(_ key:`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedHarnessEmitsDoublesAwareDispatchAndFactory`, `keyedHarnessImportsWireTestingAndKeylessDoesNot`, `productionDispatchIsUnchangedWithoutTestEntry`).

### Requirement: The key a suite passes is asserted at suite entry
When the served key's declaring module is known, the keyed factory SHALL begin its build with
`precondition(key == TestingKey(fileID: "<Module>/<File>.swift", line: <line>), "<message>")`, where the
message is
`@Suite(.wiremvc(…)) was passed a TestingKey this target does not serve. This target's harness is built for '<key>' (<fileID>:<line>); serving a different key's substitutions would need its own variant graph, which only the target declaring it emits. Pass <key>, or move the suite to the target that declares the key you meant.`.
The check SHALL run inside the serve closure, not when the attribute is evaluated. Without module
attribution no assertion SHALL be emitted.

#### Scenario: attributed sources
- **WHEN** `generateRouteContributors` runs with `sourceModules: ["App.swift": "MyTests"]` and `static let mock = TestingKey()` is on line 16
- **THEN** the output contains `key == TestingKey(fileID: "MyTests/App.swift", line: 16)` inside a `precondition(`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedFactoryAssertsTheKeyItWasBuiltFor`).

### Requirement: Every `@Scoped(seed:)` controller and every `@TestScopable` controller is a variant subject
Under a served key, `keyedScopeEntry(for:key:)` SHALL treat a controller as a variant subject when it
carries `@Scoped(seed:)` or `@TestScopable`. For each subject the harness SHALL emit, in
`enum _WireMVCKeyed_<Variant>`, `static let <subject>Doubles = TestBindStore<_<Variant>_<Subject>Doubles>()`,
a `typealias <Subject>Doubles = _<Variant>_<Subject>Doubles`, and a `@discardableResult withClient<R>(supplying doubles: _<Variant>_<Subject>Doubles, _ body:)`
overload whose body receives `<Subject>Client` when one exists and `TestClient` otherwise. A seed-scoped
subject SHALL enter scope through `_wireEnterScope(request, doubles)`; a seedless one through
`_wireEnterScope(doubles)`.

#### Scenario: a seed-scoped subject
- **WHEN** `NotesController` is `@Scoped(seed: HTTPRequest.self)` and injects the substituted `NoteBackend`
- **THEN** `withClient(supplying: NotesControllerDoubles(noteBackend: mock)) { notes in … }` serves the mock on `GET /notes/{id}`

#### Scenario: a `@TestScopable` singleton
- **WHEN** `SummaryController` is an app `@Singleton` marked `@TestScopable`
- **THEN** `withClient(supplying: SummaryControllerDoubles(…))` rebuilds it per request and its route serves the mock

#### Scenario: a subject reaching no substituted slot
- **WHEN** `PingController` is a subject whose doubles struct has no fields
- **THEN** `withClient(supplying: PingControllerDoubles())` serves `/ping`

Pinned by: `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedHarnessEmitsDoublesAwareDispatchAndFactory`), `Fixtures/Tests/WireMVCBootstrapExampleBindTests/BindTests.swift` (`suppliedMockIsObservedOverHTTP`, `appScopedTestScopableRouteServesMockSeedlessly`, `seedScopedRouteWithMockConsumingMiddlewareServesMock`, `keyedBindTypeSlotThreadsMockOverHTTP`, `mockIgnoringRouteServesUnderWithBindValues`, `factoryCarryingRouteEntersAndServes`).

### Requirement: `withClient(supplying:)` correlates doubles by a header the client carries
`WireMVCTesting.withClient(supplying:in:_:)` SHALL mint a `CorrelationID` (a `UUID`), `put` the doubles
in the subject's `TestBindStore` under it, hand the body `TestClient.forSuite.withFreshTransport().bound(to: id)`,
and `remove` the slot in a `defer`. A bound client SHALL stamp `X-WireMVC-Test-Binds`
(`wireMVCTestBindsHeader`) with the id's `uuidString` on every request it renders, on both transports;
an unbound client SHALL stamp nothing. `bound(to:)` SHALL return a new client and leave the original
unbound.

#### Scenario: the slot's lifetime
- **WHEN** a `withClient(supplying:)` body runs, then exits normally or by throwing
- **THEN** the store holds the doubles under the body's id while it runs and not afterwards

#### Scenario: nested bindings of one controller
- **WHEN** `withClient(supplying: NotesControllerDoubles(noteBackend: outer)) { notes1 in withClient(supplying: NotesControllerDoubles(noteBackend: inner)) { notes2 in … } }` drives both clients inside the inner block
- **THEN** `notes1` resolves `outer` and `notes2` resolves `inner`

#### Scenario: a cross-controller flow
- **WHEN** a `PrefsController` block is nested inside a `NotesController` block and the outer client is driven from inside
- **THEN** each controller sees only its own mock and the outer client still works after the inner block exits

Pinned by: `Tests/WireMVCTestingTests/TestBindStoreTests.swift` (`putValueRemoveRoundTrip`, `suppliedDoublesBindTheClientAndClearAfter`, `suppliedDoublesRemoveTheSlotOnThrow`, `concurrentClosuresGetDistinctIDsAndIsolatedSlots`, `correlationIDHeaderRoundTrip`, `stampsHeaderWhenTheClientCarriesAnID`), `Tests/WireMVCTestingTests/InProcessTransportTests.swift` (`correlationHeaderIsStampedOnTheInProcessRequest`), `Fixtures/Tests/WireMVCBootstrapExampleBindTests/BindTests.swift` (`nestedBindingsOfOneControllerStayDistinct`, `crossControllerFlowDrivesBothClients`).

### Requirement: The keyed dispatch resolves doubles only while a harness is active, else answers an explicit 500
Each variant subject's generated witness SHALL guard its scope entry with
`WireMVCTesting.harnessIsActive`, `wireMVCTestCorrelationID(in: request)` and
`_WireMVCKeyed_<Variant>.<subject>Doubles.value(for:)`. When any of the three fails it SHALL send
`.internalServerError` with the body
`WireMVC keyed test harness: no bound doubles for a request reaching this route under key <key> — wrap the request in withClient(supplying: <Subject>Doubles(...))`
followed by a newline, and return. `wireMVCTestCorrelationID(in:)` SHALL be a pure header read that does
not consult `harnessIsActive`.

#### Scenario: a keyed route driven without doubles
- **WHEN** `withClient(for: NotesControllerClient.self) { notes in try await notes.note(id: "y") }` runs under the keyed suite
- **THEN** it throws `WireMVCRouteError` with `status == .internalServerError`

#### Scenario: a subject with an empty doubles struct driven without doubles
- **WHEN** `withClient(for: PingControllerClient.self) { ping in try await ping.ping() }` runs under the keyed suite
- **THEN** it throws `WireMVCRouteError` with `status == .internalServerError`

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleBindTests/BindTests.swift` (`missingDoublesIsExplicit500`, `mockIgnoringRouteWithoutDoublesIs500`), `Tests/WireMVCCodegenTests/RouteContributorGenerationTests.swift` (`keyedHarnessEmitsDoublesAwareDispatchAndFactory`).

### Requirement: Parallel suites and parallel requests do not cross
A keyless `.wiremvc(mode)` suite SHALL serve the production graph and a keyed `.wiremvc(key, mode)` suite
the variant graph, each on its own server, so both can run in one target concurrently on the same route.
Two `withClient(supplying:)` requests in flight at once SHALL each resolve their own doubles.

#### Scenario: a shared route across the two suites
- **WHEN** `KeylessCoexistTests` and `BindTests` run in parallel and both drive `GET /notes/z`
- **THEN** the keyless suite answers `stamped:real:z` and the keyed suite, with doubles supplied, answers `stamped:mock:z`

#### Scenario: two differently-mocked requests held in their handlers simultaneously
- **WHEN** requests tagged `alpha` and `beta`, each with its own `MockNoteBackend`, rendezvous inside the handler
- **THEN** each answers its own tag and each mock records only its own tag

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleBindTests/KeylessCoexistTests.swift` (`keylessSuiteServesRealBackendOnSharedRoute`), `Fixtures/Tests/WireMVCBootstrapExampleBindTests/BindTests.swift` (`keyedSuiteServesMockOnSharedRoute`, `differentlyMockedRequestsInterleaveWithoutCrossing`).

### Requirement: `@Replaces` and `@BindType` are the two substitution mechanisms
A test target SHALL substitute a binding either by declaring a `@Replaces` provider, which the keyless
factory serves through the production graph with no `TestingKey` and no doubles, or by a `@BindType`
marker on a `TestingKey`, which the keyed factory serves with per-request doubles. The `TestingKey`,
`@BindType` and `@TestScopable` semantics are swift-wire's and are specified there.

#### Scenario: a replaced binding
- **WHEN** the test target declares `@Replaces FakeGreeter` and the suite is `@Suite(.wiremvc(.inProcess))`
- **THEN** `hello.hello(name: "Alice")` answers `FAKE:Alice`

#### Scenario: a bound type
- **WHEN** the key declares `@BindType(NoteBackend.self, MockNoteBackend.self)` and a test supplies a `MockNoteBackend`
- **THEN** the route answers through that instance and the instance records the call

Pinned by: `Fixtures/Tests/WireMVCBootstrapExampleReplaceTests/ReplaceTests.swift` (`serveHelloUsesReplacedFakeGreeter`), `Fixtures/Tests/WireMVCBootstrapExampleBindTests/BindTests.swift` (`suppliedMockIsObservedOverHTTP`).

### Requirement: The in-process transport is a real `HTTPServer` that streams over a rendezvous
`InProcessServer` SHALL conform to `HTTPServer` with `InProcessRequestContext`, `InProcessReader` and
`InProcessResponseSender`, and its `serve(handler:)` SHALL run an accept loop over `InProcessDispatch`,
handling each exchange in a child task with at most `64` in flight. `InProcessResponseSender.send`
SHALL publish the head before any body chunk exists, and each `InProcessWriter.write` SHALL suspend on
an `AsyncChannel` until the reader takes the chunk. `TestClient`'s buffered surface SHALL drain that
channel whole; `performRawRoute` SHALL read it chunk by chunk.

#### Scenario: a route writing three chunks
- **WHEN** `performRawRoute(method: "GET", path: "/chunks")` reads a handler that writes `one`, `two`, `three` in separate `write` calls
- **THEN** the head is available before the first write completes, and at every read the handler has completed no more writes than the reader has consumed

#### Scenario: the buffered surface
- **WHEN** `client.get` drives the same streaming handler
- **THEN** the response body is `onetwothree`

Pinned by: `Tests/WireMVCTestingTests/TypedRouteClientTests.swift` (`inProcessAppliesBackpressurePerChunk`) for the per-read bound, `Tests/WireMVCTestingTests/InProcessTransportTests.swift` (`streamedWritesAccumulateIntoOneBody`). The head being available before the first write completes is pinned by nothing yet (https://github.com/swift-wire/wire-mvc/issues/250).

### Requirement: `WireMVCTestServer` reports the bound port or throws `noListeningPort`
`WireMVCTestServer` SHALL require `var wireMVCBoundPort: Int { get async throws }`. Under the
`NIOHTTPServer` trait, `NIOHTTPServer`'s conformance SHALL return `listeningAddresses.first?.port` and
throw `WireMVCTestingError.noListeningPort` when there is none.

#### Scenario: a server that bound no address
- **WHEN** `wireMVCBoundPort` is read on an `NIOHTTPServer` whose `listeningAddresses` yields no port
- **THEN** it throws `WireMVCTestingError.noListeningPort`

Pinned by: nothing yet.

## Related specifications

- [controllers-and-routes](../controllers-and-routes/spec.md)
- [request-bindings](../request-bindings/spec.md)
- [graph-aware-bindings](../graph-aware-bindings/spec.md)
- [request-scope](../request-scope/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [composition-root](../composition-root/spec.md)
- [package-traits](../package-traits/spec.md)
- [build-plugins-and-routegen-cli](../build-plugins-and-routegen-cli/spec.md)
- [server-transport-bridge](../server-transport-bridge/spec.md)
- [swift-wire testing-variants](https://github.com/swift-wire/swift-wire/blob/main/openspec/specs/testing-variants/spec.md)
