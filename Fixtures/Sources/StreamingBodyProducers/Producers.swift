public import AsyncStreaming
import BasicContainers
public import HTTPTypes
public import WireMVC

// Test producers for WireMVC's streaming response tier (`WireMVC/StreamingResponses.swift`). They exist so
// the suite can drive the *shipped* tier over synthetic bodies — fixed chunks, a mid-body failure, a gated
// tail — with no HTML library in the way. The tier itself is no longer duplicated here; these are
// producers, nothing more.

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
