// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

public import AsyncStreaming
import BasicContainers
public import HTTPTypes

// The reader-body request tier — the mirror of `StreamingResponses.swift`, and much smaller than it.
//
// `RequestBound.bind` is handed `body: [UInt8]?`, collected whole by the terminal before any binding runs.
// That is right for a JSON payload and wrong for an upload: a `multipart/form-data` binding written against
// it must buffer the entire request in memory before it can look at the first part. The only alternative
// today is `@RawRoute(.reader)`, which gives up typed binding altogether.
//
// **The reader never escapes.** A reader binding consumes it and returns a finished value; nothing hands
// the reader, or anything holding it, back to the handler. That is a deliberate restriction rather than a
// limitation of what compiles — a value *can* hold and return a reader today, because
// `HTTPServerRequestHandler.Reader` suppresses only `Copyable`. But upstream marks that choice open
// ("TODO: Check if we should allow ~Escapable readers", apple/swift-http-api-proposal#13), and the same
// package's `HTTPResponseSender.Writer` already **is** `~Escapable`. Building the handler-facing half of
// this tier on the reader staying escapable would be betting the API on an unresolved question; consuming
// it here costs nothing that a real binding needs, and settles either way.
//
// So this tier answers "parse the body without holding it all" — multipart to disk, a checksum, a bounded
// field scan. Handing the handler a stream to iterate is the separate `.bodyStream` tier.

/// A binding that reads the request body **incrementally**, instead of being handed it whole.
///
/// Declared alongside ``RequestBound`` rather than refining it: a binding is one or the other, and the
/// generated terminal calls exactly one of `bind` / `bindReader` for a given parameter. Conforming to
/// both would make that choice ambiguous, which is why the obligation — not the conformance — decides.
///
/// Generic over the reader's `Buffer`, which is worth stating because the obvious alternative is a trap.
/// `Container`'s element *subscript* is commented out in swift-collections, so a first attempt constrained
/// `Buffer == UniqueArray<UInt8>` — true of every reader that exists. That constraint has to be satisfiable
/// where the generated code calls this, so it propagates to `HTTPServerRouteBuilder.Reader`, and from there
/// into every application generic over its server. `Container.nextSpan(after:maximumCount:)` is the stable
/// accessor that makes all of it unnecessary.
public protocol RequestBodyReading {
    /// The value handed to the handler parameter.
    associatedtype Value

    /// Consume the reader, producing the bound value.
    ///
    /// **The reader is consumed, so at most one binding on a route may stream.** That is not a rule this
    /// framework enforces: a second call is `'reader' consumed more than once` from the move-only checker.
    /// The codegen diagnoses the same thing earlier only so the message names the route rather than a line
    /// of generated code.
    ///
    /// The negative — that two calls really do fail — was checked by compiling it during development and is
    /// **not** machine-verified: this repo has no compile-failure harness, and asserting otherwise would be
    /// the same trap as a commented-out line that looks like a test.
    static func bindReader<Reader: AsyncReader & ~Copyable>(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        reader: consuming Reader,
        coding: WireMVCCoding
    ) async throws -> Value
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?
}

/// Reading a request body a chunk at a time, for bindings that do not want the whole thing.
///
/// The counterpart of ``WireMVCRequest/collectBody(_:maximumSize:)``, which every collecting (`.body`) binding
/// goes through. A binding may of course drive `reader.read(body:)` itself; this exists so the common
/// shape — "walk the body, accumulating something small" — does not require each binding to re-derive the
/// end-of-stream rule (a non-`nil` final element ends the stream, and reading again after it is a
/// programmer error per the proposal).
extension WireMVCRequest {
    /// Feed each chunk to `consume` until the body ends, then return `state`.
    ///
    /// `state` is `inout` rather than returned per chunk so a binding can accumulate into something that is
    /// not cheap to copy — a hasher, a file handle, a parser's partial state.
    public static func streamBody<Reader: AsyncReader & ~Copyable, State: ~Copyable>(
        _ reader: consuming Reader,
        into state: inout State,
        maximumSize: Int = 100_000_000,
        consume: (inout State, Span<UInt8>) throws -> Void
    ) async throws
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
        var reader = reader
        var total = 0
        var ended = false
        while !ended {
            do {
                // `read` hands back the callee's buffer and the end-of-stream payload together. A non-`nil`
                // final element marks *this* chunk as the last one — its buffer may still hold bytes, so
                // the consume happens before the loop exits, not after it.
                ended = try await reader.read { buffer, finalElement in
                    total += buffer.count
                    guard total <= maximumSize else { throw WireMVCBindingError.malformedBody }
                    // `nextSpan` rather than a `Buffer`-specific accessor: a container may hold its contents
                    // in several chunks, so one call is not guaranteed to cover the buffer and the walk has
                    // to loop until the index reaches the end.
                    var index = buffer.startIndex
                    while index != buffer.endIndex {
                        try consume(&state, buffer.nextSpan(after: &index, maximumCount: .max))
                    }
                    return finalElement != nil
                }
            } catch {
                // The bound `error` is the `EitherError<Reader.ReadFailure, any Error>` `read` declares —
                // it is the only throwing call in the `do`, so its typed throw is the block's, and naming
                // the type in the pattern was a cast that could not fail.
                //
                // **Unwrapped, deliberately.** `read` reports both a transport failure and anything the
                // consume closure threw as one `EitherError`, and a wrapped error is invisible to
                // `@ErrorResponse(MyError.self, …)`: a route can only map a type it can name. Letting the
                // wrapper escape would make every reader binding's own errors unmappable — the same
                // defect a codec that leaks its parser's error type has.
                try error.unwrap()
            }
        }
    }
}

