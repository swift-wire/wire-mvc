# WireMVC testing architecture — target design

> **Status:** design record, for review before building. Supersedes the current single-mode `.wiremvc()`
> harness (`WireMVCTesting.serveForSuite` over a hard-wired `NIOHTTPServer`). Motivated by a concrete coupling
> bug: a framework-agnostic package (`Controllers` in wire-mvc-examples) transitively resolves
> `swift-http-server` purely because it depends on the `WireMVC` product, since the `wire-mvc` package declares
> `swift-http-server` unconditionally for `WireMVCTesting`'s harness.

## The problem

The current harness stands up a **real HTTP server** for every test suite and drives it over `URLSession`:

- `WireMVCTesting` `public import`s `NIOHTTPServer` (to conform it to `WireMVCTestServer` and read the bound
  port), so the `wire-mvc` package declares `swift-http-server` — and **every consumer of the `WireMVC`
  product transitively resolves it**, framework-agnostic ones included.
- `serveForSuite<Server: HTTPServer & WireMVCTestServer, …>` requires the bound-port capability
  **unconditionally**, even for a suite that would be happy with a fixed, known port and needs no read-back.
- "Use an ephemeral port" is expressed as an app-level `@Replaces` of `ServerConfig(port: 0)` — a *testing
  instruction* smuggled through *application configuration*, which then requires a *separate* server-side
  mechanism (`WireMVCTestServer.wireMVCBoundPort`) to read the OS-assigned port back.
- Every route/controller test pays for a full server + socket + ephemeral-port dance, even though the thing
  under test (routing, middleware, controller logic) needs no transport at all. The mocked routing suite is
  the clearest example: it explicitly tests "routing/controller logic in isolation, no backend," yet stands up
  a real NIO server to do it.

The deeper issue: **the test path reuses the app's production server construction.** That works for a trivial
`ServerConfig`, but production and test server configuration diverge (TLS, bind interface, timeouts,
connection limits, HTTP/2, graceful shutdown) — so sharing the factory means "un-configuring" it for tests.

## Prior art

No mainstream framework reuses the app's production server factory for tests. They split into two modes, and
the test layer owns the transport in both:

- **In-process / no server (the default).** Requests go straight through the app's handler/middleware chain;
  no socket, no port. Hummingbird `app.test(.router)`, Vapor `app.test(.inMemory)`, ASP.NET Core `TestServer`
  (an in-memory server that reuses config/DI but swaps the transport), Spring `MockMvc`.
- **Real server, framework-owned (for E2E).** A test-configured server on an (ephemeral) port, with a
  read-back. Spring `@SpringBootTest(webEnvironment = RANDOM_PORT)` + `@LocalServerPort` (exactly the
  ephemeral-bind + read-back pattern), Hummingbird `.live`, Vapor `.running(port:)`, Express `supertest`.

The through-line: **the app owns routes + config; the test framework owns the server/transport.** In-process
is the default; the live server is the exception, kept for genuine end-to-end confidence.

WireMVC is well-positioned for the in-process default because its generated route witnesses finalize into a
server-agnostic `HTTPServerRequestHandler`, and its `ServiceLifecycle` services are collated as graph data
(`WireMVCComposable.services`) run *independently* of the server (`WireMVC.runServices` is a sibling task to
`server.serve`). That decoupling means an in-process mode can run the background services that Hummingbird's
`.router` cannot.

## The design — three transport modes

`@Suite(.wiremvc(<mode>, services: <policy>))`. The mode is the transport; `services` is an orthogonal axis.

### Mode 1 — `.inProcess` (default)

Drives the finalized handler directly. No socket, no port, no concrete server. Covers all route / controller /
middleware / error-mapping / keyed-harness logic — i.e. the vast majority of tests, including the entire
mocked routing suite.

- Requires: the abstract `HTTPServerRequestHandler` only.
- Lives in: **core `WireMVCTesting`** — no concrete-server dependency.
- Naming: `.inProcess` (not `.mockServer` — nothing is mocked, the real handler runs; and `.mockServer` would
  collide with the smockable mocks used in these suites).

### Mode 3 — `.server(_:)` (generic escape hatch)

