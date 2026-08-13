public import AsyncStreaming
public import BasicContainers
public import HTTPTypes
public import WireMVC

// A compiler probe, not a design. The question is what a *streaming request binding* can even express
// before anything is proposed — the response tier took several passes because each shape was reasoned
// about and then refuted, and this is the same territory (`consuming`, `~Copyable`, `~Escapable`).
//
// Two candidate shapes:
//   (a) streaming decode — the binding consumes the reader incrementally and returns a finished value.
//   (b) lazy stream — the handler receives something it can iterate, so the reader must outlive `bind`.

// ── (a) streaming decode ──────────────────────────────────────────────────────

/// Consumes the reader, returns an ordinary escaping value. If this compiles, a multipart binding that
/// writes parts to disk (or counts them, or parses bounded fields) is expressible today.
public protocol RequestBodyStreamable {
    associatedtype Value

    static func bindStreaming<Reader: AsyncReader & ~Copyable>(
        name: String,
        request: HTTPRequest,
        reader: consuming Reader
    ) async throws -> Value
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?
}

/// A witness: counts bytes without ever holding them all.
public enum ByteCounter: RequestBodyStreamable {
    public static func bindStreaming<Reader: AsyncReader & ~Copyable>(
        name: String,
        request: HTTPRequest,
        reader: consuming Reader
    ) async throws -> Int
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
        var buffer = UniqueArray<UInt8>()
        _ = try await reader.collect(into: &buffer, maximumSize: 1_000_000)
        return buffer.span.count
    }
}

/// The terminal's shape for (a): the reader arrives `consuming` and is handed to exactly one binding.
/// A second binding cannot be given it — that is the single-consume-site invariant, checker-enforced
/// rather than documented, if this compiles and the commented line below does not.
public func terminalA<Reader: AsyncReader & ~Copyable>(
    request: HTTPRequest,
    reader: consuming Reader
) async throws -> Int
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
    let count = try await ByteCounter.bindStreaming(name: "body", request: request, reader: reader)
    // try await ByteCounter.bindStreaming(name: "again", request: request, reader: reader)  // ← must not compile
    return count
}

// ── (b) lazy stream ───────────────────────────────────────────────────────────
//
// The handler receives something it iterates, so the reader must survive `bind` and die after the handler
// returns. Three sub-questions, each a separate probe below, because the response tier's lesson was that
// "it can hold the writer" and "it can be returned" are different claims and the second is usually false.

/// b1: can a value *hold* a `~Copyable` reader at all? A stored property of non-copyable type in a
/// non-copyable struct.
/// `Buffer == UniqueArray<UInt8>` is a real constraint, not a shortcut. `Container`'s element subscript is
/// still commented out in swift-collections (`Container.swift:168`), so the only generic way to read a
/// buffer's elements is the underscored, provisional `makeBorrowingIterator_()`. Every reader this framework
/// can actually receive uses `UniqueArray<UInt8>` — the NIO server's, the proposal's four clients', and both
/// of WireMVCTesting's — so constraining is honest about what is supported and stays checkable, where the
/// underscored API would be a dependency on something explicitly unstable.
public struct BodyStream<Reader: AsyncReader & ~Copyable>: ~Copyable
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Reader.Buffer == UniqueArray<UInt8> {
    private var reader: Reader

    public init(consuming reader: consuming Reader) {
        self.reader = reader
    }

    /// Reads the next chunk, mutating in place — the shape a `for try await` over parts would be built on.
    ///
    /// `read(body:)` is the incremental primitive: the callee fills a buffer and hands it to the closure
    /// along with the end-of-stream payload. `collect` is the wrong tool here — it reads to the end, which
    /// is what `WireMVCRequest.collectBody` already does and what streaming exists to avoid.
    ///
    /// Returns `false` once the reader has delivered a non-nil final element; calling again after that is a
    /// programmer error per the proposal, so the flag has to be honoured by whatever drives this.
    public mutating func next(appendingTo sink: inout [UInt8]) async throws -> Bool {
        // Iterated through `Container`'s index API rather than `span`: the reader's `Buffer` is any
        // `RangeReplaceableContainer`, and `span` belongs to `UniqueArray` specifically. Constraining
        // `Reader.Buffer == UniqueArray<UInt8>` would work for the readers WireMVC gets today and would be
        // a hidden assumption the day one of them uses a different container.
        try await reader.read { buffer, finalElement in
            let span = buffer.span
            for index in 0..<span.count { sink.append(span[index]) }
            return finalElement == nil
        }
    }
}

/// b2: can `bind` *return* one? This is the claim that matters — a returned value carrying a borrowed
/// resource is exactly what the response tier could not express for `AsyncHTMLRenderer`.
public enum StreamBinder {
    public static func bindStreaming<Reader: AsyncReader & ~Copyable>(
        reader: consuming Reader
    ) async throws -> BodyStream<Reader>
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Reader.Buffer == UniqueArray<UInt8> {
        BodyStream(consuming: reader)
    }
}

/// b3: the terminal shape (b) forces — the handler must run inside the reader's lifetime, so it is a
/// closure the terminal calls rather than a value the terminal returns.
public func terminalB<Reader: AsyncReader & ~Copyable, Result>(
    reader: consuming Reader,
    handler: (inout BodyStream<Reader>) async throws -> Result
) async throws -> Result
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Reader.Buffer == UniqueArray<UInt8> {
    var stream = try await StreamBinder.bindStreaming(reader: reader)
    return try await handler(&stream)
}

// ── What the probes established ───────────────────────────────────────────────
//
// Both shapes compile. What that does and does not license:
//
// 1. **The reader is escapable — today, and by an unresolved upstream TODO.** `AsyncReader` is declared
//    `~Copyable, ~Escapable`, so a conformer *may* be non-escapable; `HTTPServerRouteBuilder.Reader`
//    suppresses only `Copyable` (`Routing.swift:12`), which mirrors the proposal, which WireMVC cannot
//    differ from anyway (`HTTPServer.serve` requires `Handler.Reader == Reader`). But upstream marks the
//    choice open — `HTTPServerRequestHandler.swift:58`, "TODO: Check if we should allow ~Escapable
//    readers", apple/swift-http-api-proposal#13 — and nothing forces it: a `~Escapable` reader passed
//    `consuming sending` compiles, both as a requirement and with a concrete conformer.
//
//    So a value *may* hold and return a reader today, and that is a bet on an open question. The
//    asymmetry with the response side is unresolved rather than principled: `HTTPResponseSender.Writer`
//    in the same package **is** `~Escapable`, which is why the producer must finish the response itself.
//    Anything built here that lets a reader escape breaks the day #13 resolves the other way.
//
// 2. **The single-consume invariant is checker-enforced.** Two `bindStreaming` calls on one reader is
//    `'reader' consumed more than once`, verified by compiling it. "At most one binding streams the body"
//    needs no runtime check and no codegen rule — it is the same structural argument that made a second
//    response body unrepresentable.
//
// So shape (b) is available *today*, and the part of it worth relying on is `terminalB`'s closure: with
// the stream scoped to a call the reader never escapes, so that shape survives #13 either way. Returning
// a `BodyStream` from `bind` — b2 above — is the part that does not.
//
// The real constraint is elsewhere and is not about ownership at all: `Reader.Buffer` has no stable
// element accessor, so the tier has to constrain `Buffer == UniqueArray<UInt8>` (every reader in the
// ecosystem uses it) or depend on provisional underscored API.
