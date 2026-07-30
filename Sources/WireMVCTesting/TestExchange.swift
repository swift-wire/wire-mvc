import AsyncAlgorithms
public import Foundation
public import HTTPTypes
import Synchronization

// One in-flight request/response pair, and the channel the in-process accept loop takes them from. This is
// the shape *both* transports answer on: the response head travels ahead of the body, and each body chunk
// crosses a rendezvous — so whoever produces the response is paced by the test reading it. In-process fills
// an exchange from the app's handler; the live transport fills one by piping a proposal `HTTPClient.perform`
// into it. Everything above (`TestResponseReader`, the buffered verbs, the generated clients) reads an
// exchange and so is transport-agnostic.
//
// The shape mirrors `WireMVCServerTransport`'s bridge, which solves the same problem for OpenAPIRuntime: a
// one-shot start (the head, or the two ways a producer can fail to give one) plus a rendezvous body. The
// difference is ownership — there the handler must outlive the framework's closure and so runs unstructured;
// here `InProcessServer.serve` owns an accept loop, so handler tasks are its children and cancellation flows
// from the suite's task group without a lifetime handle.

/// How a response begins, delivered from whoever produces it to whoever is driving the request.
enum TestResponseStart: Sendable {
    /// `send(_:)` or `sendAndFinish(…)` produced a head; the body follows on the exchange's channel.
    case head(HTTPResponse)
    /// The handler threw before responding. Re-thrown to the caller, since no response exists to report.
    case failed(any Error)
    /// The handler returned without responding — invalid, and distinct from any status it could have sent.
    case finishedWithoutResponse
}

/// One request in flight: what the producer is given, and the two channels it answers on.
final class TestExchange: Sendable {
    let request: HTTPRequest
    let requestBody: [UInt8]

    /// The response body, chunk by chunk. A rendezvous channel: `send` suspends until the consumer receives,
    /// so a handler streaming a large body is paced by the test reading it.
    let body = AsyncChannel<ArraySlice<UInt8>>()

    private let startStream: AsyncStream<TestResponseStart>
    private let startContinuation: AsyncStream<TestResponseStart>.Continuation
    private let responded = Mutex(false)
    /// The task producing this response, when one is unstructured (the live transport's `perform`). Cancelled
    /// when the exchange is released, so a body nobody drains cannot park the producer forever. The
    /// in-process transport leaves this `nil` — its producer is a child of `serve`.
    private let producer = Mutex<Task<Void, Never>?>(nil)

    init(request: HTTPRequest, requestBody: [UInt8]) {
        self.request = request
        self.requestBody = requestBody
        (startStream, startContinuation) = AsyncStream.makeStream(of: TestResponseStart.self)
    }

    /// Publish the response head. The consumer can begin reading the body immediately after.
    func publish(head: HTTPResponse) {
        responded.withLock { $0 = true }
        startContinuation.yield(.head(head))
        startContinuation.finish()
    }

    /// The handler threw. Before a head, that is the caller's error; after one, the head is already out, so
    /// the body is simply cut short.
    func handlerThrew(_ error: any Error) {
        if responded.withLock({ $0 }) {
            body.finish()
        } else {
            startContinuation.yield(.failed(error))
            startContinuation.finish()
        }
    }

    /// The handler returned. The writer's `finish` normally ended the body already; this closes both as a
    /// safety net and flags the never-responded case.
    func handlerFinished() {
        if !responded.withLock({ $0 }) {
            startContinuation.yield(.finishedWithoutResponse)
            startContinuation.finish()
        }
        body.finish()
    }

    /// Bind a producing task's lifetime to this exchange.
    func bindProducer(_ task: Task<Void, Never>) {
        producer.withLock { $0 = task }
    }

    /// Wait for the producer to finish after its body has been consumed.
    ///
    /// Necessary, not tidiness: a live producer is a `perform` call, and `perform` does per-request
    /// connection cleanup *after* its response handler returns. Letting the exchange die at that point runs
    /// `deinit`'s cancellation into the middle of that cleanup, which poisons the pooled connection — the
    /// next request on it fails with `remoteConnectionClosed`. Awaiting first means cancellation only ever
    /// applies to a producer that really was abandoned.
    func awaitCompletion() async {
        await producer.withLock { $0 }?.value
    }

    deinit {
        producer.withLock { $0 }?.cancel()
    }

    /// Await the response head (or the reason there isn't one).
    func awaitStart() async -> TestResponseStart {
        for await start in startStream { return start }
        return .finishedWithoutResponse
    }

    /// The head, `nil` when the handler returned without responding. A handler that threw before responding
    /// rethrows here, since there is no response to report.
    func startedHead() async throws -> HTTPResponse? {
        switch await awaitStart() {
        case let .head(head): return head
        case let .failed(error): throw error
        case .finishedWithoutResponse: return nil
        }
    }

    /// Collect the whole body — what the buffered surface (`TestClient`'s verbs, the typed route methods)
    /// does over this streaming transport.
    func drainBody() async throws -> Data {
        var collected = Data()
        for await chunk in body { collected.append(contentsOf: chunk) }
        await awaitCompletion()
        return collected
    }

    /// Discard anything the consumer left unread, then let the producer finish. A streaming caller may
    /// return from its response handler mid-body; the producer stays suspended on the rendezvous until
    /// someone takes the rest.
    func drainRemainder() async {
        for await _ in body {}
        await awaitCompletion()
    }
}

/// The channel `InProcessServer.serve` takes exchanges from, and the client puts them on. Separate from the
/// server value so the client can reach it before `serve` has started — the two race at suite entry, and a
/// request made first simply waits for the accept loop.
final class InProcessDispatch: Sendable {
    private let incoming = AsyncChannel<TestExchange>()

    /// Start one request: enqueue it for the accept loop and hand back its exchange. Returns as soon as the
    /// loop has taken it, *before* the handler has responded — which is what lets the caller read the head
    /// and then the body as they are produced.
    func start(_ request: HTTPRequest, body: Data?) async throws -> TestExchange {
        let exchange = TestExchange(request: request, requestBody: body.map(Array.init) ?? [])
        await incoming.send(exchange)
        return exchange
    }

    /// The accept loop's source. Iterated once, by `serve`.
    var exchanges: AsyncChannel<TestExchange> { incoming }
}
