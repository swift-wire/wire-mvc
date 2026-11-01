// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes

// Reading what a route leaves of its request body, once the route is done.
//
// Most routes never touch the reader — a `GET` has no body to bind, so the generated register closure
// binds it `_` — and a route that does may stop part-way, refusing a body it has decided against. Either
// way the server is left with a request it has not seen the end of, and that is not free: swift-http-server
// hands a connection back to its keep-alive loop only from a reader that has read the request's end. A
// handler that returns without one ends the loop, the connection is closed, and whatever of the response is
// still queued behind the socket is dropped with it. A small response is already in the kernel's buffer by
// then; a large one — an image, a file, a long JSON array — arrives cut short under a `Content-Length` that
// promised the rest, at a different point each time.
//
// So the reader every route is handed is this wrapper, sharing its state with ``WireMVCContextHandler``,
// which reads the rest of the body through it once the route returns. For a bodiless request that is one
// read that answers "ended" at once.

/// The request body reader a route is handed: the server's own, through a reference the per-request
/// handler keeps, so the handler can finish reading a body the route left unread.
///
/// It forwards each read unchanged, and notes when the body has ended so the handler does not read past
/// it — reading again after the final element is a programmer error per the proposal.
public struct WireMVCRequestReader<Base: AsyncReader & ~Copyable>: AsyncReader, ~Copyable
where Base.ReadElement == UInt8, Base.FinalElement == HTTPFields? {
    public typealias ReadElement = UInt8
    public typealias Buffer = Base.Buffer
    public typealias ReadFailure = Base.ReadFailure
    public typealias FinalElement = HTTPFields?

    let body: RequestBody<Base>

    init(_ body: RequestBody<Base>) {
        self.body = body
    }

    public mutating func read<Return: ~Copyable, Failure: Error>(
        body consume: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        try await body.read(consume)
    }
}

/// The server's reader and whether its body has ended, shared between the route's
/// ``WireMVCRequestReader`` and the handler that drains what the route leaves.
///
/// A class because both hold it: the route's reader is `sending`, so it cannot share anything with the
/// handler's frame unless what it shares is `Sendable`. `@unchecked` on the same terms as the bridge's own
/// per-request state — the two never touch it at once, because the handler reads only after the route
/// has returned.
final class RequestBody<Base: AsyncReader & ~Copyable>: @unchecked Sendable
where Base.ReadElement == UInt8, Base.FinalElement == HTTPFields? {
    /// How much of an unread body the handler reads before giving up on the connection. A body the route
    /// refused for its size is not worth receiving whole just to keep the connection open, and a client
    /// still sending past this has its connection closed — what happened to every request before.
    static var drainLimit: Int { 1 << 20 }

    private var reader: Base
    private(set) var ended = false

    init(_ reader: consuming sending Base) {
        self.reader = reader
    }

    func read<Return: ~Copyable, Failure: Error>(
        _ consume: (inout Base.Buffer, consuming HTTPFields??) async throws(Failure) -> Return
    ) async throws(EitherError<Base.ReadFailure, Failure>) -> Return {
        try await reader.read { (buffer, finalElement) async throws(Failure) -> Return in
            if finalElement != nil { ended = true }
            return try await consume(&buffer, finalElement)
        }
    }

    /// Read and discard the rest of the body, up to ``drainLimit``. A failure to read ends it quietly: the
    /// route has answered, and a connection that cannot be read is one the server closes anyway.
    func drain() async {
        var drained = 0
        while !ended, drained <= Self.drainLimit {
            do {
                try await read { (buffer, _) async throws(Never) in drained += buffer.count }
            } catch {
                return
            }
        }
    }
}
