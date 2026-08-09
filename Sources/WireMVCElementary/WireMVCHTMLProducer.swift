#if Elementary
public import AsyncStreaming
// Re-exported so a controller writing HTML needs only `import WireMVCElementary` — the same courtesy
// `WireMVC/Exports.swift` extends for the proposal's HTTP types.
@_exported public import Elementary
public import HTTPTypes
public import WireMVC

import BasicContainers

// What `@HTMLResponse` resolves against. The generated terminal emits `WireMVCHTMLProducer(<handler call>)`
// into the *controller's* module, so this name is looked up against whatever adapter that module imports —
// WireMVC's core never mentions Elementary. A different HTML library can supply a `WireMVCHTMLProducer` of
// its own and `@HTMLResponse` keeps working unchanged.

/// Bridges the proposal's `CallerAsyncWriter` to Elementary's `HTMLStreamWriter`.
///
/// Non-copyable *and* non-escapable, because the writer it owns is both. Moving a non-escapable value does
/// not extend its lifetime, so the adapter inherits the writer's bound even though it owns it. It takes
/// ownership and hands the writer back via ``taken()`` — the consume-and-return shape Elementary's
/// `render(intoOwned:)` uses, and for the same reason: a mutable borrow of an arbitrary non-copyable type
/// is not storable in a struct.
public struct ProposalHTMLStreamWriter<Writer: CallerAsyncWriter & ~Copyable & ~Escapable>: HTMLStreamWriter,
    ~Copyable, ~Escapable
where Writer.WriteElement == UInt8 {
    @usableFromInline
    var writer: Writer

    // `copy` names copying the *lifetime dependency*, not the value — this adapter inherits whatever bound
    // `writer` carries. The compiler will not infer between `borrow` and `copy`.
    @_lifetime(copy writer)
    public init(writer: consuming Writer) {
        self.writer = writer
    }

    public mutating func write(_ bytes: ArraySlice<UInt8>) async throws {
        var buffer = UniqueArray<UInt8>(copying: Array(bytes))
        try await writer.write(buffer: &buffer)
    }

    /// Hand the writer back, so the body can be terminated.
    @_lifetime(copy self)
    public consuming func taken() -> Writer {
        writer
    }
}

/// A ``WireMVCBodyProducer`` whose body is Elementary HTML, rendered straight into the response body writer
/// with no intermediate buffer.
///
/// Holds the HTML value without requiring it to be `Sendable` — the tier imposes no such constraint, which
/// is what lets a page capture a request-scoped model object without an erasure box.
public struct WireMVCHTMLProducer<Content: HTML>: WireMVCBodyProducer {
    public let content: Content

    /// The maximum size of a written chunk. Elementary's default; a page smaller than this still streams,
    /// it simply completes in one write.
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
        // function body, so no lifetime-dependent value crosses a function boundary. Returning the writer
        // from here instead would fail: the checker cannot trace `writer → adapter → returned writer` back
        // to the argument across the protocol witness.
        let adapter = try await content.render(
            intoOwned: ProposalHTMLStreamWriter(writer: writer),
            chunkSize: chunkSize
        )
        var writer = adapter.taken()
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: trailer)
    }
}

/// The `Content-Type` an HTML route sends unless it says otherwise. Charset included, unlike
/// `WireMVCOutcome.json`'s bare `application/json`: a browser sniffs an HTML body without it.
public let wireMVCHTMLContentType = "text/html; charset=utf-8"
#endif
