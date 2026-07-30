public import HTTPAPIs
public import ServiceLifecycle
public import Testing
import WireMVC

// Test support for a `@WireMVCBootstrap` app. The one public way to stand a suite up is the suite trait
// `@Suite(.wiremvc(<mode>))`: `WireMVCRouteGen` emits, in a test consumer, a `.wiremvc(_:)` factory whose
// closure inlines the SAME build-and-wrap the `@main` does (the finalized+wrapped handler is an opaque
// `~Copyable` type that can't be returned or stored, so the build is inlined and the opaque handler handed
// straight to the driver — exactly as the `@main` hands it to `WireMVC.serve<Server, Handler>`). The trait
// runs that closure once at suite entry, points `TestClient.current` at the running transport for the
// suite's tests, runs them, and tears down at suite exit.
//
// **The app owns routes and config; the harness owns the transport.** A ``WireMVCTestMode`` carries the
// server the suite runs on, so the generated factory has a single build path — it registers the app's
// collated routes onto `bootstrap.createRouteBuilder(for: mode.server)` and hands the finalized handler to
// ``runSuite(_:handler:services:runTests:)``, which serves it. The app's own `createServer()` is never
// called under test: production and test server configuration diverge (TLS, bind interface, timeouts,
// connection limits, HTTP/2, graceful shutdown), so sharing the factory would mean un-configuring it.
//
// Every mode is a real `HTTPServer` — ``InProcessServer`` included, whose `serve` publishes an in-memory
// dispatch instead of binding a socket. That is what lets one driver cover all of them, and it keeps the
// generated code free of any concrete server type: the constraint on which servers are usable is
// discharged where the test writes `.inProcess` / `.swiftHttpServer` / `.server(_:)`.

/// A server that reports the port it bound. An **ephemeral** live mode reads it to point
/// `TestClient.current` at the loopback port the OS assigned — the harness binds `0`, so the app's
/// `ServerConfig` is not involved. This is the one capability the seam needs beyond ``HTTPServer``, which
/// surfaces no bound-address API, and only an ephemeral mode needs it: ``WireMVCTestMode/server(_:on:)``
/// already knows its port, so this bound does not appear in that signature.
///
/// The `NIOHTTPServer` conformance is `#if NIOHTTPServer` in this module, so with the trait off nothing
/// here names a concrete server. A bootstrap serving on another server type conforms it to opt that server
/// into ``WireMVCTestMode/server(_:)``.
public protocol WireMVCTestServer {
    /// The port the server is listening on, once bound. Suspends until the first address binds.
    var wireMVCBoundPort: Int { get async throws }
}

/// Whether a suite starts the graph's collated app-scoped `ServiceLifecycle` services.
public enum WireMVCTestServices: Sendable {
    /// Start them alongside the transport, as production does.
    case run
    /// Leave them stopped — the isolation-friendly choice for a suite testing route logic.
    case skip
}

/// The transport a `@Suite(.wiremvc(_:))` suite runs on: the server it serves, and how to reach that
/// server once it is serving. Orthogonal to *which* variant graph the suite serves (the `TestingKey`
/// argument) — this picks only how a request reaches the finalized handler.
///
/// Generic over the server, so the generated factory builds the app's router over `server`'s associated
/// types with one build path and never names a concrete server. `client` is a plain stored closure rather
/// than a protocol requirement precisely because it does *not* mention the handler type: whatever a mode
/// needs in order to reach its server (a bound-port read-back, a known port, an in-memory dispatch) is
/// captured when the mode is constructed, where the concrete server type is still known.
public struct WireMVCTestMode<Server: HTTPServer>: Sendable
where
    Server.RequestContext: ~Copyable,
    Server.Reader: ~Copyable,
    Server.ResponseSender: ~Copyable,
    Server.ResponseSender.Writer: ~Copyable
{
    /// Builds the server this suite serves the app on. A factory rather than an instance because a mode is
    /// constructed when the `@Suite(.wiremvc(…))` *attribute* is evaluated — which happens for every suite
    /// in the bundle, including ones the run filters out. A server built there and never served is at best
    /// wasted and at worst fatal (`NIOHTTPServer` traps on a leaked unfulfilled promise), so nothing is
    /// built until the trait actually enters the suite.
    let makeServer: @Sendable () -> Server
    /// Builds the client for the server, once it is serving, together with the teardown its transport
    /// needs. A live transport owns a connection pool that must not outlive the suite's server; in-process
    /// has nothing to tear down.
    let client: @Sendable (Server) async throws -> TestTransportSession
    /// What this mode does with the graph's services when the suite does not say.
    let defaultServices: WireMVCTestServices

    init(
        defaultServices: WireMVCTestServices,
        makeServer: @escaping @Sendable () -> Server,
        client: @escaping @Sendable (Server) async throws -> TestTransportSession
    ) {
        self.makeServer = makeServer
        self.client = client
        self.defaultServices = defaultServices
    }

    /// The server to serve this suite on. The generated factory calls it once per suite entry and builds
    /// the app's route builder over it.
    public func makeTestServer() -> Server { makeServer() }
}

