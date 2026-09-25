# Server transport bridge

## Purpose

The opt-in `WireMVCServerTransport` module serves the same proposal-native controllers on any
OpenAPIRuntime `ServerTransport`, which is how a WireMVC graph reaches Hummingbird and Vapor through
swift-openapi-hummingbird and swift-openapi-vapor. It registers each collated route onto the host's
router with one `transport.register` call and adapts the proposal's streaming reader and response
sender to the transport's `HTTPBody`. There is no router in the bridge: the host routes and supplies
the path parameters. The module is compiled only when the `ServerTransport` package trait is enabled.

Rationale: [WireMVCDesign](../../../Documentation/Notes/WireMVCDesign.md), [CatchAllMountingProbe](../../../Documentation/Notes/CatchAllMountingProbe.md), [VaporMacroRouting-Overlap](../../../Documentation/Notes/VaporMacroRouting-Overlap.md).
Documentation: [PackageTraits](../../../Sources/WireMVC/WireMVC.docc/PackageTraits.md), [WhatDiffersByRuntime](../../../Sources/WireMVC/WireMVC.docc/WhatDiffersByRuntime.md).

## Requirements

### Requirement: The module is empty unless the `ServerTransport` trait is enabled
The `WireMVCServerTransport` target's sources SHALL be wrapped in `#if ServerTransport`, and its
`OpenAPIRuntime` dependency SHALL be conditional on the `ServerTransport` trait, so that with the trait
off the target compiles to an empty module and OpenAPIRuntime is not linked.

#### Scenario: the default build
- **WHEN** CI runs `swift build` and `swift test` with no traits enabled
- **THEN** both succeed and the `WireMVCServerTransport` target contributes no symbols

#### Scenario: the trait build
- **WHEN** CI runs `swift test --traits ServerTransport`
- **THEN** the log contains `Suite "WireMVCServerTransport" passed`, and the step fails if it does not

Pinned by: `.github/workflows/build.yml` (`BuildAndRun`, steps `Build`, `Test` and `Test ServerTransport adapter (trait)`), which show only that both builds succeed and that the trait build runs the suite. That the trait-off target contributes no symbols and does not link OpenAPIRuntime holds by construction (`#if ServerTransport` around the target's only source file, and the trait-gated `OpenAPIRuntime` product dependency in `Package.swift`) and is pinned by nothing yet.

### Requirement: `WireMVCServerTransport.apply` registers the graph and returns its services
`WireMVCServerTransport.apply(_ graph: some WireMVCComposable, to transport: some ServerTransport)
throws -> [any Service]` SHALL run `WireMVC.apply` with the default coding onto the bridge's own route
builder, then register every collected route onto `transport`, and SHALL return `graph.services`. The
result SHALL be `@discardableResult`.

#### Scenario: a hand-written graph served over a transport
- **WHEN** a test applies a `WireMVCComposable` with `GET /hello`, `POST /echo` and `GET /users/{id}` routes to an in-process `ServerTransport`
- **THEN** `GET /hello` answers `200` with `Well, hello!`, `POST /echo` with body `round-trip` answers `200` with `round-trip`, and `GET /users/42` answers `200` with `user 42`

#### Scenario: the Hummingbird example
- **WHEN** `HummingbirdExample` builds its application with `let services = try WireMVCServerTransport.apply(graph, to: router)`
- **THEN** its runtime suite drives the collated controllers on Hummingbird

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`servesProposalRoutesOnServerTransport`), [HummingbirdExample TodoVerificationTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/HummingbirdExample/Tests/HummingbirdExampleTests/TodoVerificationTests.swift).

### Requirement: One `transport.register` per route
The bridge SHALL call `transport.register(_:method:path:)` once per collected route, in registration
order, until it reaches a route it refuses (see "A catch-all template is refused at registration"),
passing the route's method and its template string unchanged, and SHALL take each request's path
parameters from `ServerRequestMetadata.pathParameters`. Routes after a refused one SHALL NOT be
registered.

