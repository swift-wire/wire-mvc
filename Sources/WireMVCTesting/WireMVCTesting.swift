public import HTTPAPIs
public import ServiceLifecycle
public import Testing
import WireMVC

// Test support for a `@WireMVCBootstrap` app. The one public way to stand a suite up is the suite trait
// `@Suite(.wiremvc(<mode>))`: `WireMVCRouteGen` emits, in a test consumer, a `.wiremvc(_:)` factory whose
// closure inlines the SAME build-and-wrap the `@main` does (the finalized+wrapped handler is an opaque
// `~Copyable` type that can't be returned or stored, so the build is inlined and the opaque handler handed
// straight to a driver — exactly as the `@main` hands it to `WireMVC.serve<Server, Handler>`). The trait
// runs that closure once at suite entry, points `TestClient.current` at the resulting transport for the
// suite's tests, runs them, and tears down at suite exit.
//
// The ``WireMVCTestMode`` picks the transport, which is the only thing that differs between the two build
// paths — both build the app's real router, middleware fold, error tiers and `@NotFound` fallback:
//   • `.inProcess` builds over ``InProcessServer`` and calls the finalized handler directly
//     (``driveInProcess(handler:services:runTests:)``) — no socket, no port, no `createServer()`;
//   • `.appServer` builds over the app's own `createServer()` and serves it
//     (``serveForSuite(on:handler:services:runTests:)``), driving real HTTP per call.
//
// The target design has a third, and *standard*, live mode the harness has not grown yet: a
// **test-framework-owned** server on an ephemeral or fixed port (`.swiftHttpServer` / `.server(_:)`),
// which never calls `createServer()`. The app is meant to own routes and config while the test framework
// owns the transport — reusing the production server factory means un-configuring it for tests (TLS, bind
// interface, timeouts, HTTP/2, graceful shutdown). `.appServer` is deliberately named for what it is, so
// that mode can arrive without redefining a name.

/// A server that reports the port it bound. `serveForSuite` reads it to point `TestClient.current` at the
/// ephemeral loopback port the OS assigned (the app binds port `0` under test). This is the one capability
/// the seam needs beyond ``HTTPServer``, which surfaces no bound-address API. The `NIOHTTPServer`
/// conformance ships in the opt-in `WireMVCTestingNIOHTTPServer` product — the only place
/// `swift-http-server` enters the graph — so this module stays server-agnostic; a bootstrap returning
/// another server type conforms it to opt that server into the suite trait.
public protocol WireMVCTestServer {
    /// The port the server is listening on, once bound. Suspends until the first address binds.
    var wireMVCBoundPort: Int { get async throws }
}

/// The transport a `@Suite(.wiremvc(_:))` suite runs on. Orthogonal to *which* variant graph the suite
/// serves (the `TestingKey` argument) — this picks only how a request reaches the finalized handler.
public enum WireMVCTestMode: Sendable {
    /// Drive the finalized handler in memory: no socket, no port, and the app's `createServer()` is never
    /// called. Covers route, controller, middleware, error-mapping and keyed-harness logic — everything
    /// that doesn't depend on the transport. The default.
    case inProcess

    /// Serve the app's own `createServer()` and drive real HTTP over it. The only mode that exercises the
    /// app's real server construction, real connection capabilities, and genuine streaming/backpressure —
    /// but it serves on whatever port the app's `ServerConfig` carries, so a suite currently `@Replaces`
    /// that with `0` to get an ephemeral one. Reading the bound port back needs the server's
    /// ``WireMVCTestServer`` conformance in scope; for `NIOHTTPServer` that is the
    /// `WireMVCTestingNIOHTTPServer` product.
    ///
    /// This is *not* the standard live mode — a test-framework-owned server on a mode-chosen port is, and
    /// it does not exist yet. Reuse the app's factory only for a genuine end-to-end test whose point is
    /// verifying the real server wiring.
    case appServer
}

