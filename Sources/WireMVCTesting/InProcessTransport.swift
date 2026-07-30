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

    /// Carries the dispatch from `serve` (running in the suite's serving child task) to the client the
    /// driver builds. A reference, so the copyable server value can be handed around freely.
    let dispatch = InProcessDispatch()

    public init() {}

    /// Publish a dispatch over `handler`, then park until cancelled — the in-memory analogue of a real
    /// server holding a listening socket open for the suite's lifetime. Each dispatched request builds the
    /// four arguments `handle` takes, runs it, and reads back what the sender captured.
    public func serve<Handler: HTTPServerRequestHandler>(handler: Handler) async throws
    where
        Handler.RequestContext: ~Copyable,
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.Reader: ~Copyable,
        Handler.ResponseSender == ResponseSender,
        Handler.ResponseSender: ~Copyable
    {
        dispatch.install { request, body in
            let sink = ResponseSink()
            try await handler.handle(
                request: request,
                requestContext: InProcessRequestContext(),
                reader: InProcessReader(body),
                responseSender: InProcessResponseSender(sink: sink)
            )
            return sink.response
        }
        // Serving ends only when the suite cancels it, exactly as a socket-backed `serve` does.
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }
}

/// The one-shot channel carrying the request dispatch from ``InProcessServer/serve(handler:)`` to the
/// ``TestClient`` the driver builds. The two race — serving runs in a child task while the driver builds
/// the client — so a client asked for before `serve` has installed suspends until it has.
final class InProcessDispatch: Sendable {
    /// One request: the head and body in, the handler's response out (`nil` if it never responded).
    typealias Dispatch = @Sendable (HTTPRequest, [UInt8]) async throws -> (head: HTTPResponse, body: [UInt8])?

    private enum State {
        case waiting([CheckedContinuation<Dispatch, Never>])
        case installed(Dispatch)
    }

    private let state = Mutex<State>(.waiting([]))

    /// Publish the dispatch, waking anything already waiting for it.
    func install(_ dispatch: @escaping Dispatch) {
        let waiting: [CheckedContinuation<Dispatch, Never>] = state.withLock { state in
            defer { state = .installed(dispatch) }
            guard case let .waiting(continuations) = state else { return [] }
            return continuations
        }
        for continuation in waiting { continuation.resume(returning: dispatch) }
    }

    /// The installed dispatch, suspending until `serve` publishes one.
    var current: Dispatch {
        get async {
            await withCheckedContinuation { continuation in
                let installed: Dispatch? = state.withLock { state in
                    switch state {
                    case let .installed(dispatch):
                        return dispatch
                    case var .waiting(continuations):
                        continuations.append(continuation)
                        state = .waiting(continuations)
                        return nil
                    }
                }
                if let installed { continuation.resume(returning: installed) }
            }
        }
    }
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

/// The response the handler wrote, accumulated as it wrote it. A `Sendable` reference so it outlives the
/// `consuming` sender and writer threaded through the handler chain: the driver reads it once `handle`
/// returns. In-process responses are buffered whole — a streaming `@RawRoute` still *runs*, but its
/// incremental framing and backpressure are only observable on a live mode.
final class ResponseSink: Sendable {
    private struct State {
        var head: HTTPResponse?
        var body: [UInt8] = []
        var trailers: HTTPFields?
    }

    private let state = Mutex(State())

    /// Record the final response head. Informational (1xx) responses are dropped — nothing in-process
    /// observes them.
    func setHead(_ response: HTTPResponse) {
        state.withLock { $0.head = response }
    }

    func appendBody(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        state.withLock { $0.body.append(contentsOf: bytes) }
    }

    func finish(body: [UInt8], trailers: HTTPFields?) {
        state.withLock {
            $0.body.append(contentsOf: body)
            $0.trailers = trailers
        }
    }

    /// The head and body the handler produced, or `nil` for a handler that returned without responding.
    var response: (head: HTTPResponse, body: [UInt8])? {
        state.withLock { state in
            state.head.map { ($0, state.body) }
        }
    }
}

/// The in-process `HTTPResponseSender`. `sendAndFinish` (the typed-route path) records head and body in
/// one step; `send(_:)` (the raw/streaming path) records the head and hands back a writer that appends.
public struct InProcessResponseSender: HTTPResponseSender {
    public typealias Writer = InProcessWriter

    let sink: ResponseSink

    public mutating func sendInformational(_ response: HTTPResponse) async throws {}

    public consuming func send(_ response: HTTPResponse) async throws -> InProcessWriter {
        sink.setHead(response)
        return InProcessWriter(sink: sink)
    }

    public consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        sink.setHead(response)
        sink.finish(body: drainBytes(&buffer), trailers: trailer)
    }
}

/// The in-process body writer — appends each written chunk to the sink. Nothing can fail, so
/// `WriteFailure` is `Never`; nothing suspends, so a writer under backpressure in production streams
/// freely here.
public struct InProcessWriter: CallerAsyncWriter {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = Never
    public typealias FinalElement = HTTPFields?

    let sink: ResponseSink

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        sink.appendBody(drainBytes(&buffer))
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        sink.finish(body: drainBytes(&buffer), trailers: finalElement)
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
