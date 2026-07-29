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
// The point of ``InProcessServer`` is that it is a real ``HTTPServer``: the generated `.inProcess` build
// path passes it to the app's own `createRouteBuilder(for:)`, so the suite exercises the app's *actual*
// router, middleware fold, error tiers and `@NotFound` fallback — only the transport underneath differs.
// `serve(handler:)` is never called on it; the driver invokes `handle` per request instead.
//
// These types are ordinary *copyable* structs. `AsyncReader`/`HTTPResponseSender`/`CallerAsyncWriter` are
// declared `~Copyable`/`~Escapable`, but that *relaxes* the constraint for conformers rather than
// requiring it — the same latitude `WireMVCServerTransport`'s bridge types take. They are also `Sendable`
// (their only storage is a `Sendable` sink), so handing them to `handle`'s `consuming sending` parameters
// needs no region gymnastics.

/// The in-process server: an ``HTTPServer`` whose request context, body reader, and response sender are
/// the in-memory types below. It exists so the generated `.inProcess` build path can call the app's
/// `createRouteBuilder(for:)` — and therefore build the app's real router over the in-memory types.
/// It never serves; ``WireMVCTesting/driveInProcess(handler:services:runTests:)`` drives the finalized
/// handler directly.
public struct InProcessServer: HTTPServer {
    public typealias RequestContext = InProcessRequestContext
    public typealias Reader = InProcessReader
    public typealias ResponseSender = InProcessResponseSender

    public init() {}

    /// Not a serving transport — the in-process driver calls `handle` per request instead. Reaching this
    /// means an in-process build path was handed to a serving helper (`WireMVC.serve` /
    /// `WireMVCTesting.serveForSuite`) rather than to the driver.
    public func serve<Handler: HTTPServerRequestHandler>(handler: Handler) async throws
    where
        Handler.RequestContext: ~Copyable,
        Handler.RequestContext == RequestContext,
        Handler.Reader == Reader,
        Handler.Reader: ~Copyable,
        Handler.ResponseSender == ResponseSender,
        Handler.ResponseSender: ~Copyable
    {
        throw WireMVCTestingError.inProcessServerCannotServe
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

    init(sink: ResponseSink) { self.sink = sink }

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
