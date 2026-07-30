#if NIOHTTPServer
import AHCHTTPClient
import AsyncAlgorithms
import AsyncHTTPClient
import Foundation
import HTTPAPIs
import HTTPTypes

// The live transport: a real HTTP round-trip driven by a proposal `HTTPClient`, piped into the same
// ``TestExchange`` the in-process transport answers on. Everything above the exchange — the buffered verbs,
// the generated typed clients, `performRawRoute` — is therefore transport-agnostic, and a live suite gets
// the same incremental reads an in-process one does.
//
// Behind the `NIOHTTPServer` trait, with the server half: a live suite needs both, and with the trait off
// neither this file nor `swift-http-server` is in the build. It costs no package in a consumer's
// `Package.resolved` — `swift-http-api-proposal` already declares async-http-client — only a link
// dependency for a target that opts in.
//
// Why async-http-client's client rather than the proposal's URLSession-backed one: that one is
// `#if canImport(Darwin)`, so it does not exist on the Linux CI runs at all, and it is separately known to
// hang collecting keep-alive responses on this toolchain (see the examples' `CouchDB.swift`).
//
// KNOWN ISSUE — this transport does not pass yet, and the fixtures' live suites fail because of it. Requests
// fail in single-digit milliseconds with `HTTPClientError.remoteConnectionClosed`, on a different subset of
// tests each run. Two causes were found and fixed and neither was the whole story: a process-wide `.shared`
// pool handing out connections to torn-down ephemeral ports (fixed by the per-suite client below), and
// producer cancellation cutting into `perform`'s connection cleanup (fixed by `awaitCompletion` before the
// exchange is released). What remains looks like connection establishment racing suite startup: the failing
// suites are the parallel ones, several requests reach a just-bound server at once, and the failure is far
// too fast to be mid-body. The in-process transport is unaffected — it shares only the exchange.

/// Starts live exchanges against a bound loopback port, over a client owned by this suite.
///
/// Deliberately **not** `HTTPClient.shared`: that pools keep-alive connections process-wide, while each
/// suite binds an ephemeral port and tears it down at exit — so a later suite would take a pooled connection
/// to a dead server and see `remoteConnectionClosed`. A per-suite client's pool dies with its suite. It must
/// be shut down (`HTTPClient` calls `preconditionFailure` in `deinit` otherwise), which
/// ``TestTransportSession`` does in `runSuite`'s `defer`.
final class LiveDispatch: Sendable {
    private let host: String
    private let port: Int
    private let client: AsyncHTTPClient.HTTPClient

    init(host: String, port: Int) {
        self.host = host
        self.port = port
        // The singleton event-loop group: a suite's client is a connection pool, not a thread pool.
        self.client = AsyncHTTPClient.HTTPClient(eventLoopGroupProvider: .singleton)
    }

    /// Release the connection pool. Called once, at suite exit, before the server is cancelled.
    func shutdown() async {
        try? await client.shutdown()
    }

    /// Start one request and hand back its exchange. Returns once the response head has been piped in — the
    /// body then arrives chunk by chunk as the client reads it off the socket.
    func start(_ request: HTTPRequest, body: Data?) async throws -> TestExchange {
        let exchange = TestExchange(request: request, requestBody: body.map(Array.init) ?? [])
        var addressed = request
        addressed.scheme = "http"
        addressed.authority = "\(host):\(port)"

        // The perform call outlives this function — it feeds the exchange while the caller reads it — so it
        // runs in a task bound to the exchange. Dropping the exchange without draining cancels it rather
        // than leaving the client parked on a body nobody is taking.
        let task = Task {
            do {
                // The convenience overload supplies `defaultRequestOptions`; it is `mutating`, so the
                // client is bound locally (it is a class — the binding is the reference).
                var client = self.client
                try await client.perform(
                    request: addressed,
                    body: body.map { .data($0) }
                ) { response, reader in
                    exchange.publish(head: response)
                    var reader = reader
                    var finished = false
                    while !finished {
                        try await reader.read { buffer, final in
                            let chunk = drainBytes(&buffer)
                            if !chunk.isEmpty { await exchange.body.send(chunk[...]) }
                            if final != nil { finished = true }
                        }
                    }
                }
                exchange.handlerFinished()
            } catch {
                exchange.handlerThrew(error)
            }
        }
        exchange.bindProducer(task)
        return exchange
    }
}
#endif