The caller supplies any server. This is where an app on a non-NIO server (Hummingbird, a custom transport)
plugs in, and where a genuine E2E test that *wants* the app's real server lives.

- Ephemeral: `.server(s)` where `s: HTTPServer & WireMVCTestServer` — reads the bound port back.
- Fixed: `.server(s, on: port)` where `s: HTTPServer` — the client already knows the port, so the
  `WireMVCTestServer` read-back seam is **not** in the signature.
- Lives in: **core `WireMVCTesting`** — references only the abstract `HTTPServer` (+ `WireMVCTestServer` for
  the ephemeral overload), no concrete server.

### Mode 2 — `.swiftHttpServer` / `.swiftHttpServer(on: port)` (NIO convenience)

Batteries-included live mode for the proposal-native / `NIOHTTPServer` stack. It is **mode 3 with
`NIOHTTPServer` pre-filled** — `.swiftHttpServer` *is* `.server(NIOHTTPServer(…))` over a plaintext HTTP/1.1
loopback configuration the harness owns — not a separate mechanism.

- Ephemeral by default (`.swiftHttpServer`); fixed with `.swiftHttpServer(on: port)`.
- Lives in: an opt-in **`WireMVCTestingNIOHTTPServer`** product that ships `import NIOHTTPServer`, the
  `extension NIOHTTPServer: WireMVCTestServer` conformance, and the `.swiftHttpServer` factory.
- "Availability-gated" = you get `.swiftHttpServer` only by depending on that product, which is the only place
  `swift-http-server` enters the graph.

### The two orthogonal axes

- **Ephemeral vs fixed port** (live modes only). Ephemeral requires the `WireMVCTestServer` read-back; fixed
  does not. This makes "no read-back capability unless you're binding ephemeral" structural, and retires the
  `@Replaces(ServerConfig(port: 0))` instruction-as-config: the port choice is a WireMVCTesting API decision,
  not an app-config replacement.
- **Services `.run` vs `.skip`** (all modes). Whether the graph's collated `ServiceLifecycle` services start.
  Defaults per mode: `.inProcess` → `.skip` (isolation), live → `.run` (E2E). Not a mode — it cross-cuts them.

## Selecting a variant — multiple testing keys via source-location identity

`.wiremvc(_ key: TestingKey, …)` names the variant app graph to serve. Each `TestingKey` produces one variant
graph (its `@BindType` substitutions), so a target with several keys has several variants — but the harness is
**single-key today** (`discoverTestingKey` takes "the first `TestingKey` found"). The blocker is identity: a
`TestingKey()` **value** is opaque at runtime, so `.wiremvc(someKey)` can't tell *which* generated variant that
value corresponds to. Naming the variant after the key's source *reference* (`Binds.mock`) doesn't help — the
reference is a compile-time name the runtime value doesn't carry.

**Source location is the bridge** — the one stable, unique identity a plain value *can* capture at runtime.
`TestingKey.init` captures its declaration site via default arguments, so users still write `TestingKey()`:

```swift
public struct TestingKey: Sendable {
    package let fileID: String       // package-private: exists only for the generated dispatch, not user code
    package let line: Int
    public init(fileID: String = #fileID, line: Int = #line) { self.fileID = fileID; self.line = line }
}
```

The `fileID`/`line` are **package-private** (`package`, not `public`) — they serve the generated `.wiremvc`
dispatch and the framework's own code, and are not part of the user-facing surface. WireGen already sees every
`@BindType(…) static let … = TestingKey()` at a known location while building each variant, so it generates
`.wiremvc(_ key:)` as a switch over `(fileID, line)` rather than a single-key factory:

```swift
static func wiremvc(_ key: TestingKey, _ mode: …) -> WireMVCSuiteTrait {
    switch (key.fileID, key.line) {
    case ("…MockedTests/MockableProtocols.swift", 22): /* serve variant A on `mode` */
    case (…, …):                                       /* serve variant B on `mode` */
    default: fatalError("no variant graph generated for TestingKey at \(key.fileID):\(key.line)")
    }
}
```

This switches on the **key** (which variant) orthogonally to the **mode** (which transport) — the two arguments
of `.wiremvc`.

