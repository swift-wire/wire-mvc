// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import AsyncAlgorithms
public import AsyncStreaming
public import BasicContainers
public import HTTPAPIs
public import HTTPTypes
import Synchronization

// The in-process transport — the `.inProcess` mode's implementation of the proposal's server-side types,
// entirely in memory. There is no socket, no port, and no wire codec: a request is four values handed
// straight to the finalized handler's one entry point
// (`handle(request:requestContext:reader:responseSender:)`), and the response is whatever the handler
// wrote into a shared sink by the time that call returns.
//
// The point of ``InProcessServer`` is that it is a real ``HTTPServer``, all the way down: the generated
// factory passes it to the app's own `createRouteBuilder(for:)` (so the suite exercises the app's *actual*
// router, middleware fold, error tiers and `@NotFound` fallback), and then `serve(handler:)` — the same
// call the live modes make — installs a dispatch over the finalized handler and parks until the suite ends.
// Because in-process serving is a genuine `HTTPServer.serve`, the harness needs no per-mode branch: one
// driver serves whatever server the mode carries.
//
// These types are ordinary *copyable* structs. `AsyncReader`/`HTTPResponseSender`/`CallerAsyncWriter` are
// declared `~Copyable`/`~Escapable`, but that *relaxes* the constraint for conformers rather than
// requiring it — the same latitude `WireMVCServerTransport`'s bridge types take. They are also `Sendable`
// (their only storage is a `Sendable` sink), so handing them to `handle`'s `consuming sending` parameters
// needs no region gymnastics.

/// The in-process server: an ``HTTPServer`` whose request context, body reader, and response sender are
/// the in-memory types below. The app's `createRouteBuilder(for:)` builds its real router over those
/// types, and `serve(handler:)` publishes a dispatch over the finalized handler for ``TestClient`` to call.
public struct InProcessServer: HTTPServer {
    public typealias RequestContext = InProcessRequestContext
    public typealias Reader = InProcessReader
    public typealias ResponseSender = InProcessResponseSender

    /// The channel the client puts requests on and `serve`'s accept loop takes them off. A reference, so the
    /// copyable server value can be handed around freely.
    let dispatch = InProcessDispatch()

    public init() {}

    /// Take exchanges off the dispatch channel and run `handler` for each in a child task, until cancelled.
    /// An accept loop, like a socket-backed server's — which is what lets the response stream: the handler
    /// runs concurrently with the test consuming its body, so a `write` can suspend on the rendezvous.
    ///
    /// Handler tasks are children of this one, so the suite's task group cancels them on the way out and no
    /// unstructured task or lifetime handle is needed. In-flight handlers are bounded: past the limit the
    /// loop reaps a finished one before accepting another, so a long suite cannot accumulate children.
    public func serve<Handler: HTTPServerRequestHandler>(handler: Handler) async throws
    where
        Handler.RequestContext: ~Copyable,
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.Reader: ~Copyable,
        Handler.ResponseSender == ResponseSender,
        Handler.ResponseSender: ~Copyable
    {
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for await exchange in dispatch.exchanges {
                if inFlight >= Self.maximumInFlightRequests {
                    await group.next()
                    inFlight -= 1
                }
                group.addTask {
                    do {
                        try await handler.handle(
                            request: exchange.request,
                            requestContext: InProcessRequestContext(),
                            reader: InProcessReader(exchange.requestBody),
                            responseSender: InProcessResponseSender(exchange: exchange)
                        )
                        exchange.handlerFinished()
                    } catch {
                        exchange.handlerThrew(error)
                    }
                }
                inFlight += 1
            }
        }
    }

    /// How many handlers may be running at once. Generous for a suite — the interleaving tests hold two —
    /// and bounded only so the accept loop reaps finished children rather than holding every request the
    /// suite ever made.
    static let maximumInFlightRequests = 64
}

/// The in-process request context. The proposal's `RequestContext` is a capability marker and this
/// transport exposes none (no peer address, no TLS) — a route reading a real server capability is one of
/// the things only a live mode can cover.
public struct InProcessRequestContext: HTTPServerCapability.RequestContext {
    public init() {}
}

/// An in-memory `AsyncReader` over the request body — delivers the whole body in one read, fused with
/// the end-of-stream signal. No I/O, so `ReadFailure` is `Never`.
public struct InProcessReader: AsyncReader {
    public typealias ReadElement = UInt8
    public typealias ReadFailure = Never
    public typealias FinalElement = HTTPFields?
    public typealias Buffer = UniqueArray<UInt8>

    private let bytes: [UInt8]

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    public mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>(copying: bytes)
        do {
            // `.some(nil)` — the terminal chunk (end of stream) carrying no trailers.
            return try await body(&buffer, .some(nil))
        } catch {
            throw EitherError.second(error)
        }
    }
}

/// The in-process `HTTPResponseSender`. `send(_:)` publishes the head — so the consumer sees it before the
/// body exists — and returns a writer whose chunks cross the exchange's rendezvous channel. `sendAndFinish`
/// (the typed-route path) does both in one step.
public struct InProcessResponseSender: HTTPResponseSender {
    public typealias Writer = InProcessWriter

    let exchange: InProcessExchange

    public mutating func sendInformational(_ response: HTTPResponse) async throws {}

    public consuming func send(_ response: HTTPResponse) async throws -> InProcessWriter {
        exchange.publish(head: response)
        return InProcessWriter(exchange: exchange)
    }

    public consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        exchange.publish(head: response)
        let bytes = drainBytes(&buffer)
        if !bytes.isEmpty { await exchange.body.send(bytes[...]) }
        exchange.body.finish()
    }
}

/// The in-process body writer. Each `write` **suspends until the consumer receives the chunk** — the
/// rendezvous is what makes backpressure real in process, so a route that streams incrementally is paced by
/// the test reading it rather than filling a buffer nobody is watching.
public struct InProcessWriter: CallerAsyncWriter {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = Never
    public typealias FinalElement = HTTPFields?

    let exchange: InProcessExchange

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = drainBytes(&buffer)
        if !bytes.isEmpty { await exchange.body.send(bytes[...]) }
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = drainBytes(&buffer)
        if !bytes.isEmpty { await exchange.body.send(bytes[...]) }
        exchange.body.finish()
    }
}

/// Drain a caller-supplied container into a plain byte array — the one place the generic
/// `RangeReplaceableContainer` is consumed, shared by the sender's one-shot path and the writer.
func drainBytes<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
    _ buffer: inout Buffer
) -> [UInt8] where Buffer.Element: ~Copyable {
    var bytes: [UInt8] = []
    var consumer = buffer.consumeAll()
    while let byte = consumer.next() { bytes.append(byte) }
    return bytes
}
