// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncAlgorithms
import Foundation
public import HTTPTypes
import Synchronization

// One in-flight request/response pair on the in-process transport, and the channel the server's accept loop
// takes them from. This is what makes in-process *streaming*: the response head travels ahead of the body,
// and each body chunk crosses a rendezvous — so a handler's `write` suspends until the test reads it, which
// is real backpressure rather than a buffer filled before anyone looks.
//
// The shape mirrors `WireMVCServerTransport`'s bridge, which solves the same problem for OpenAPIRuntime: a
// one-shot start (the head, or the two ways a handler can fail to produce one) plus a rendezvous body. The
// difference is ownership — there the handler must outlive the framework's closure and so runs unstructured;
// here `InProcessServer.serve` owns an accept loop, so handler tasks are its children and cancellation flows
// from the suite's task group without a lifetime handle.

/// How a response begins, delivered from the handler to whoever is driving the request.
enum InProcessResponseStart: Sendable {
    /// `send(_:)` or `sendAndFinish(…)` produced a head; the body follows on the exchange's channel.
    case head(HTTPResponse)
    /// The handler threw before responding. Re-thrown to the caller, since no response exists to report.
    case failed(any Error)
    /// The handler returned without responding — invalid, and distinct from any status it could have sent.
    case finishedWithoutResponse
}

/// One request in flight: what the handler is given, and the two channels it answers on.
final class InProcessExchange: Sendable {
    let request: HTTPRequest
    let requestBody: [UInt8]

    /// The response body, chunk by chunk. A rendezvous channel: `send` suspends until the consumer receives,
    /// so a handler streaming a large body is paced by the test reading it.
    let body = AsyncChannel<ArraySlice<UInt8>>()

    private let startStream: AsyncStream<InProcessResponseStart>
    private let startContinuation: AsyncStream<InProcessResponseStart>.Continuation
    private let responded = Mutex(false)

    init(request: HTTPRequest, requestBody: [UInt8]) {
        self.request = request
        self.requestBody = requestBody
        (startStream, startContinuation) = AsyncStream.makeStream(of: InProcessResponseStart.self)
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

    /// Await the response head (or the reason there isn't one).
    func awaitStart() async -> InProcessResponseStart {
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
        return collected
    }
}

/// The channel `InProcessServer.serve` takes exchanges from, and the client puts them on. Separate from the
/// server value so the client can reach it before `serve` has started — the two race at suite entry, and a
/// request made first simply waits for the accept loop.
final class InProcessDispatch: Sendable {
    private let incoming = AsyncChannel<InProcessExchange>()

    /// Start one request: enqueue it for the accept loop and hand back its exchange. Returns as soon as the
    /// loop has taken it, *before* the handler has responded — which is what lets the caller read the head
    /// and then the body as they are produced.
    func start(_ request: HTTPRequest, body: Data?) async throws -> InProcessExchange {
        let exchange = InProcessExchange(request: request, requestBody: body.map(Array.init) ?? [])
        await incoming.send(exchange)
        return exchange
    }

    /// The accept loop's source. Iterated once, by `serve`.
    var exchanges: AsyncChannel<InProcessExchange> { incoming }
}
