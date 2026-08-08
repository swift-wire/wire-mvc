public import AsyncStreaming
import BasicContainers
public import HTTPAPIs
public import HTTPTypes
public import WireMVC

// The prototype of the streaming response tier proposed in
// `Documentation/Notes/StreamingResponseTier.md`, exercised end to end with a `ChunkProducer` body — no
// Elementary dependency, deliberately, so the tier's design is validated independently of whether
// Elementary's renderer can be made non-escapable.
//
// It composes with the **real** `WireMVCOutcome`: the buffered tier is untouched by this design, and the
// terminal below is the one place the two meet. That is the whole claim being tested.
//
// Not wired into any route yet — there is no `@HTMLResponse`/streaming route kind in `RouteCodegen`. This
// target exists to keep the runtime half compiling and passing while that codegen work is done.

// ─────────────────────────────────────────────────────────────────────────────
// The producer
// ─────────────────────────────────────────────────────────────────────────────

/// A description of a body that is written incrementally.
///
/// **No `Sendable` requirement**, deliberately. The producer never escapes the terminal's region — it is
/// built and consumed in a single statement — and requiring `Sendable` would be the sole reason a
/// non-`Sendable` body value (an Elementary `some HTML` capturing a model object) would need an erasure box.
/// `StreamingTierPrototypeTests` pins that: adding `: Sendable` here breaks `NonSendableProducer`.
///
/// The writer arrives as a `consuming` generic parameter, and the producer **terminates the response
/// itself** by calling `finish` with the trailer it is handed.
///
/// That division of labour is forced, not chosen. A `~Escapable` writer cannot be held in a struct field,
/// so it cannot be passed by an escaping borrow; and handing it *back* — `write(into:) -> W` — makes the
/// return value lifetime-dependent on an argument, which the checker cannot trace across a protocol witness
/// once the value has passed through an intermediary (`lifetime-dependent value escapes its scope`). Letting
/// the producer finish keeps every lifetime-dependent value inside one function body, and needs no
/// `@_lifetime` annotation anywhere in the tier.
///
/// The cost is that a producer which forgets to `finish` leaves the response unterminated — which, per the
/// proposal, aborts it. That is the same outcome as a mid-body throw, so the failure mode is at least
/// consistent, but it is a real obligation and the name is doing the work of saying so.
public protocol WireMVCBodyProducer {
    consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields?
}

// ─────────────────────────────────────────────────────────────────────────────
// The streaming outcome
// ─────────────────────────────────────────────────────────────────────────────

/// The new tier: status and header fields resolve normally, the body is produced incrementally.
///
/// Generic over the *concrete* producer, inferred at its single construction site in the terminal. It
/// appears in no user-written signature — the property an existential arm on `WireMVCOutcome` was reaching
/// for, without the erasure, and without forcing `Sendable` on the body.
public struct WireMVCStreamingOutcome<Producer: WireMVCBodyProducer> {
    public var status: HTTPResponse.Status
    public var headerFields: HTTPFields
    public var producer: Producer
    /// Trailing fields — where a post-head contribution goes, now that the header fold has already run.
    public var trailer: HTTPFields?

    public init(
        status: HTTPResponse.Status,
        headerFields: HTTPFields = [:],
        producer: Producer,
        trailer: HTTPFields? = nil
    ) {
        self.status = status
        self.headerFields = headerFields
        self.producer = producer
        self.trailer = trailer
    }

    /// Sends the head, hands the writer to the producer, then finishes.
    ///
    /// Deliberately `throws`: a mid-body failure propagates to the framework, and the writer is dropped
    /// without `finish` — which per the proposal aborts the response, the honest wire signal for a truncated
    /// body. Nothing is swallowed, and nothing pretends a post-head error can become a status code.
    public consuming func send<Sender: HTTPResponseSender & ~Copyable>(
        on sender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        let writer = try await sender.send(HTTPResponse(status: status, headerFields: headerFields))
        try await producer.writeBody(into: writer, terminatedBy: trailer)
    }
}

