# Differences by runtime

## Purpose

The same controllers serve on three runtimes: the proposal-native server, where `FrozenTrieRouter`
routes, and Hummingbird and Vapor, where `WireMVCServerTransport` collates the routes onto the host's
own router and the host decides what a miss means. This spec states, row by row, how the runtimes
differ on the behaviours the DocC article `WhatDiffersByRuntime` tabulates, and what each row is
measured by. The router and the bridge themselves are specified in the trie-router and
server-transport-bridge specs.

Rationale: [WireMVCRouter](../../../Documentation/Notes/WireMVCRouter.md), [CatchAllMountingProbe](../../../Documentation/Notes/CatchAllMountingProbe.md).
Documentation: [WhatDiffersByRuntime](../../../Sources/WireMVC/WireMVC.docc/WhatDiffersByRuntime.md).

## Requirements

### Requirement: A wrong method is a 405 natively and a 404 on the bridged runtimes
On the proposal-native runtime, a request whose path reaches a registered route under a different
method SHALL be answered `405` with an `Allow` header. On Hummingbird and on Vapor, the same request
SHALL be answered `404` with no `Allow` header.

#### Scenario: proposal-native
- **WHEN** `/todos` is registered for `GET` and `POST` and a client sends `DELETE /todos`
- **THEN** the response is `405` with `Allow: GET, POST`

#### Scenario: Hummingbird
- **WHEN** `/only-get` is registered for `GET` on a Hummingbird router through `ServerTransport` and a client sends `DELETE /only-get`
- **THEN** the response is `404` with no `Allow` header

#### Scenario: Vapor
- **WHEN** the same registration is made on Vapor and the same request is sent
- **THEN** the response is `404` with no `Allow` header

Pinned by: `Fixtures/Tests/WireMVCFallbackExampleTests/FallbackTests.swift` (`aWrongMethodOnARealRouteIsMethodNotAllowed`), [SwiftHttpServerExample MethodMismatchTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/SwiftHttpServerExample/Tests/SwiftHttpServerExampleMockedTests/MethodMismatchTests.swift) (`aWrongMethodOnARegisteredPathIs405WithAllow`), [HummingbirdExample MethodMismatchTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/HummingbirdExample/Tests/HummingbirdExampleTests/MethodMismatchTests.swift) (`aWrongMethodOnARegisteredPathIs404NotAllowed`), [VaporExample MethodMismatchTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/VaporExample/Tests/VaporExampleTests/MethodMismatchTests.swift) (`aWrongMethodOnARegisteredPathIs404NotAllowed`).

### Requirement: Path parameters are percent-decoded natively and on Vapor, not on Hummingbird
On the proposal-native runtime and on Vapor, a bound path parameter SHALL reach the handler
percent-decoded. On Hummingbird it SHALL reach the handler exactly as it appeared in the request path.

#### Scenario: proposal-native
- **WHEN** the typed client requests a todo whose id is `does not exist`, `a%zz` or `a/b`
- **THEN** the repository behind the handler is asked for exactly that id

#### Scenario: Hummingbird
- **WHEN** a route with a `{name}` parameter is requested with `a%20b` in that segment
- **THEN** the handler receives `a%20b`

