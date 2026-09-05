# WireMVC testing architecture

> **Status:** built. This describes the harness as it stands — three transport modes, the module
> structure that decoupled `WireMVCTesting` from a concrete server, and the codegen that selects a
> variant. The implementation plan it was built from is in git history; what is still open is on the
> tracker: #190 (in-package fixtures), #191 (`serve(on:)` upstream), #192 (service-startup ergonomics),
> and #170 (one testing key per target).

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
- Lives in: `WireMVCTesting`, behind the off-by-default **`NIOHTTPServer` trait** — `#if NIOHTTPServer`
  guards `import NIOHTTPServer`, the `extension NIOHTTPServer: WireMVCTestServer` conformance, and the
  `.swiftHttpServer` factory. (Phase 1 shipped these as a separate `WireMVCTestingNIOHTTPServer` product;
  Phase 5 folded it away — see "Module structure" below.)
- "Availability-gated" = you get `.swiftHttpServer` only by enabling that trait, which is the only thing that
  puts `swift-http-server` into the graph.

### The two orthogonal axes

- **Ephemeral vs fixed port** (live modes only). Ephemeral requires the `WireMVCTestServer` read-back; fixed
  does not. This makes "no read-back capability unless you're binding ephemeral" structural, and retires the
  `@Replaces(ServerConfig(port: 0))` instruction-as-config: the port choice is a WireMVCTesting API decision,
  not an app-config replacement.
- **Services `.run` vs `.skip`** (all modes). Whether the graph's collated `ServiceLifecycle` services start.
  Defaults per mode: `.inProcess` → `.skip` (isolation), live → `.run` (E2E). Not a mode — it cross-cuts them.

### What the live default actually starts

`.server(_:)` and `.server(_:on:)` default to `services: .run`, which starts the graph's **real** app-scoped
`ServiceLifecycle` services against whatever configuration the graph resolves. That is the point of a live
mode — it is the fidelity you are paying the socket for — but it is worth stating plainly, because it is the
one direction the rest of this document's safety machinery does not cover.

Everything else here protects *production from tests*: the `--testing-variants` gate keeps variant graphs out
of shipping binaries, and the keyed dispatch resolves doubles only under a live harness. This axis runs the
other way. A live suite reaches whatever the app's own config points at, and nothing in the harness knows
whether that is a throwaway container or something you care about. A `@Replaces`d config binding, an
environment closure (`.wiremvc(mode, environment:)`), or a container-per-run is the app's responsibility, not
the harness's.

`.inProcess` is the isolation-safe default and defaults to `.skip` for exactly this reason: a route-logic
suite has no business starting the app's services. Reach for a live mode when you specifically want the
transport or the services in the picture, and know what the config resolves to when you do.

## Selecting a variant — one testing key per target

`.wiremvc(_ key: TestingKey, _ mode:)` names the variant app graph to serve. Each `TestingKey` produces one
variant graph (its `@BindType` substitutions), and swift-wire's WireGen already emits **one variant per key**.
wire-mvc, though, emits a single `.wiremvc(_ key:, _ mode:)` factory bound to one variant — so a second key
has nothing to be served by.

**Decided 2026-07-30: keep it at one key per target, and reject a second at build time.** It used to be
silently ignored (`discoverTestingKey` took the first match), which meant a suite passing the second key was
handed the *first* key's mocks — failing as a mysteriously wrong double rather than as a build error. Now
`WireMVCDiagnostic.multipleTestingKeys` names both declarations and points at the workaround (put the second
key in its own test target; test targets are cheap here, and the in-package fixtures already split that way).