**The precision requirement:** WireGen must reproduce exactly the `#fileID`/`#line` the compiler stamps on the
`TestingKey()` **init call** — `#fileID` is `Module/Basename.swift`, and `#line` is the line of the
`TestingKey()` expression (not necessarily the `static let`, if split across lines). This is a codegen detail,
not a runtime fragility: the generated `switch` and the compiled key value are produced from the same source in
the same build (the plugin regenerates every build), so they cannot drift relative to each other.

**Validation the identity enables** (today a second key is silently ignored):
- a `.wiremvc(key)` whose location matches no generated variant is a clear `fatalError`/diagnostic, not a
  silently-wrong graph;
- WireGen can reject two keys sharing a source location.

Rejected alternatives: per-key generated factory names (`.wiremvcBindsMock()`) drop the uniform `.wiremvc(key)`
surface; an explicit user-supplied id (`TestingKey("mock")`) is boilerplate and collision-prone. Source
location is the only option that is both auto-captured and keeps the API uniform.

## Module structure (the coupling fix)

| Product | Provides | Concrete-server dependency |
|---|---|---|
| `WireMVCTesting` (core) | `.inProcess`, `.server(_:)`, `WireMVCTestServer`, the in-process transport, `WireMVCSuiteTrait`, `TestClient`/`InProcessClient` | **none** — abstract `HTTPServer` only |
| `WireMVCTestingNIOHTTPServer` (opt-in) | `.swiftHttpServer[(on:)]`, `extension NIOHTTPServer: WireMVCTestServer` | `swift-http-server` |

Result: a consumer of the `WireMVC` (or core `WireMVCTesting`) product no longer *links* `swift-http-server`.
`Controllers` — and any framework-agnostic package — compiles against a NIO-free target graph. Only a test
target that opts into the NIO convenience links it.

**Package *resolution* needs one more step.** SwiftPM pins every manifest-transitive package dependency
regardless of target reachability; the only thing it prunes is a product dependency gated behind an
off-by-default **trait** (that is why `Controllers` resolves no `swift-openapi-runtime` — `WireMVCServerTransport`'s
`OpenAPIRuntime` is `.when(traits: ["ServerTransport"])` — while it still resolves `swift-http-server`). So the
target split above is necessary but not sufficient to close the reported bug: `swift-http-server` stays in
`Controllers`' `Package.resolved` as long as *any* wire-mvc target names it unconditionally
(`WireMVCTestingNIOHTTPServer` plus the in-package `WireMVCExample` / `WireMVCBootstrapExample*` fixtures).
**Decided: a `NIOHTTPServer` trait, in Phase 5.** Off by default and gating every `swift-http-server` product
dependency, mirroring the existing `ServerTransport` trait — the conformance returns to core `WireMVCTesting`
under `#if NIOHTTPServer` and `WireMVCTestingNIOHTTPServer` is folded away. That collapses three problems into
one mechanism: `Controllers` stops *resolving* swift-http-server, a test consumer no longer imports a separate
transport product for a retroactive conformance, and an in-process-only suite stops carrying a NIO dependency
it never uses.

It could not be pulled forward into Phase 1, because it is inseparable from relocating the fixtures. `#if` can
empty a library target (that is how `WireMVCServerTransport` handles `ServerTransport`), but `WireMVCExample`
and `WireMVCBootstrapExample` are executables whose generated `@main` cannot compile away, and three test
targets depend on them — so an off-by-default trait would gut the package's own suite until those fixtures
move out. The separate-product split shipped in Phase 1 is the working intermediate: it already gives a
`WireMVC`/`WireMVCTesting` consumer a NIO-free *target* graph.

## The in-process transport

Everything hangs off the finalized handler's one entry point:

```swift
func handle(
    request: HTTPRequest,
    requestContext: consuming RequestContext,
    reader: consuming sending Reader,            // AsyncReader<UInt8, HTTPFields?> — the request body
    responseSender: consuming sending ResponseSender
) async throws
```

The in-process transport manufactures those four arguments, calls `handle`, and reads back what the sender
captured. It is the analogue of Hummingbird's `.router` transport / ASP.NET's `TestServer` — written once.