extension WireMVCTestMode where Server == InProcessServer {
    /// Drive the finalized handler in memory: no socket, no port, no wire codec. Covers route, controller,
    /// middleware, error-mapping and keyed-harness logic — everything that does not depend on the
    /// transport, which is the vast majority of a suite. Services default to ``WireMVCTestServices/skip``,
    /// since a route-logic suite wants isolation; pass `services: .run` for a route that needs a started
    /// service.
    public static var inProcess: WireMVCTestMode<InProcessServer> {
        WireMVCTestMode(defaultServices: .skip) {
            InProcessServer()
        } client: { server in
            // Nothing to tear down: the in-process transport is the suite's own task tree.
            TestTransportSession(client: TestClient(dispatch: server.dispatch))
        }
    }
}

// The live modes need a client to reach the server they stand up, and the proposal client ships behind the
// `NIOHTTPServer` trait with the server half — so these factories exist only when it is enabled. With the
// trait off, `.inProcess` is the whole surface, which is exactly the configuration a framework-agnostic
// consumer wants.
//
// The suppressions the struct declares have to be restated on a generic extension of it — otherwise
// `Copyable` is re-imposed on the associated types and no proposal server satisfies these factories.
#if NIOHTTPServer
extension WireMVCTestMode
where
    Server.RequestContext: ~Copyable,
    Server.Reader: ~Copyable,
    Server.ResponseSender: ~Copyable,
    Server.ResponseSender.Writer: ~Copyable
{
    /// Serve on a caller-supplied server bound to an **ephemeral** port, reading the port the OS assigned
    /// back through ``WireMVCTestServer``. The generic escape hatch: an app on a non-NIO server plugs in
    /// here, as does a test that wants a specific server configuration.
    ///
    /// The server expression is `@autoclosure`, so it reads as a plain value at the call site but is not
    /// evaluated until the suite starts. That matters because a mode is built when the
    /// `@Suite(.wiremvc(…))` attribute is evaluated — for every suite in the bundle, filtered-out ones
    /// included — and a server constructed there and never served is at best wasted work and at worst
    /// fatal (`NIOHTTPServer` traps on the unfulfilled listening promise its `init` creates).
    public static func server(
        _ makeServer: @autoclosure @escaping @Sendable () -> Server
    ) -> WireMVCTestMode<Server>
    where Server: WireMVCTestServer {
        WireMVCTestMode(defaultServices: .run, makeServer: makeServer) { server in
            let dispatch = LiveDispatch(host: loopbackHost, port: try await server.wireMVCBoundPort)
            return TestTransportSession(client: TestClient(dispatch: dispatch)) { await dispatch.shutdown() }
        }
    }

    /// Serve on a caller-supplied server bound to a **known** port. The client already knows where to
    /// reach it, so — unlike ``server(_:)`` — this needs no ``WireMVCTestServer`` read-back, and that shows
    /// in the signature. The server expression is deferred for the same reason as ``server(_:)``.
    public static func server(
        _ makeServer: @autoclosure @escaping @Sendable () -> Server,
        on port: Int
    ) -> WireMVCTestMode<Server> {
        WireMVCTestMode(defaultServices: .run, makeServer: makeServer) { _ in
            let dispatch = LiveDispatch(host: loopbackHost, port: port)
            return TestTransportSession(client: TestClient(dispatch: dispatch)) { await dispatch.shutdown() }
        }
    }
}

#endif

/// A suite's client plus whatever its transport must release at suite exit.
public struct TestTransportSession: Sendable {
    let client: TestClient
    /// Run once the suite's tests have finished, before the server is cancelled. A live transport shuts its
    /// connection pool down here — pooled keep-alive connections must not survive the ephemeral server they
    /// point at, or a later suite picks one up and sees the far end closed.
    let shutdown: @Sendable () async -> Void