Why not just build it: the dispatch half is easy, and the mechanism for it is **merged and tested** in
swift-wire — `TestingKey.init` captures its declaration site via `#fileID`/`#line` defaults and the type is
`Hashable`, so a generated `switch` can match a key value by reconstructing `TestingKey(fileID:line:)`
(`Sources/Wire/TestingKey.swift`, `Tests/WireTests/TestingKeyTests.swift`; the tests pin that `#line` is
stamped at the `TestingKey()` *call*, not the `static let`, when they differ). What stops it is the **doubles
model**, which is per-key and demands every one of a key's doubles on every request — even for a route that
consumes none. Making the fields optional to fix that turns the per-key `withBindValues` overloads ambiguous,
so multi-key and the doubles model are one problem. The preferred direction is per-controller bind values
(`with<Controller>BindValues`, taking exactly what that controller's scope consumes, all required), which
keeps the compile-time guarantee at the granularity testing happens *and* weakens the case for multi-key.
Recorded in full as [swift-wire/swift-wire#336](https://github.com/swift-wire/swift-wire/issues/336), and — together with a typed per-route client derived
from the same controller — in [Notes/ControllerScopedTesting.md](ControllerScopedTesting.md), to
revisit after Phase 5.

## Module structure (the coupling fix)

| Configuration | `WireMVCTesting` provides | Concrete-server dependency |
|---|---|---|
| default | `.inProcess`, `.server(_:)`, `.server(_:on:)`, `WireMVCTestServer`, the in-process transport, `WireMVCSuiteTrait`, `TestClient` | **none** — abstract `HTTPServer` only |
| `NIOHTTPServer` trait on | the above **plus** `.swiftHttpServer[(on:)]` and `extension NIOHTTPServer: WireMVCTestServer` | `swift-http-server` |

The coupling is closed in two independent steps, and both were needed.

**Linking** was fixed by making `WireMVCTesting` name only the abstract `HTTPServer`, so a consumer of
`WireMVC` compiles against a NIO-free target graph.

**Resolution** needed a trait. SwiftPM pins every manifest-transitive package dependency regardless of target
reachability; the only thing it prunes is a product dependency gated behind an off-by-default trait — which is
why `Controllers` never resolved `swift-openapi-runtime` (`WireMVCServerTransport`'s `OpenAPIRuntime` is
`.when(traits: ["ServerTransport"])`) while it *did* keep resolving `swift-http-server`. So `swift-http-server`
stayed in a consumer's `Package.resolved` as long as **any** wire-mvc target named it unconditionally. The
`NIOHTTPServer` trait now gates the one remaining reference, and everything that needed an ungated one — the
two runnable examples and their integration suites — moved to a sibling `Fixtures/` package that enables the
trait on its path dependency.

Two consequences worth noting. The separate `WireMVCTestingNIOHTTPServer` product introduced in Phase 1 is
**gone**: with the conformance back in `WireMVCTesting` under `#if NIOHTTPServer`, a consumer that enables the
trait gets it in a module it already imports, so the retroactive-conformance visibility problem disappears
along with the extra product dependency and the extra `import`. And the fixtures had to move rather than be
`#if`-gated in place: `#if` can empty a *library* target (that is how `WireMVCServerTransport` handles
`ServerTransport`), but an executable whose generated `@main` compiles away has no `main` symbol, so gating
in place would have meant conditionalising a dozen files to leave the default build with everything switched
off.

**Verified:** `Controllers`, pointed at this package, resolves no `swift-http-server`. The NIO *stack* it
still resolves (`swift-nio`, `-ssl`, `-http2`, `-extras`) comes from `swift-http-api-proposal`, which declares
those packages itself and which `Controllers` depends on directly — outside wire-mvc's control, and not what
the reported bug was about. CI guards the result: a step fails the build if `swift-http-server` reappears in
the core `Package.resolved`.

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
- ~~**Streaming / backpressure**~~ — **no longer true.** The in-process transport was reworked to hand each
  `write` to the consumer over a rendezvous channel (`InProcessExchange`), with `serve` running an accept
  loop so the handler runs concurrently with the test reading it. A `@RawRoute` streaming incrementally is
  observable in process, backpressure included, with no socket — see `inProcessAppliesBackpressurePerChunk`.
  This narrows the live mode's remaining value further.
- **The app's real server-wiring** — in-process never calls `createServer()`, so a bug in the real server
  construction / server-boundary behavior only shows up live.
- **Real connection capabilities** — TLS/ALPN, client cert, peer address a real `RequestContext` exposes.
- **Wire-protocol / real-client behavior** — keep-alive, HTTP/2, compression, redirects.

Several of these (wire codec, connection concurrency) are `swift-http-server`'s responsibility, not WireMVC's,
so for a WireMVC *app* the live mode's real value narrows to **integration-smoke + streaming**: a handful of
tests, not the suite. This is exactly why the live path may legitimately reuse `createServer()` — verifying the
real wiring is the point — and why the ephemeral read-back seam rightfully lives there and nowhere else.

## Migration

- *(Done, across Phases 3 and 5.)* Existing `@Suite(.wiremvc())` suites map to `.wiremvc(.appServer)`
  (behaviour-preserving) initially, then to
  `.wiremvc(.inProcess)` where they only exercise route/controller logic (most of them, including the mocked
  routing suite) or `.wiremvc(.swiftHttpServer)` where they want a real socket.
- The `@Provides @Replaces func testServerConfig() -> ServerConfig { … port: 0 }` in test targets is retired in
  favour of the mode/port on the suite trait.
- `WireMVCTesting`'s `public import NIOHTTPServer` + the `NIOHTTPServer` conformance move to
  `WireMVCTestingNIOHTTPServer`; the `swift-http-server` package dependency becomes needed only by that product
  and the in-package example/fixture targets (which can be trait-gated or moved out in a follow-up).