- **`ResponseSink`** — a `Sendable` reference (`Mutex`-backed) that accumulates `(head, body, trailers)`. It
  outlives the sender that is `consuming`-threaded through the chain; the driver reads it after `handle`
  returns.
- **`InProcessResponseSender: HTTPResponseSender`** — `send(_:)` records the `HTTPResponse` head and returns
  an **`InProcessWriter: CallerAsyncWriter`** whose `write`/`finish` append body + trailers to the shared
  sink.
- **`InProcessReader: AsyncReader`** — buffer-backed (`ReadElement == UInt8`, `FinalElement == HTTPFields?`);
  delivers the in-memory request body fused with the end-of-stream signal. No I/O.
- **`InProcessRequestContext: HTTPServerCapability.RequestContext`** — the minimal loopback context routes
  read.
- **`InProcessServer: HTTPServer`** — see below.

**Built, and three corrections to the sketch above:**

1. **No `InProcessRouteBuilder`; an `InProcessServer` instead.** A substitute route builder would mean the
   in-process suite tests a *different router* than the app runs — the opposite of the goal. But
   `@WireMVCBootstrap`'s `createRouteBuilder<Server: HTTPServer>(for:)` is already generic over the server,
   so handing it an in-memory `HTTPServer` yields the *app's own* builder over the in-memory associated
   types. The whole codegen delta collapses to one line — `let server = InProcessServer()` in place of
   `bootstrap.createServer()` — and everything downstream (`apply`, the introspection mount, the `@NotFound`
   registration, `finalize()`, `wrapGlobalMiddleware`) is byte-identical between the two build paths. So the
   in-process suite exercises the app's real router, middleware fold, and error tiers. `InProcessServer.serve`
   is never called; it throws if it is.
2. **No separate `InProcessClient`.** `TestClient` gained a private transport enum (`.loopback` /
   `.inProcess`) behind its unchanged verb surface, so a test body reads identically in either mode and
   switching a suite between them is a one-word change. Both renderers stamp the `X-WireMVC-Test-Binds`
   correlation header, so the keyed harness works in-process too.
3. **The `~Copyable` wrinkle did not materialise.** `AsyncReader`/`HTTPResponseSender`/`CallerAsyncWriter`
   declare `~Copyable`/`~Escapable` to *relax* the constraint on conformers, not to require it — the same
   latitude `WireMVCServerTransport`'s bridge types already take. The in-process types are ordinary copyable
   `Sendable` structs whose only storage is the sink, so `consuming sending` costs nothing to satisfy.

The driver mirrors `serveForSuite`'s **services half** exactly; the only structural change is "call `handle`
per request" instead of "serve on a socket":

```swift
try await withThrowingTaskGroup(of: Void.self) { group in
    if services == .run { group.addTask { try await WireMVC.runServices(collatedServices) } }
    try await InProcessClient.$current.withValue(InProcessClient(handler: handler)) {
        try await runTests()
    }
    group.cancelAll()
}
```

Per request, `InProcessClient` builds the four args, runs one `handle`, and returns the captured response — no
round-trip, no port.

**Honest wrinkles:**
- The `~Copyable` / `consuming sending` reader and sender mean the captured response must land in a `Sendable`
  reference (`ResponseSink`) that survives the consumed sender — the fiddliest part to satisfy the compiler.
- `sending` requires the reader/sender be safe across the isolation boundary; buffer-backed value types are.

## Codegen change

The `.wiremvc()` factory today inlines "the same build-and-wrap the `@main` does," which builds the router via
the app's `createRouteBuilder(for:)` (its real server's types). The in-process mode needs the handler built
over the **in-process** associated types instead — which it gets by passing `InProcessServer()` to that same
generic factory method.

- The generated `registerWireRoutes(on:)` is already generic over `Builder: HTTPServerRouteBuilder`, so the
  route contributors are reused unchanged — only the server the builder is created for differs.
- `WireMVCRouteGen` emits the factory as a `switch` over the mode, inlining one build per branch. The two
  builds cannot share a local: each `finalize()` + `wrapGlobalMiddleware` produces a *different* opaque
  `~Copyable` handler type, so each branch must build and consume its handler in place.