#### Scenario: a parameter supplied by the transport
- **WHEN** the transport matches `GET /users/42` against the registered `/users/{id}` and passes `pathParameters["id"] == "42"`
- **THEN** the handler reads `42` and answers `user 42`

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`servesProposalRoutesOnServerTransport`).

### Requirement: `WireMVCServerTransport.mountIntrospection` registers the wiring endpoint
`WireMVCServerTransport.mountIntrospection(for graph: some Introspectable, on transport: some
ServerTransport, at path: String = "/wiring") throws` SHALL run `WireMVC.mountIntrospection` onto a
fresh bridge builder and register the resulting `GET` route onto `transport`.

#### Scenario: the Hummingbird example
- **WHEN** `HummingbirdExample` calls `try WireMVCServerTransport.mountIntrospection(for: graph, on: router)` and its suite requests `GET /wiring`
- **THEN** the response is `200` and decodes as a `WiringModel`

Pinned by: [HummingbirdExample TodoVerificationTests](https://github.com/swift-wire/wire-mvc-examples/blob/main/HummingbirdExample/Tests/HummingbirdExampleTests/TodoVerificationTests.swift).

### Requirement: A catch-all template is refused at registration
When a collected route's template contains a `{name*}` segment, the bridge SHALL throw
`WireMVCServerTransportError.catchAllNotBridgeable(path:segment:)` instead of registering it. Routes
collected before it SHALL already have been registered. The error's `description` SHALL read `route
'<path>' uses the catch-all '<segment>', which the ServerTransport bridge cannot register: the path
crosses the adapter as an OpenAPI '{name}' template, and Hummingbird and Vapor each interpret a
wildcard in it differently. The native (proposal server) router serves catch-all routes; on this
runtime, serve that shape with the host framework's own router or middleware.` Whether the gap closes
at a small seam is https://github.com/swift-wire/wire-mvc/issues/183.

#### Scenario: a catch-all controller on a bridged runtime
- **WHEN** a graph containing `@Get("/{path*}")` under `@Controller("/files")` is passed to `WireMVCServerTransport.apply`
- **THEN** it throws `catchAllNotBridgeable(path: "/files/{path*}", segment: "{path*}")`

Pinned by: nothing yet.

### Requirement: The request body is read one chunk per read
The bridge's reader SHALL pull exactly one chunk from the transport's request `HTTPBody` per `read`,
SHALL signal the end with an empty buffer and a final element of `.some(nil)` on the read after the
last chunk, and SHALL impose no size limit of its own.

#### Scenario: a handler that stops early
- **WHEN** a route reads three chunks from an unbounded request body and answers
- **THEN** the response is `read 3` and the body source produced exactly three chunks

#### Scenario: a body past one megabyte
- **WHEN** a route counts a 2 MiB request body sent as 32 chunks of 64 KiB
- **THEN** the response is `200` with the full byte count

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`streamsRequestBodyOnDemand`, `acceptsRequestBodyLargerThanTheOldCollectCeiling`).

### Requirement: A one-shot response returns a known-length body
When a handler calls `sendAndFinish`, the bridge SHALL return the head with the whole body as a
`Data`-backed `HTTPBody`, or with no body when the buffer is empty.

#### Scenario: a typed route
- **WHEN** `GET /hello` answers through `sendAndFinish`
- **THEN** the transport receives `200` and the body `Well, hello!`

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`servesProposalRoutesOnServerTransport`). That the body's length is known is pinned by nothing yet.

### Requirement: A streamed response travels through a rendezvous channel
When a handler calls `send(_:)`, the bridge SHALL return the head at once with an `HTTPBody` of unknown
length and single iteration, fed by a rendezvous `AsyncChannel`, so that each written chunk suspends
the handler until the transport pulls it.

#### Scenario: server-sent events
- **WHEN** a raw handler writes `data: tick <n>\n\n` events to an unbounded `text/event-stream` response and the test consumes five
- **THEN** the five events arrive in order and the handler is never more than one event ahead

#### Scenario: request and response at once
- **WHEN** a route echoes a three-chunk request body as it reads it
- **THEN** the first response chunk arrives before the request source has produced all three chunks

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`streamsRawResponseWithBackpressure`, `streamsRequestAndResponseBodiesConcurrently`). That the body's length is unknown and its iteration single is pinned by nothing yet.