/// The terminal-local discriminant. Never named by a user; inferred at one construction site.
public enum WireMVCTerminalOutcome<Producer: WireMVCBodyProducer> {
    case stream(WireMVCStreamingOutcome<Producer>)
    case buffered(WireMVCOutcome)
}

// ─────────────────────────────────────────────────────────────────────────────
// The terminal — what RouteCodegen would emit for a streaming route
// ─────────────────────────────────────────────────────────────────────────────

/// Mirrors the generated terminal shape: **discriminate inside the `do`/`catch`, consume the sender once,
/// outside it.** This preserves the single-consume-site invariant the buffered terminal already maintains
/// (`RouteCodegen.swift:496-502`) rather than departing from it.
///
/// The alternative — sending inside the `do` — does not compile: the ownership checker reports
/// `'responseSender' consumed more than once`, because the throwing send inside the `do` can reach the
/// `catch`. The soundness rule is the checker's, not this design's, and
/// `StreamingTierPrototypeTests` records the negative check.
public func wireMVCStreamingTerminal<Producer: WireMVCBodyProducer, Sender: HTTPResponseSender & ~Copyable>(
    responseSender: consuming Sender,
    status: HTTPResponse.Status = .ok,
    headerFields: HTTPFields = [:],
    trailer: HTTPFields? = nil,
    handler: () async throws -> Producer,
    errorMapping: (any Error) -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable {
    let wireMVCResult: WireMVCTerminalOutcome<Producer>
    do {
        wireMVCResult = .stream(
            WireMVCStreamingOutcome(
                status: status,
                headerFields: headerFields,
                producer: try await handler(),
                trailer: trailer
            )
        )
    } catch let wireMVCError {
        wireMVCResult = .buffered(errorMapping(wireMVCError))
    }
    switch wireMVCResult {
    case .stream(let streaming):
        try await streaming.send(on: responseSender)
    case .buffered(let buffered):
        try await buffered.send(on: responseSender)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Producers
// ─────────────────────────────────────────────────────────────────────────────

/// The prototype's stand-in for a rendered HTML body: fixed chunks, written one at a time.
public struct ChunkProducer: WireMVCBodyProducer {
    public let chunks: [[UInt8]]

    public init(_ chunks: [String]) { self.chunks = chunks.map { Array($0.utf8) } }

    public consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        var writer = writer
        for chunk in chunks {
            var buffer = UniqueArray<UInt8>(copying: chunk)
            try await writer.write(buffer: &buffer)
        }
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: trailer)
    }
}

/// Writes some chunks, then throws — the mid-body failure case, which cannot become a status code.
public struct FailingProducer: WireMVCBodyProducer {
    public let before: [[UInt8]]
    public let failure: any Error

    public init(before: [String], failure: any Error) {
        self.before = before.map { Array($0.utf8) }
        self.failure = failure
    }

    public consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        var writer = writer
        for chunk in before {
            var buffer = UniqueArray<UInt8>(copying: chunk)
            try await writer.write(buffer: &buffer)
        }
        throw failure
    }
}

/// Writes a chunk, awaits an external signal, then writes the rest — used to prove the head and the first
/// chunk are observable *while the producer is still running*, which is what "streaming" has to mean. A
/// buffered implementation would deadlock this rather than pass it.
public struct GatedProducer: WireMVCBodyProducer {
    public let first: [UInt8]
    public let rest: [UInt8]
    public let gate: StreamGate

    public init(first: String, rest: String, gate: StreamGate) {
        self.first = Array(first.utf8)
        self.rest = Array(rest.utf8)
        self.gate = gate
    }

    public consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        var writer = writer
        var head = UniqueArray<UInt8>(copying: first)
        try await writer.write(buffer: &head)
        await gate.wait()
        var tail = UniqueArray<UInt8>(copying: rest)
        try await writer.write(buffer: &tail)
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: trailer)
    }
}

/// A one-shot async gate the test opens once it is satisfied the early bytes are already out.
public final class StreamGate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init() {
        var continuation: AsyncStream<Void>.Continuation!
        self.stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func open() { continuation.finish() }
    public func wait() async { for await _ in stream {} }
}