- **The generated factory names no concrete server**, so a suite's transport dependency follows the mode it
  actually writes: an `.inProcess`-only target depends on neither `NIOHTTPServer` nor
  `WireMVCTestingNIOHTTPServer`.
- **Phase 2 shipped a `.appServer` mode reusing the app's `createServer()`; Phase 3 removed it.** The
  factory is now generic over the server its mode carries, with one build path and no concrete server named.

## What a genuine live server still buys (why we keep it)

In-process cannot observe, and a live E2E test can:
- **Streaming / backpressure** — that `@RawRoute` streaming (multipart export, SSE) actually streams
  incrementally with real framing/backpressure, not buffered whole. In-process proves the route *logic*, not
  the streaming *behavior*.
- **The app's real server-wiring** — in-process never calls `createServer()`, so a bug in the real server
  construction / server-boundary behavior only shows up live.
- **Real connection capabilities** — TLS/ALPN, client cert, peer address a real `RequestContext` exposes.
- **Wire-protocol / real-client behavior** — keep-alive, HTTP/2, compression, redirects.

Several of these (wire codec, connection concurrency) are `swift-http-server`'s responsibility, not WireMVC's,
so for a WireMVC *app* the live mode's real value narrows to **integration-smoke + streaming**: a handful of
tests, not the suite. This is exactly why the live path may legitimately reuse `createServer()` — verifying the
real wiring is the point — and why the ephemeral read-back seam rightfully lives there and nowhere else.

## Migration

- Existing `@Suite(.wiremvc())` suites map to `.wiremvc(.appServer)` (behaviour-preserving) initially, then to
  `.wiremvc(.inProcess)` where they only exercise route/controller logic (most of them, including the mocked
  routing suite) or `.wiremvc(.swiftHttpServer)` where they want a real socket.
- The `@Provides @Replaces func testServerConfig() -> ServerConfig { … port: 0 }` in test targets is retired in
  favour of the mode/port on the suite trait.
- `WireMVCTesting`'s `public import NIOHTTPServer` + the `NIOHTTPServer` conformance move to
  `WireMVCTestingNIOHTTPServer`; the `swift-http-server` package dependency becomes needed only by that product
  and the in-package example/fixture targets (which can be trait-gated or moved out in a follow-up).

## Implementation plan

Phased so each phase ends green (builds + suites pass) and delivers something on its own. Grounding facts: the
live path already builds via the app's `bootstrap.createServer()` and calls `WireMVCTesting.serveForSuite`, so
the NIOHTTPServer coupling is *only* the `extension NIOHTTPServer: WireMVCTestServer` conformance; and
`TestingKey` is defined in **swift-wire** (`Wire/TestingKey.swift`), so its source-location change lands there.

### Phase 1 — Decouple core (the reported bug). wire-mvc + examples. Risk: low.
Behaviour-preserving conformance relocation.
- New product **`WireMVCTestingNIOHTTPServer`**: `import NIOHTTPServer`, `extension NIOHTTPServer:
  WireMVCTestServer`, and (later) the `.swiftHttpServer` factory.
- Core `WireMVCTesting` drops `import NIOHTTPServer`; `serveForSuite` is already generic, so nothing else moves.
- `swift-http-server` becomes a dependency of only the new product (+ the in-package fixture targets), not core.
- Example/consumer **test targets** add `WireMVCTestingNIOHTTPServer` so their `createServer()`'s `NIOHTTPServer`
  keeps conforming to `WireMVCTestServer`, and **`import` it in one of their own sources**. A target dependency
  alone is not enough — the module has to be imported for its retroactive conformance to be found — but
  conformance lookup is module-wide rather than file-scoped, so one import anywhere in the test module covers
  the generated file too. This is ordinary Swift for a retroactive conformance and needs nothing from the
  plugin: no discovery, no marker file.
- **Gate:** `Controllers` (and any `WireMVC`-only consumer) no longer *links* `swift-http-server` — its target
  graph is NIO-free; existing `.wiremvc()` suites still pass unchanged. Dropping it from `Package.resolved`
  needs the trait work — see "Module structure" above and Phase 5.

