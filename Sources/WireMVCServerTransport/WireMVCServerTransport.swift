#if ServerTransport
public import OpenAPIRuntime
public import ServiceLifecycle
public import Wire
public import WireMVC

import AsyncAlgorithms
import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// Serve proposal-native WireMVC controllers on OpenAPIRuntime's `ServerTransport` (Hummingbird/Vapor
// via swift-openapi-hummingbird/-vapor). The bridge adapts the proposal's `~Copyable` streaming
// reader/sender that `@Controller`'s witnesses drive down to the transport's copyable `HTTPBody`
// currency. It's a thin per-route adapter: `ServerTransport` does its own routing and supplies the
// path parameters, so there's no router here — one `transport.register` per collated route.
//
// The response bridge **streams**: a raw handler (M5.2 — SSE, chunked bodies) drives the sender
// incrementally, and each write flows to the transport's `HTTPBody` through a rendezvous `AsyncChannel`
// (backpressure), so an unbounded stream never buffers. Typed handlers take a one-shot `sendAndFinish`
// fast path that keeps a known-length body (`Content-Length`, not chunked). Proven end-to-end in
// swift-wire-spikes/spike-14.
//
// The request bridge streams the same way: `BridgeReader` pulls one chunk per `read` off the
// transport's `HTTPBody`, so a streaming binding on this path behaves as it does on the proposal-native
// path — the handler sees the first bytes before the last have arrived, and can abandon a body it has
// decided against instead of paying to receive it.
//
// A `ServerTransport` handler must outlive the `register` closure (it produces the streamed body the
// framework consumes afterward), so it runs in a task that can't be a structured child. For a streamed
// response that task's lifetime is bound to the returned body — released (and cancelled) when the
// transport is done with or drops the body — so a client disconnect doesn't leak a handler parked on
// backpressure.
//
// The bridge types are ordinary *copyable* structs: `AsyncReader`/`HTTPResponseSender`/
// `CallerAsyncWriter` are `~Copyable`/`~Escapable`, but that relaxes the constraint (conformers may be
// non-copyable), it doesn't require it.

/// Empty request context — the proposal's `HTTPServerCapability.RequestContext` is a marker; there is
/// no real server context on the ServerTransport path.
private struct BridgeRequestContext: HTTPServerCapability.RequestContext {}

/// The request body's iteration state. A class because ``BridgeReader`` is a struct the handler holds
/// across reads while the iterator's position has to survive each one; `@unchecked Sendable` on the same
/// terms as ``ResponseChannel`` — every call happens on the single handler task.
private final class BridgeBodySource: @unchecked Sendable {
    /// `nil` once the body has ended (or when the request carried none), which is what makes a read past
    /// the terminal chunk answer "still ended" rather than iterate an exhausted sequence.
    private var iterator: HTTPBody.Iterator?

    init(_ body: HTTPBody?) {
        iterator = body?.makeAsyncIterator()
    }

    func next() async throws -> HTTPBody.ByteChunk? {
        guard var iterator else { return nil }
        do {
            let chunk = try await iterator.next()
            self.iterator = chunk == nil ? nil : iterator
            return chunk
        } catch {
            self.iterator = nil
            throw error
        }
    }
}

/// A copyable `AsyncReader` over the transport's request body — **one read per body chunk**, so an
/// upload is never buffered whole and a handler can act on a body before the rest of it has arrived.
/// How large a body a route will accept is WireMVC's own policy (`WireMVCRequest.collectBody`'s
/// `maximumSize`, a streaming binding's own limit), exactly as on the proposal-native path; the bridge
/// imposes none of its own.
///
/// `ReadFailure` is `any Error` because the body is real I/O here: the transport's sequence can fail
/// part-way through (a client that disconnects mid-upload), where the previous collect-it-all reader
/// could only ever succeed.
private struct BridgeReader: AsyncReader {
    typealias ReadElement = UInt8
    typealias ReadFailure = any Error
    typealias FinalElement = HTTPFields?
    typealias Buffer = UniqueArray<UInt8>

    private let source: BridgeBodySource
    init(_ body: HTTPBody?) { source = BridgeBodySource(body) }

    mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        let chunk: HTTPBody.ByteChunk?
        do {
            chunk = try await source.next()
        } catch {
            throw EitherError.first(error)
        }
        // The end is only known once the sequence has answered `nil`, so the terminal read delivers an
        // empty buffer rather than fusing the last chunk with the end signal. Reading one chunk ahead to
        // fuse them would pull bytes off the network the handler hasn't asked for — the opposite of what
        // a streaming binding that decides on the first field and abandons the rest wants.
        var buffer = chunk.map { Buffer(copying: $0) } ?? Buffer()
        do {
            // `.some(nil)` — terminal chunk (end of stream) with no trailers; `nil` — more may follow.
            // A `ServerTransport` has no trailers to deliver either way.
            return try await body(&buffer, chunk == nil ? .some(nil) : nil)
        } catch {
            throw EitherError.second(error)
        }
    }
}

