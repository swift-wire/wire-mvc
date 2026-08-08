public import AsyncStreaming
public import Elementary
public import HTTPTypes

import BasicContainers

// Renders Elementary HTML straight into the proposal's response body writer — the end-to-end proof that
// WireMVC can stream HTML, using the `escapable-stream-writer` fork of Elementary.

/// Bridges the proposal's `CallerAsyncWriter` to Elementary's `HTMLStreamWriter`.
///
/// Non-copyable *and* non-escapable, because the writer it owns is both: moving a non-escapable value does
/// not extend its lifetime, so the adapter inherits the bound. It takes ownership and hands the writer back
/// via ``taken()`` — the same consume-and-return shape Elementary's `render(intoOwned:)` uses, and for the
/// same reason: a mutable borrow of an arbitrary non-copyable type is not storable in Swift 6.4.
public struct ProposalHTMLStreamWriter<Writer: CallerAsyncWriter & ~Copyable & ~Escapable>: HTMLStreamWriter,
    ~Copyable, ~Escapable
where Writer.WriteElement == UInt8 {
    @usableFromInline
    var writer: Writer

    @_lifetime(copy writer)
    public init(writer: consuming Writer) {
        self.writer = writer
    }

    public mutating func write(_ bytes: ArraySlice<UInt8>) async throws {
        var buffer = UniqueArray<UInt8>(copying: Array(bytes))
        try await writer.write(buffer: &buffer)
    }

    /// Hand the writer back, so the caller can still terminate the response.
    @_lifetime(copy self)
    public consuming func taken() -> Writer {
        writer
    }
}

/// A `WireMVCBodyProducer` whose body is Elementary HTML.
///
/// The HTML value is held in Elementary's own `_SendableAnyHTMLBox`-adjacent position — here simply stored,
/// since the tier imposes no `Sendable` requirement on producers (see `WireMVCBodyProducer`).
public struct ElementaryProducer<Content: HTML>: WireMVCBodyProducer {
    public let content: Content
    public let chunkSize: Int

    public init(_ content: Content, chunkSize: Int = 1024) {
        self.content = content
        self.chunkSize = chunkSize
    }

    public consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        // Render into the adapter, take the proposal writer back, and terminate — all inside this one
        // function body, so no lifetime-dependent value crosses a function boundary.
        let adapter = try await content.render(
            intoOwned: ProposalHTMLStreamWriter(writer: writer),
            chunkSize: chunkSize
        )
        let writer = adapter.taken()
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: trailer)
    }
}