#### Scenario: Vapor
- **WHEN** the same route is requested on Vapor
- **THEN** the handler receives `a b`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aPercentEscapeInAParameterIsDecoded`), [SwiftHttpServerExample PathParameterDecodingTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/SwiftHttpServerExample/Tests/SwiftHttpServerExampleMockedTests/PathParameterDecodingTests.swift) (`anIdWithSpacesRoundTrips`, `anIdWithALiteralPercentRoundTrips`, `anIdWithASlashStaysOneParameter`), [HummingbirdExample PathParameterDecodingTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/HummingbirdExample/Tests/HummingbirdExampleTests/PathParameterDecodingTests.swift) (`aPercentEscapedParameterArrivesUndecoded`), [VaporExample PathParameterDecodingTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/VaporExample/Tests/VaporExampleTests/PathParameterDecodingTests.swift) (`aPercentEscapedParameterArrivesDecoded`).

### Requirement: The trailing slash is a policy natively and lenient on the bridged runtimes
On the proposal-native runtime, a trailing slash on a request path SHALL be governed by the
`TrailingSlashPolicy` the app passes to `TrieRouteBuilder`, `.lenient` by default and `.strict` on
request. On Hummingbird and on Vapor, a trailing slash SHALL be ignored, with no option to change it.

#### Scenario: proposal-native, strict
- **WHEN** `GET /users` is registered on a router frozen with `.strict` and `GET /users/` is requested
- **THEN** the router resolves a miss

#### Scenario: a bridged runtime
- **WHEN** `GET /users` is registered on Hummingbird or Vapor and `GET /users/` is requested
- **THEN** the route serves it

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`lenientTreatsATrailingSlashAsTheSameResource`, `strictRejectsATrailingSlash`). The Hummingbird and Vapor behaviour is pinned by nothing yet.

### Requirement: A duplicate route is fatal natively and on Hummingbird, and overrides on Vapor
On the proposal-native runtime, registering a second route for the same method at the same trie node
SHALL stop the process with a `preconditionFailure` at startup. On Hummingbird, a second handler for
the same method and path SHALL stop the process with Hummingbird's own `preconditionFailure`. On Vapor,
the later registration SHALL replace the earlier one, with an `info`-level log line.

#### Scenario: proposal-native
- **WHEN** two controllers both register `GET /users`
- **THEN** `RouteTrie.insert` reports `.duplicate(existing: "/users")` and `TrieRouteBuilder.register` fails with `duplicate route: GET '/users' is registered twice.`

#### Scenario: Vapor
- **WHEN** two controllers both register `GET /users` on Vapor through the bridge
- **THEN** RoutingKit logs a line beginning `[Routing] Overriding duplicate route for GET` at `info` level, and the second handler serves

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`registeringTheSameMethodAndPathTwiceIsADuplicate`). The native `preconditionFailure` and the Hummingbird and Vapor behaviour are pinned by nothing yet.

### Requirement: A catch-all serves natively and is refused on the bridged runtimes
On the proposal-native runtime, a trailing `{name*}` template SHALL serve and bind the remainder of the
path. On Hummingbird and on Vapor, `WireMVCServerTransport.apply` SHALL throw
`WireMVCServerTransportError.catchAllNotBridgeable` for that template at startup.

#### Scenario: proposal-native
- **WHEN** `AssetsController` declares `@Get("/{path*}")` under `/assets` and a client requests `GET /assets/img/logo/small.svg`
- **THEN** the response is `200` and the handler received `img/logo/small.svg`

#### Scenario: a bridged runtime
- **WHEN** the same controller is composed into a graph passed to `WireMVCServerTransport.apply`
- **THEN** `apply` throws `catchAllNotBridgeable(path: "/assets/{path*}", segment: "{path*}")`

Pinned by: `Tests/WireMVCRouterTests/RouteTrieTests.swift` (`aCatchAllBindsTheRemainder`), [SwiftHttpServerExample AssetRoutingTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/SwiftHttpServerExample/Tests/SwiftHttpServerExampleMockedTests/AssetRoutingTests.swift) (`aCatchAllMatchesADeepPath`). The refusal on the bridged runtimes is pinned by nothing yet.

### Requirement: Ambient task-local context reaches a handler on every runtime
A task-local value bound by the host around request dispatch SHALL be readable inside a WireMVC route
handler on all three runtimes. On Hummingbird and on Vapor it SHALL also be readable in a response body
the handler produces itself, and SHALL NOT be readable in a body sequence the host pulls lazily after the
handler returns.

#### Scenario: host middleware on Hummingbird or Vapor
- **WHEN** a host middleware binds `TracingProbe.$traceID` to `abc-123` and a `ServerTransport`-registered handler returns it
- **THEN** the response body is `abc-123`

#### Scenario: a lazily pulled body on Hummingbird or Vapor
- **WHEN** the handler instead returns a body sequence that reads the task-local in `next()`
- **THEN** the body is `1:<none>\n2:<none>\n3:<none>\n`

#### Scenario: the bridge itself
- **WHEN** a transport call runs inside `TracingProbe.$traceID.withValue("abc-123")` and the WireMVC handler streams three lines reading it
- **THEN** the body is `1:abc-123\n2:abc-123\n3:abc-123\n`

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`taskLocalContextReachesTheHandlerThroughTheBridge`, `taskLocalContextSurvivesIntoAStreamedBody`), [HummingbirdExample AmbientContextTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/HummingbirdExample/Tests/HummingbirdExampleTests/AmbientContextTests.swift) (`taskLocalContextSetByHostMiddlewareReachesTheHandler`, `taskLocalContextIsLostWhenTheFrameworkPullsTheBody`, `taskLocalContextSurvivesWhenTheHandlerProducesTheBytes`), [VaporExample AmbientContextTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/VaporExample/Tests/VaporExampleTests/AmbientContextTests.swift) (`taskLocalContextSetByHostMiddlewareReachesTheHandler`, `taskLocalContextIsLostWhenTheFrameworkPullsTheBody`, `taskLocalContextSurvivesWhenTheHandlerProducesTheBytes`). The proposal-native runtime is pinned by nothing yet: `Fixtures/Sources/WireMVCTaskLocalExample/main.swift` exercises it when run, and CI builds it without running it.

## Related specifications

- [trie-router](../trie-router/spec.md)
- [server-transport-bridge](../server-transport-bridge/spec.md)
- [route-builder-contract](../route-builder-contract/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [composition-root](../composition-root/spec.md)
- [package-traits](../package-traits/spec.md)
- [middleware](../middleware/spec.md)
- [testing-harness](../testing-harness/spec.md)