/// How a request's response begins, delivered from the handler to the `transport.register` closure so
/// it can return `(HTTPResponse, HTTPBody?)` without buffering a streamed body.
private enum ResponseStart {
    /// One-shot `sendAndFinish` — the whole body is known, so it returns a known-length `HTTPBody`.
    case complete(HTTPResponse, [UInt8])
    /// `send(_:)` — the head is known but the body streams; the register closure returns a streaming
    /// `HTTPBody` backed by `body` while the handler keeps writing.
    case streaming(HTTPResponse)
    /// The handler threw before producing any response — re-thrown so the framework maps it (a 500),
    /// preserving the pre-streaming error behavior.
    case failed(any Error)
    /// The handler returned without ever responding (invalid) — a defensive 500.
    case finishedWithoutResponse
}

/// Coordinates the handler (running concurrently) with the `transport.register` closure. The response
/// *start* travels on a one-shot buffered `AsyncStream`; a streamed body travels on `body`, a
/// **rendezvous** `AsyncChannel` — each `send` suspends until the transport pulls the chunk, which is
/// real backpressure. All mutation happens on the single handler task, so no lock is needed.
private final class ResponseChannel: @unchecked Sendable {
    let body = AsyncChannel<ArraySlice<UInt8>>()
    private let startStream: AsyncStream<ResponseStart>
    private let startContinuation: AsyncStream<ResponseStart>.Continuation
    private var responded = false

    init() {
        (startStream, startContinuation) = AsyncStream.makeStream(of: ResponseStart.self)
    }

    func deliverComplete(_ response: HTTPResponse, _ bytes: [UInt8]) {
        responded = true
        startContinuation.yield(.complete(response, bytes))
        startContinuation.finish()
    }

    func deliverStreaming(_ response: HTTPResponse) {
        responded = true
        startContinuation.yield(.streaming(response))
        startContinuation.finish()
    }

    /// The handler threw. If nothing was sent yet, surface the error to the register closure; otherwise
    /// the head is already out, so just terminate the (truncated) body.
    func handlerThrew(_ error: any Error) {
        if responded {
            body.finish()
        } else {
            startContinuation.yield(.failed(error))
            startContinuation.finish()
        }
    }

    /// The handler returned normally. The streaming writer's `finish` already ended the body; this is a
    /// safety net (and flags the invalid never-responded case).
    func handlerFinished() {
        if !responded {
            startContinuation.yield(.finishedWithoutResponse)
            startContinuation.finish()
        }
        body.finish()
    }

    func awaitStart() async -> ResponseStart {
        for await start in startStream { return start }
        return .finishedWithoutResponse
    }
}

/// A copyable `CallerAsyncWriter` that streams each written chunk onto the channel's body. `send`
/// suspends until the transport receives (backpressure); `WriteFailure` is `Never`.
private struct BridgeWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    let channel: ResponseChannel

    mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = Self.drain(&buffer)
        if !bytes.isEmpty { await channel.body.send(bytes[...]) }
    }

    consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        let bytes = Self.drain(&buffer)
        if !bytes.isEmpty { await channel.body.send(bytes[...]) }
        channel.body.finish()
    }

    static func drain<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ buffer: inout Buffer
    ) -> [UInt8] where Buffer.Element: ~Copyable {
        var out: [UInt8] = []
        var consumer = buffer.consumeAll()
        while let byte = consumer.next() { out.append(byte) }
        return out
    }
}

/// Cancels the producing handler task when the response body it feeds is released. A `ServerTransport`
/// handler must outlive the `register` closure (it produces the streamed body the framework consumes
/// afterward), so it can't be a structured child; binding it to the body instead means a stream the
/// transport stops consuming (client disconnect) cancels the handler rather than parking it forever on
/// backpressure. On normal completion the task has already finished and `cancel()` is a no-op.
private final class HandlerTaskHandle: Sendable {
    private let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    deinit { task.cancel() }
}

/// A copyable `HTTPResponseSender`. `sendAndFinish` (one-shot — the typed path) is fused into a
/// known-length response; `send(_:)` (the raw/streaming path) hands back a streaming writer.
private struct BridgeResponseSender: HTTPResponseSender {
    typealias Writer = BridgeWriter

    let channel: ResponseChannel

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> BridgeWriter {
        channel.deliverStreaming(response)
        return BridgeWriter(channel: channel)
    }

    consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        channel.deliverComplete(response, BridgeWriter.drain(&buffer))
    }
}