    init(client: TestClient, shutdown: @escaping @Sendable () async -> Void = {}) {
        self.client = client
        self.shutdown = shutdown
    }
}

/// The interface a live suite's server binds and its client dials.
let loopbackHost = "127.0.0.1"

/// A failure reaching the running test server.
public enum WireMVCTestingError: Error {
    /// The server bound no listening address to read a port from.
    case noListeningPort
    /// A route returned without sending a response — there is no head to report. Live, the server aborts the
    /// connection; in-process there is nothing to abort, so it surfaces here rather than as a plausible 500.
    case routeDidNotRespond(String)
}

/// The suite trait standing up a `@WireMVCBootstrap` app's test server — `@Suite(.wiremvc())`. Non-generic
/// (the server and opaque `~Copyable` handler types stay inside `serve`, which the generated `.wiremvc()`
/// factory closes over): it holds a type-erasing serve closure that builds + serves the app and runs the
/// suite's tests inside it. `provideScope` runs `serve` once at suite entry (not per test case), threading
/// the tests through as `runTests`. `serve` cancels the server on the way out (suite exit).
public struct WireMVCSuiteTrait: SuiteTrait, TestScoping {
    public let isRecursive = false

    /// Builds + serves the app, then runs `runTests` against it and cancels — supplied by the generated
    /// `.wiremvc(_:)` factory, which inlines the build and calls
    /// ``WireMVCTesting/runSuite(_:handler:services:runTests:)``.
    let serve: @Sendable (_ runTests: @concurrent @Sendable () async throws -> Void) async throws -> Void

    public init(
        serve: @escaping @Sendable (_ runTests: @concurrent @Sendable () async throws -> Void) async throws -> Void
    ) {
        self.serve = serve
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing execute: @concurrent @Sendable () async throws -> Void
    ) async throws {
        // Only scope at suite level, not individual test cases — the server stands up once for the whole
        // suite, and each test case runs against the shared client.
        guard testCase == nil else {
            try await execute()
            return
        }
        try await serve { try await execute() }
    }
}

public enum WireMVCTesting {
    /// Serve `handler` on `mode`'s server, optionally run the graph's collated app-scoped services, point
    /// `TestClient.current` at the running transport, run `runTests()`, then cancel. The one mechanism the
    /// ``WireMVCSuiteTrait``'s generated `.wiremvc(_:)` factory hands its inlined build to, whatever the
    /// mode: `.inProcess` differs from a live mode only in what `serve` and `client` do.
    ///
    /// The generic signature mirrors `WireMVC.serve`'s — the `~Copyable` + associated-type constraints let
    /// the opaque, non-returnable finalized+wrapped `handler` flow in by inference. Serving and the
    /// services run as child tasks so the tests drive requests concurrently; both are cancelled on the way
    /// out. `servicePolicy` overrides the mode's default when the suite states one.
    ///
    /// `server` is passed in rather than taken from `mode` because the caller already built it: the app's
    /// route builder is created *for* a server, so the generated factory calls
    /// ``WireMVCTestMode/makeTestServer()`` before the build and hands the same instance on. Building a
    /// second one here would serve a different server than the router was built for.
    public static func runSuite<Server: HTTPServer, Handler: HTTPServerRequestHandler>(
        _ mode: WireMVCTestMode<Server>,
        on server: Server,
        handler: Handler,
        services: [any Service],
        servicePolicy: WireMVCTestServices? = nil,
        runTests: @concurrent @Sendable () async throws -> Void
    ) async throws
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable,
        Handler.RequestContext == Server.RequestContext,
        Handler.Reader == Server.Reader,
        Handler.ResponseSender == Server.ResponseSender
    {
        try await withThrowingTaskGroup(of: Void.self) { group in
            if servicePolicy ?? mode.defaultServices == .run {
                group.addTask { try await WireMVC.runServices(services) }
            }
            group.addTask { try await server.serve(handler: handler) }
            let session = try await mode.client(server)
            // Tear the transport down before cancelling the server, on every exit path — a live client
            // traps in `deinit` if it is never shut down, so this must not be missed when a test throws or
            // the suite is cancelled.
            defer { await session.shutdown() }
            try await TestClient.$currentStorage.withValue(session.client) {
                try await runTests()
            }
            group.cancelAll()
        }
    }
}