/// A failure reaching the running test server.
public enum WireMVCTestingError: Error {
    /// The server bound no listening address to read a port from.
    case noListeningPort
    /// ``InProcessServer`` was handed to a serving helper. It is a build-time stand-in that lets the
    /// `.inProcess` path construct the app's router over the in-memory types; the driver calls `handle`
    /// on the finalized handler instead of serving.
    case inProcessServerCannotServe
}

/// The suite trait standing up a `@WireMVCBootstrap` app's test server — `@Suite(.wiremvc())`. Non-generic
/// (the server and opaque `~Copyable` handler types stay inside `serve`, which the generated `.wiremvc()`
/// factory closes over): it holds a type-erasing serve closure that builds + serves the app and runs the
/// suite's tests inside it. `provideScope` runs `serve` once at suite entry (not per test case), threading
/// the tests through as `runTests`. `serve` cancels the server on the way out (suite exit).
public struct WireMVCSuiteTrait: SuiteTrait, TestScoping {
    public let isRecursive = false

    /// Builds + serves the app, then runs `runTests` against it and cancels — supplied by the generated
    /// `.wiremvc()` factory, which inlines the build and calls ``WireMVCTesting/serveForSuite(on:handler:services:runTests:)``.
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
    /// Serve `handler` on `server` on its (ephemeral) port, run the graph's collated app-scoped `services`,
    /// point `TestClient.current` at the bound loopback port, run `runTests()`, then cancel. The internal
    /// mechanism the ``WireMVCSuiteTrait``'s generated `.wiremvc()` factory hands its inlined build to. The
    /// generic signature mirrors `WireMVC.serve`'s — the `~Copyable` + associated-type constraints let the
    /// opaque, non-returnable finalized+wrapped `handler` flow in by inference — plus a `WireMVCTestServer`
    /// bound so the seam can read the bound port. Serving and the services run as child tasks so the tests
    /// drive real requests concurrently; both are cancelled on the way out.
    public static func serveForSuite<Server: HTTPServer & WireMVCTestServer, Handler: HTTPServerRequestHandler>(
        on server: Server,
        handler: Handler,
        services: [any Service],
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
            group.addTask { try await WireMVC.runServices(services) }
            group.addTask { try await server.serve(handler: handler) }
            let port = try await server.wireMVCBoundPort
            try await TestClient.$currentStorage.withValue(TestClient(host: "127.0.0.1", port: port)) {
                try await runTests()
            }
            group.cancelAll()
        }
    }

    /// Run the graph's collated app-scoped `services`, point `TestClient.current` at an in-process client
    /// over `handler`, run `runTests()`, then cancel. The `.inProcess` counterpart to
    /// ``serveForSuite(on:handler:services:runTests:)`` — same services half, but each request calls
    /// `handler.handle` directly instead of crossing a socket. The `Handler` bound pins the in-memory
    /// associated types, so only a handler built over ``InProcessServer`` can be driven here.
    ///
    /// Services run in a child task exactly as they do live; whether they *should* run is the suite's
    /// choice, and the caller passes an empty array to skip them.
    public static func driveInProcess<Handler: HTTPServerRequestHandler>(
        handler: Handler,
        services: [any Service],
        runTests: @concurrent @Sendable () async throws -> Void
    ) async throws
    where
        Handler.RequestContext == InProcessRequestContext,
        Handler.Reader == InProcessReader,
        Handler.ResponseSender == InProcessResponseSender
    {
        // The opaque handler can't be named or stored, but it *is* `Sendable` — so the dispatch closure
        // captures it and the non-generic `TestClient` carries it without knowing its type.
        let client = TestClient { request, body in
            let sink = ResponseSink()
            try await handler.handle(
                request: request,
                requestContext: InProcessRequestContext(),
                reader: InProcessReader(body),
                responseSender: InProcessResponseSender(sink: sink)
            )
            return sink.response
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await WireMVC.runServices(services) }
            try await TestClient.$currentStorage.withValue(client) {
                try await runTests()
            }
            group.cancelAll()
        }
    }
}
