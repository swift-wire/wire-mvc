// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import AsyncStreaming
import BasicContainers
public import HTTPAPIs
public import HTTPTypes

// Answering `HEAD`: the response a `GET` would give, without its content (RFC 9110 §9.3.2).
//
// The router answers a `HEAD` from the path's `GET` route when there is no `HEAD` route, so the handler that
// runs writes its usual response — a buffered body, a streamed one, or whatever a `@RawRoute` writes. The
// body has to go somewhere other than the wire, and what a server does with one varies:
//
// - swift-http-server over HTTP/1.1 pairs each response with its request's method and rejects body writes on
//   a response to `HEAD`. The rejection is not surfaced through its async writer, so the bytes are dropped
//   silently and the framing stays correct — measured: the fixture's pipelined `HEAD` + `GET` exchange
//   passes with this wrapper disabled.
// - Over HTTP/2, swift-nio-http2 expects a response to `HEAD` to carry zero bytes and treats DATA beyond
//   that as a content-length violation, which fails the stream — read from its `ContentLengthVerifier`.
// - The in-process test transport and a `ServerTransport` host have no notion of it at all: with this
//   wrapper disabled, every in-process `HEAD` fixture test sees the `GET`'s body.
//
// So the body is dropped here, once, rather than left to whichever server happens to be underneath — and one
// place drops it for every kind of route: the sender every route on the native path is handed. It is
// this wrapper, put on by ``WireMVCContextHandler`` beside ``WireMVCRequestReader``, and it knows the
// request's method because the handler that makes it does. Nothing above it — the router, a typed terminal,
// a raw handler, a middleware wrapping the sender — needs to know the request was a `HEAD`.

/// The response sender a route is handed: the server's own, with the response body withheld when the request
/// was a `HEAD`.
///
/// For any other method it forwards every call unchanged. For a `HEAD` it forwards the **head** unchanged —
/// status, fields, and the `Content-Length` a `GET` would have stated — and drops the body:
///
/// - ``sendAndFinish(_:buffer:trailer:)`` states the length of the body it was handed, as the buffered path
///   always does, then sends the head with none. A field already present wins, as everywhere else, which is
///   what keeps a route's own `Content-Length` — the length of the `GET`'s content, not of what is written.
/// - ``send(_:)`` sends the head and hands back a writer that discards what is written and finishes the
///   response with nothing, so a streaming producer or a raw route's writes complete normally.
///
/// Trailers are dropped with the body: a bodiless response has no chunked framing for them to ride on.
public struct WireMVCResponseSender<Base: HTTPResponseSender & ~Copyable>: HTTPResponseSender, ~Copyable
where Base.Writer: ~Copyable {
    public typealias Writer = WireMVCResponseWriter<Base.Writer>

    var base: Base

    /// Whether the body is withheld — the request was a `HEAD`.
    public let omitsBody: Bool

    public init(wrapping base: consuming Base, omitsBody: Bool) {
        self.base = base
        self.omitsBody = omitsBody
    }

    /// The sender for a request: one that withholds the body when `request` is a `HEAD`.
    public init(wrapping base: consuming Base, answering request: HTTPRequest) {
        self.init(wrapping: base, omitsBody: request.method == .head)
    }

    public mutating func sendInformational(_ response: HTTPResponse) async throws {
        try await base.sendInformational(response)
    }

    public consuming func send(_ response: HTTPResponse) async throws -> Writer {
        let omitsBody = self.omitsBody
        let inner = consume self.base
        return WireMVCResponseWriter(base: try await inner.send(response), omitsBody: omitsBody)
    }

    public consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        let inner = consume self.base
        guard omitsBody else {
            try await inner.sendAndFinish(response, buffer: &buffer, trailer: trailer)
            return
        }
        var head = response
        // The length the `GET` would have stated. With a trailer the `GET` would have been chunked and stated
        // none, so neither does this.
        if trailer == nil { head.stateLengthIfAbsent(buffer.count) }
        var nothing = UniqueArray<UInt8>()
        try await inner.sendAndFinish(head, buffer: &nothing, trailer: nil)
    }
}

/// The body writer ``WireMVCResponseSender`` hands back: the server's own, or — for a `HEAD` — one that
/// discards every write and finishes the response with nothing.
public struct WireMVCResponseWriter<Base: CallerAsyncWriter & ~Copyable>: CallerAsyncWriter, ~Copyable
where Base.WriteElement == UInt8, Base.FinalElement == HTTPFields? {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = Base.WriteFailure
    public typealias FinalElement = HTTPFields?

    var base: Base
    let omitsBody: Bool

    init(base: consuming Base, omitsBody: Bool) {
        self.base = base
        self.omitsBody = omitsBody
    }

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(WriteFailure) where Buffer.Element: ~Copyable {
        guard omitsBody else {
            try await base.write(buffer: &buffer)
            return
        }
        // Drained as a write would drain it, so a caller that reuses its buffer sees what it always sees.
        buffer.removeAll()
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming HTTPFields?
    ) async throws(WriteFailure) where Buffer.Element: ~Copyable {
        let inner = consume self.base
        guard omitsBody else {
            try await inner.finish(buffer: &buffer, finalElement: finalElement)
            return
        }
        buffer.removeAll()
        var nothing = UniqueArray<UInt8>()
        try await inner.finish(buffer: &nothing, finalElement: nil)
    }
}