### Phase 2 — In-process transport + `.inProcess` mode. wire-mvc (core + codegen). Risk: high.
The one genuinely new, intricate piece.
- Core `WireMVCTesting`: `ResponseSink`, `InProcessResponseSender`/`InProcessWriter`, `InProcessReader`,
  `InProcessRequestContext`, `InProcessServer`, `TestClient`'s in-process transport, and
  `driveInProcess` (the services-half of `serveForSuite` + per-request `handle`).
- Introduce the mode enum: `.wiremvc(.inProcess)` / `.wiremvc(.appServer)` (the existing live path, under an
  honest name — see the codegen note above; the framework-owned `.swiftHttpServer` lands in Phase 3).
- Codegen (`WireMVCRouteGen`): a `switch` over the mode inlining one build per branch, the in-process one
  building over `InProcessServer()` (the generic `registerWireRoutes(on:)` and the whole downstream build are
  reused verbatim) and handing the handler to `driveInProcess`.
- **Gate:** `WireMVCBootstrapExampleReplaceTests` runs on `.inProcess` — no socket, no
  `@Replaces ServerConfig(port: 0)`, no `WireMVCTestingNIOHTTPServer` dependency — with parity assertions for
  the global error tier, the `@NotFound` raw fallback, and the guarded introspection mount. Roughly 8× faster
  per test than the sibling live suite. `WireMVCTestingTests` adds direct transport coverage (request body,
  incremental writes, never-responded handler, correlation header) that the GET-only fixture app can't reach.

### Phase 3 — `.server(_:)`, ephemeral/fixed, services knob. wire-mvc + examples. Risk: medium.
Complete the mode surface + retire the config hack.
**This is where the live mode becomes framework-owned.** Phase 2's `.appServer` reused the app's
`createServer()`; the standard live mode must not. Done — `createServer()` is now called by the generated
`@main` and nowhere else.

- `WireMVCTestMode<Server>` carries the server, so the generated factory is generic over it with a **single**
  build path. `.inProcess` (core), `.server(_:)` / `.server(_:on:)` (core), `.swiftHttpServer` /
  `.swiftHttpServer(on:)` (the NIO product, `.server(_:)` with a plaintext HTTP/1.1 loopback `NIOHTTPServer`
  pre-filled). `.appServer` is **gone**.
- The generated code names no concrete server and no `WireMVCTestServer`: whatever bound a transport needs
  is discharged where the test writes the mode. The Phase-2 "every target needs the conformance in scope"
  problem went with it — `WireMVCBootstrapExampleReplaceTests` and the examples' mocked routing suite now
  depend on **no** concrete server at all.
- `services: WireMVCTestServices?` on the factory, defaulting to the mode's own policy (`.inProcess` skips,
  live runs).
- `@Provides @Replaces func testServerConfig() { port: 0 }` retired everywhere: the harness owns the port.

**Two things the plan did not anticipate.**

1. **No `WireMVCTestDriver` protocol.** The obvious way to let one driver serve either transport is a
   `WireMVCTestDriver: HTTPServer` refinement with a generic `driveSuite<Handler>` requirement. That
   refinement type-checks only if it restates every `~Copyable` suppression, and with them restated the
   6.4.x-snapshot-2026-07-06 toolchain crashes (`getTypeWitness`, ProtocolConformanceRef.cpp:195). It is
   also unnecessary: ``InProcessServer/serve(handler:)`` publishes an in-memory dispatch instead of binding
   a socket, so in-process *is* a genuine `HTTPServer.serve` and the existing driver covers it unchanged.
   What the mode carries beyond the server is a plain `client` closure — legal to store precisely because
   it does not mention the handler type.
   (Restating suppressions is required on any generic extension of `WireMVCTestMode` too, or `Copyable` is
   re-imposed on the associated types and no proposal server satisfies the factories.)
2. **The mode must build its server lazily.** A mode is constructed when the `@Suite(.wiremvc(…))`
   *attribute* is evaluated — for every suite in the bundle, including ones the run filters out. An eagerly
   constructed `NIOHTTPServer` that is never served traps on the unfulfilled listening promise its `init`
   creates, so `swift test --filter` crashed every bundle holding a live suite. `.server(_:)` therefore
   takes its server as an `@autoclosure`: the call site still reads `.server(NIOHTTPServer(…))`, but nothing
   is built until the trait enters the suite.