/// The bridge builder: a `HTTPServerRouteBuilder` whose reader/sender are the copyable bridge types.
/// It accumulates routes, then `apply(to:)` forwards each onto a `ServerTransport`.
private struct ServerTransportRouteBuilder: HTTPServerRouteBuilder {
    // The bridge is the top of its own stack, so it puts the courier on itself — the analogue of
    // `WireMVCContextHandler` on the proposal-native path.
    typealias RequestContext = WireMVCContext<BridgeRequestContext>
    typealias Reader = BridgeReader
    typealias ResponseSender = BridgeResponseSender

    typealias Handler =
        @Sendable (
            HTTPRequest,
            consuming WireMVCContext<BridgeRequestContext>,
            [String: Substring],
            consuming sending BridgeReader,
            consuming sending BridgeResponseSender
        ) async throws -> Void

    private struct Route {
        let method: HTTPRequest.Method
        let path: String
        let handler: Handler
    }

    private var routes: [Route] = []

    mutating func register(method: HTTPRequest.Method, path: String, handler: @escaping Handler) {
        routes.append(Route(method: method, path: path, handler: handler))
    }

    /// Forward each collected route onto a `ServerTransport`: the framework routes + provides path
    /// parameters; per request we fabricate a reader from the `HTTPBody?`, run the handler concurrently,
    /// and return the response head with either a known-length or a streaming body.
    consuming func apply(to transport: some ServerTransport) throws {
        for route in routes {
            let handler = route.handler
            try transport.register(
                { request, requestBody, metadata in
                    let channel = ResponseChannel()
                    // Unstructured by necessity: the handler produces the streamed body the transport
                    // consumes *after* this closure returns, so it can't be a structured child. For a
                    // streamed response its lifetime is bound to the returned body (see `StreamedResponseBody`);
                    // for a one-shot response it finishes before the closure returns.
                    let task = Task {
                        do {
                            try await handler(
                                request,
                                WireMVCContext(
                                    base: BridgeRequestContext(),
                                    responseHeaders: ResponseHeaderRegistry()
                                ),
                                metadata.pathParameters,
                                BridgeReader(requestBody),
                                BridgeResponseSender(channel: channel)
                            )
                            channel.handlerFinished()
                        } catch {
                            channel.handlerThrew(error)
                        }
                    }
                    // `Task {}` inherits task-locals and priority but **not** cancellation, so the
                    // handler has to be cancelled explicitly when the request is. Without this a client
                    // that disconnects before the head is sent leaves the handler running to completion
                    // for a response nobody will read — the streaming path is already covered further
                    // down (releasing the body releases `HandlerTaskHandle`, whose `deinit` cancels),
                    // but before a head exists there is no body to release.
                    let start = await withTaskCancellationHandler {
                        await channel.awaitStart()
                    } onCancel: {
                        task.cancel()
                    }
                    switch start {
                    case let .complete(head, responseBytes):
                        return (head, responseBytes.isEmpty ? nil : HTTPBody(Data(responseBytes)))
                    case let .streaming(head):
                        // Bind the handler task's lifetime to the streamed body: the `map` closure
                        // captures `handle`, so releasing the body (transport done / client disconnect)
                        // releases `handle`, whose `deinit` cancels the task.
                        let handle = HandlerTaskHandle(task)
                        let body = channel.body.map { chunk in withExtendedLifetime(handle) { chunk } }
                        return (head, HTTPBody(body, length: .unknown, iterationBehavior: .single))
                    case let .failed(error):
                        throw error
                    case .finishedWithoutResponse:
                        return (HTTPResponse(status: .internalServerError), nil)
                    }
                },
                method: route.method,
                path: route.path
            )
        }
    }
}

/// Serves proposal-native WireMVC controllers on a `ServerTransport`. The `ServerTransport`-era
/// counterpart to `WireMVC.apply(_:to:)` (which targets a `HTTPServerRouteBuilder` directly): a
/// Hummingbird/Vapor runtime uses this to serve the *same* controllers a proposal server does.
public enum WireMVCServerTransport {
    /// Register the graph's collated controllers onto a `ServerTransport` and return the graph's
    /// collated app-scoped `ServiceLifecycle` services to hand to `Application(services:)` / a
    /// `ServiceGroup`.
    @discardableResult
    public static func apply(
        _ graph: some WireMVCComposable,
        to transport: some ServerTransport
    ) throws -> [any Service] {
        var builder = ServerTransportRouteBuilder()
        let services = try WireMVC.apply(graph, to: &builder)
        try builder.apply(to: transport)
        return services
    }

    /// Register a `GET` endpoint serving the graph's wiring model (`introspect()`) as JSON onto a
    /// `ServerTransport`.
    public static func mountIntrospection(
        for graph: some Introspectable,
        on transport: some ServerTransport,
        at path: String = "/wiring"
    ) throws {
        var builder = ServerTransportRouteBuilder()
        try WireMVC.mountIntrospection(for: graph, into: &builder, at: path)
        try builder.apply(to: transport)
    }
}
#endif