### Requirement: The handler runs in an unstructured task that inherits task-locals
The bridge SHALL run each route handler in an unstructured `Task`, so task-local values set around the
transport's call reach the handler, including while it produces a streamed body after the register
closure has returned.

#### Scenario: a one-shot response
- **WHEN** the transport call runs inside `TracingProbe.$traceID.withValue("abc-123")` and the handler returns the task-local
- **THEN** the body is `abc-123`

#### Scenario: a streamed response
- **WHEN** the transport call runs inside the same `withValue` scope and a route (`GET /trace-stream`) sends its head, then streams three lines that each read the task-local after the head has been returned
- **THEN** the body is `1:abc-123\n2:abc-123\n3:abc-123\n`

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`taskLocalContextReachesTheHandlerThroughTheBridge`, `taskLocalContextSurvivesIntoAStreamedBody`).

### Requirement: Cancelling the request cancels the handler
The bridge SHALL cancel the handler task when the request task is cancelled before a response head has
been delivered, and for a streamed response SHALL cancel it when the returned body is released. A
request cancelled this way is reported by the host as a server error:
https://github.com/swift-wire/wire-mvc/issues/174.

#### Scenario: cancellation before the head
- **WHEN** a handler is suspended in `GET /slow` and the task sending the request is cancelled
- **THEN** the handler observes cancellation

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`cancellingTheRequestCancelsTheHandlerBeforeAnyResponse`). Cancellation on release of a streamed body is pinned by nothing yet.

### Requirement: A handler error before the head is rethrown to the transport
When a handler throws before sending a response head, the bridge SHALL rethrow that error from the
register closure, leaving the host to map it. When it throws after a streamed head, the bridge SHALL
finish the body where it stands.

#### Scenario: a throwing route
- **WHEN** a route handler throws before calling `sendAndFinish` or `send`
- **THEN** the closure registered with the transport throws the same error

Pinned by: nothing yet.

### Requirement: A handler that never responds is a 500
When a handler returns without sending a response head, the bridge SHALL return
`HTTPResponse(status: .internalServerError)` with no body.

#### Scenario: a silent route
- **WHEN** a route handler returns normally without calling `sendAndFinish` or `send`
- **THEN** the transport receives `500` with no body

Pinned by: nothing yet.

### Requirement: The bridge carries response-header contributions
The bridge SHALL give each handler a `WireMVCContext<BridgeRequestContext>` holding a fresh
`ResponseHeaderRegistry`, so the middleware box's contribution rules (see
[middleware](../middleware/spec.md)) hold on this runtime as they do natively. Dropping a contribution
made after a gate has responded is done by `RequestResponseMiddlewareBox.contributing` in the `WireMVC`
module, not by the bridge; the gate scenario shows that rule survives the bridge.

#### Scenario: a stamped route
- **WHEN** middleware on `GET /stamped` contributes `x-stamp: adapter`
- **THEN** the response carries `x-stamp: adapter`

#### Scenario: a gate answers first
- **WHEN** a gate on `GET /gated` contributes `x-gate: before`, responds `401`, and an observer further in contributes `x-observer`
- **THEN** the response is `401` with `x-gate: before` and no `x-observer`

Pinned by: `Tests/WireMVCServerTransportTests/AdapterTests.swift` (`contributedHeaderFieldsReachTheResponseThroughTheBridge`, `aContributionAfterAGateRespondsDoesNotReachTheResponse`).

## Related specifications

- [route-builder-contract](../route-builder-contract/spec.md)
- [package-traits](../package-traits/spec.md)
- [trie-router](../trie-router/spec.md)
- [runtime-differences](../runtime-differences/spec.md)
- [controllers-and-routes](../controllers-and-routes/spec.md)
- [composition-root](../composition-root/spec.md)
- [responses-and-modes](../responses-and-modes/spec.md)
- [middleware](../middleware/spec.md)
- [testing-harness](../testing-harness/spec.md)