- **Deviation from the plan: there is no default mode.** The plan called `.inProcess` the default, but a
  no-argument `.wiremvc()` would silently re-point existing suites at a different transport during exactly
  the migration this design is about. Every suite states its transport; a default can be added later.
- **Gate:** met. A fixed-port suite compiles with no `WireMVCTestServer` in scope; the ephemeral one still
  reads back; no suite calls `createServer()`; `swift test` and `swift test --filter` are both green.

### Phase 4 — Multi-key via source-location identity. swift-wire → wire-mvc. Risk: medium.
- swift-wire: `TestingKey` gains `package let fileID`/`line` captured via `#fileID`/`#line` init defaults
  (users still write `TestingKey()`). Merge first.
- wire-mvc: WireGen records each key's `TestingKey()` **init-call** location (matching the compiler's
  `#fileID`/`#line` exactly) and emits `.wiremvc(_ key:, _ mode:)` as a `switch (key.fileID, key.line)` over the
  variants, with a `default` diagnostic and a duplicate-location check.
- **Gate:** two `TestingKey`s in one target each serve their own variant; an unmatched key errors clearly.

### Phase 5 — Migration + package-graph cleanup. wire-mvc + examples. Risk: low–medium.
- Migrate wire-mvc's in-package `WireMVCBootstrapExample*` suites and the examples-repo suites to the mode API
  (`.inProcess` where they only exercise route logic — most; `.swiftHttpServer` for the streaming/E2E ones,
  which by then is a framework-owned server rather than the app's `createServer()`).
- Concrete worked example — `SwiftHttpServerExample` becomes a two-mode reference:
  - the **mocked routing suite** (`SwiftHttpServerExampleMockedTests`, smockable, no backend) →
    `.wiremvc(MockedRoutingBinds.mocks, .inProcess)` — socket-free, and it drops the `NIOHTTPServer` /
    `WireMVCTestingNIOHTTPServer` dependency entirely (it tests route/controller logic, not transport).
  - the **real-backend suite** (`SwiftHttpServerExampleTests`, Docker CouchDB) → `.wiremvc(.swiftHttpServer)` —
    genuine E2E over real HTTP, the one place streaming behaviour and the real server-wiring are exercised.
  This division is deliberate: the in-process suite loses nothing it tests, and streaming/real-stack coverage
  lives in the E2E suite that already stands up real infrastructure.
- **The `NIOHTTPServer` trait.** Relocate the in-package NIO fixture executables (`WireMVCExample`,
  `WireMVCBootstrapExample` + its three test targets) out of the package, then add an off-by-default
  `NIOHTTPServer` trait gating every `swift-http-server` product dependency. The
  `NIOHTTPServer: WireMVCTestServer` conformance moves back into core `WireMVCTesting` under
  `#if NIOHTTPServer`, and `WireMVCTestingNIOHTTPServer` is deleted — consumers drop that product dependency
  and its `import`, and enable the trait on their wire-mvc dependency instead. This is the step that actually
  drops `swift-http-server` from a `WireMVC`-only consumer's `Package.resolved`; Phase 1 only removed it from
  the *target* graph.
- **Gate:** `Controllers` resolves no `swift-http-server`; an in-process-only suite declares no NIO
  dependency; all suites green.

**Cross-repo ordering:** Phase 4's swift-wire `TestingKey` change merges before its wire-mvc half (the usual
`swift package update swift-wire` dance). Phases 1–3 are wire-mvc-local; Phase 5 spans both repos + examples.

## Open questions

- **In-package fixtures.** `WireMVCBootstrapExample*` still pull `swift-http-server`. Fully cleaning the
  package graph means trait-gating or relocating those fixtures — separable from this change.
- **`serve(on:)` upstream.** A truly cohesive design would put the bind endpoint on `HTTPServer.serve` so the
  port stops being app config entirely; that's a swift-http-api-proposal change, tracked separately.
- **Services default for `.inProcess`.** `.skip` by default is the isolation-friendly choice, but a route that
  depends on a started service (a pool) needs `.run` — confirm the ergonomics of the per-suite override.