// MARK: - The lent-stream tier

/// A stream a `.bodyStream` binding lends to the handler, and the one thing WireMVC requires of it: that
/// it can refuse a request it cannot be produced from, *before* the terminal commits to a response.
///
/// **Construction stays a spelling; validation does not, and the distinction is the whole of this
/// protocol.** The terminal builds the stream by writing `MultipartParts(request: request, reader: reader)`,
/// read off `@RequestBinding(stream:)` rather than called through a requirement, because the stream's type
/// depends on the reader and a protocol's `associatedtype` is fixed by the conformance before any reader
/// exists. That reasoning covers the *initialiser* and nothing else. Whether the request can produce this
/// stream at all — a `Content-Type` that is not `multipart/form-data`, a missing boundary — involves no
/// reader, so it can be a requirement; the only reason it was not one is that the tier had nowhere to
/// state it.
///
/// **Why it has to be one.** A non-throwing initialiser defers its check to whatever the handler calls
/// first, and on today's tiers that is harmless: the handler runs before the head goes out, so a throw from
/// `withParts` maps through `@ErrorResponse` exactly as a decode failure does. The duplex shape inverts
/// that — the handler holds the response and runs *after* the head — so the same deferred check would
/// truncate a response that had already claimed a status, instead of mapping to 415. The check belongs
/// where every other binding's does: inside `building`, before the terminal has committed to anything.
///
/// This is why the requirement lands now rather than with the feature it serves. It changes a **public**
/// binding protocol — every lent stream anyone writes conforms — which is a mechanical sweep before 1.0
/// and a break after it. `@RequestBinding(.bodyStream)`'s duplex half is paused on
/// [swiftlang/swift#91473](https://github.com/swiftlang/swift/issues/91473); this half is on 1.0's
/// schedule, not that bug's. The `.readerBody` tier already checks up front — ``RequestBodyReading``'s
/// `bindReader` throws before it reads a byte — so what this does is give the two request-streaming tiers
/// the same order of operations rather than inventing one.
///
/// The generated terminal binds and then validates, one statement later and still inside `building`:
///
///     let parts = MultipartParts(request: request, reader: reader)
///     try parts.validateRequest()
///
/// **An instance method, and `borrowing`.** A static `validate(request:)` cannot be called from generated
/// code: the stream type is spelled with no type argument — that is what lets a witness name a
/// reader-dependent type at all — so `MultipartParts.validate(…)` leaves `Reader` uninferred. On the
/// constructed value the type is already settled. Borrowing rather than consuming leaves the stream whole
/// to be lent on, so validating costs the route nothing but the check.
public protocol LentBodyStream: ~Copyable, ~Escapable {
    /// Refuse a request this stream cannot be produced from.
    ///
    /// Throw in the binding's **own** vocabulary — a type the route can name in `@ErrorResponse`, the way
    /// `MultipartBindingError.notMultipart` is what a route naming `MultipartBindingError` maps. An error
    /// from a layer underneath is an unmapped 500, which is the same trap ``RequestBodyReading`` documents
    /// for the reader tier.
    ///
    /// Called once per request, immediately after construction. It is not a substitute for the checks a
    /// stream makes while reading — a malformed delimiter is not knowable here — only for the ones it can
    /// make from the request alone.
    borrowing func validateRequest() throws
}

extension LentBodyStream where Self: ~Copyable & ~Escapable {
    /// Defaulted, so a stream with nothing to check from the request alone conforms with an empty
    /// extension and says nothing. The requirement exists to give the check a *place*, not to insist every
    /// stream has one — the same reason ``RequestBound``'s coding-aware `bind` is defaulted rather than
    /// required.
    public borrowing func validateRequest() throws {}
}
