// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import AsyncStreaming
import BasicContainers
public import HTTPAPIs
public import HTTPTypes

// The streaming response tier — a typed route whose status and header fields resolve normally but whose
// body is produced incrementally. See `Documentation/Notes/StreamingResponseTier.md` for the design and
// for why each shape here is the one that compiles.
//
// It sits alongside ``WireMVCOutcome`` rather than inside it. The buffered tier is untouched: gates, the
// header registry, `@ErrorResponse` mappings and the generated typed client all still see exactly the
// non-generic `WireMVCOutcome` they saw before.

/// A description of a body that is written incrementally.
///
/// The producer **terminates the response itself**, calling `finish` with the trailer it is handed. That
/// division of labour is forced rather than chosen: a `~Escapable` writer cannot be held in a struct field,
/// so it cannot be passed by an escaping borrow; and handing it back (`write(into:) -> W`) makes the return
/// value lifetime-dependent on an argument, which the checker cannot trace across a protocol witness once
/// the value has passed through an intermediary. Letting the producer finish keeps every lifetime-dependent
/// value inside one function body, and needs no `@_lifetime` annotation anywhere in this tier.
///
/// The cost is a real obligation: a producer that returns without calling `finish` leaves the response
/// unterminated, which per the proposal aborts it. That is the same observable outcome as a mid-body throw,
/// so the failure mode is at least consistent — but nothing enforces it.
///
/// **No `Sendable` requirement**, deliberately. The producer never escapes the terminal's region. Requiring
/// `Sendable` would be the sole reason a non-`Sendable` body value — an Elementary `some HTML` capturing a
/// model object, say — would need an erasure box.
public protocol WireMVCBodyProducer {
    /// The `Content-Type` these bytes are, seeded into the response unless the route already named one.
    ///
    /// The producer *is* the codec, so it is the thing that knows. Before this the codegen seeded HTML's
    /// content type as a static header contribution while `WireMVCOutcome.json` seeded JSON's internally —
    /// two mechanisms for one intent, and neither available to a body type WireMVC has never heard of.
    /// `RequestBodySendable.sendBody` already returns `(bytes, contentType)` together for the same reason.
    var contentType: String? { get }

    /// The parts of the response head this body decides, rather than the route — ``WireMVCBodyHead/route``
    /// for a body that leaves the head entirely to the route, which is what every producer did before this
    /// existed and what the default says.
    ///
    /// A requirement rather than an extension member so a conformer's own value is what the terminal reads
    /// through the generic `Producer`; the extension below supplies the default.
    ///
    /// It exists for a body whose bytes are only known *as a range of something*: a file answering
    /// `Range` sends `206` and `Content-Range` for a part, `416` for a range it cannot satisfy, and states
    /// `Content-Length` because it knows it. None of that is the route's to say, because none of it is
    /// known until the request's `Range` field has been read against the file — so it is read off the body,
    /// once, when the head is built.
    var head: WireMVCBodyHead { get }

    consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields?
}

extension WireMVCBodyProducer {
    /// Defaulted, so a producer whose bytes have no single content type — server-sent events framed by the
    /// route, a raw stream — simply says nothing and lets the route's own `@ResponseHeader` stand.
    public var contentType: String? { nil }

    /// Defaulted to ``WireMVCBodyHead/route``, so a producer that says nothing about the head — HTML, a
    /// framed stream — leaves the route's status and fields exactly as they were.
    public var head: WireMVCBodyHead { .route }
}

/// What a ``WireMVCBodyProducer`` decides about the response head: a status, and header fields.
///
/// **It describes the bytes, so it wins.** Applied after every other contributor has folded —
/// `@ResponseHeader` constants, the handler's returned fields, middleware contributions — a stated status
/// replaces the route's, and each stated field replaces every line of the same name. The rule is the one a
/// content type would want if a route could not name its own, and here it cannot be otherwise: a `206`
/// whose `Content-Range` a middleware overwrote, or a `Content-Length` a route constant contradicted, is a
/// malformed response rather than a preference. A route that wants a different validator or length is
/// asking for a different body, and says so by building one.
///
/// `Content-Type` is the exception, and stays where it was: ``WireMVCBodyProducer/contentType`` is
/// *seeded*, so a route's own `@ResponseHeader(.contentType, …)` still beats it. A media type is the
/// author's to restate; framing is not.
public struct WireMVCBodyHead: Sendable, Equatable {
    /// The status the body requires, or `nil` to answer with the route's.
    public var status: HTTPResponse.Status?

    /// Fields the body requires. Each name here replaces that name's lines from every other contributor.
    public var headerFields: HTTPFields

    public init(status: HTTPResponse.Status? = nil, headerFields: HTTPFields = HTTPFields()) {
        self.status = status
        self.headerFields = headerFields
    }

    /// Nothing decided: the route's status and fields stand.
    public static let route = WireMVCBodyHead()

    /// The head with this body's decisions applied over the route's.
    func applied(
        over status: HTTPResponse.Status,
        _ fields: HTTPFields
    ) -> (status: HTTPResponse.Status, headerFields: HTTPFields) {
        guard !headerFields.isEmpty else { return (self.status ?? status, fields) }
        var resolved = fields
        // Every line of a stated name goes, then the stated lines go in — so a body stating one value for a
        // field another contributor appended twice leaves exactly the body's.
        for name in Set(headerFields.map(\.name)) { resolved[name] = nil }
        resolved.append(contentsOf: headerFields)
        return (self.status ?? status, resolved)
    }
}

/// A response whose head is sent up front and whose body is then streamed by a ``WireMVCBodyProducer``.
///
/// Generic over the *concrete* producer, which is inferred at its single construction site inside the
/// generated terminal's `building` closure. It appears in no user-written signature.
public struct WireMVCStreamingOutcome<Producer: WireMVCBodyProducer> {
    /// The response status. Resolved before the producer runs, because the head goes out first.
    public var status: HTTPResponse.Status

    /// The response header fields, already folded — `@ResponseHeader` constants, the handler's returned
    /// fields, and middleware contributions, in the usual order. A contribution registered *after* the head
    /// is sent has nowhere to go; see ``trailer``.
    public var headerFields: HTTPFields

    /// What writes the body.
    public var producer: Producer

    /// Trailing fields, delivered with the end of the body — where post-head metadata goes now that the
    /// header fold has already run (`Writer.FinalElement == HTTPFields?`).
    public var trailer: HTTPFields?

    public init(
        status: HTTPResponse.Status,
        headerFields: HTTPFields = HTTPFields(),
        producer: Producer,
        trailer: HTTPFields? = nil
    ) {
        self.status = status
        self.headerFields = headerFields
        self.producer = producer
        self.trailer = trailer
    }

    /// Send the head, then hand the writer to the producer.
    ///
    /// Deliberately `throws`. A mid-body failure propagates to the framework, and the writer is dropped
    /// without `finish` — which the proposal defines as aborting the response, the honest wire signal for a
    /// truncated body. Nothing is swallowed, and nothing pretends a post-head error can become a status.
    public consuming func send<Sender: HTTPResponseSender & ~Copyable>(
        on sender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        var fields = headerFields
        // Seeded, not forced: a route's own `@ResponseHeader(.contentType, …)` is already in `headerFields`
        // by the time the terminal builds this, so naming one wins — the same precedence the static header
        // tier gives it.
        if fields[.contentType] == nil, let contentType = producer.contentType {
            fields[.contentType] = contentType
        }
        // Last, over everything above — see ``WireMVCBodyHead`` for why the body's own head wins.
        let head = producer.head.applied(over: status, fields)
        let writer = try await sender.send(HTTPResponse(status: head.status, headerFields: head.headerFields))
        try await producer.writeBody(into: writer, terminatedBy: trailer)
    }
}

/// The generated terminal for a streaming route whose request body is **read incrementally**.
///
/// The sibling of the collecting overload above, and the distinction between them is worth stating because
/// it is easy to conclude the wrong thing from that one's doc comment. Collection cannot happen *inside*
/// `building` because a closure only **borrows** what it captures, and `collectBody` consumes. A reader
/// handed to `building` as a **consuming parameter** is not captured — this function owns it and moves it
/// in — so the obstacle does not apply, and a `@RequestBinding(.readerBody)` binding can consume it there.
///
/// That placement is the whole point: the binding runs inside the same `do` whose `catch` maps, so a
/// malformed body still becomes a status through `@ErrorResponse` rather than escaping as a truncated
/// response. Hoisting the read above the call would compile and lose exactly that.
///
/// The request is reduced to a value before the response head goes out, so this is *sequential*, not
/// duplex. A binding that **lends** the stream to the handler (`.bodyStream`) still cannot combine with a
/// streaming response — see `WireMVCDiagnostic.bodyStreamOnStreamingResponse`.
public func wireMVCStreamingTerminal<
    Producer: WireMVCBodyProducer,
    Sender: HTTPResponseSender & ~Copyable,
    Reader: AsyncReader & ~Copyable
>(
    responseSender: consuming Sender,
    responseHeaders: consuming ResponseHeaderRegistry,
    lendingBodyFrom reader: consuming sending Reader,
    building: (consuming Reader) async throws -> WireMVCStreamingOutcome<Producer>,
    // `async` because a mapped refusal may still await — and it no longer drains: the registry is owned
    // by this function and resolved onto whichever branch ran, so a middleware's contributed fields reach
    // a mapped `403` without a second drain. That mattered because a middleware's fields used to survive a
    // 200 and vanish from every `@ErrorResponse` status, which is exactly the path most likely to need
    // them: a cross-origin caller cannot read a 403 whose `Access-Control-Allow-Origin` was dropped.
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable, Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
    let wireMVCProduced: Result<WireMVCStreamingOutcome<Producer>, any Error>
    do {
        wireMVCProduced = .success(try await building(reader))
    } catch let wireMVCError {
        wireMVCProduced = .failure(wireMVCError)
    }
    // Between the handler and the head: late enough that a deferred contribution reads what the handler
    // did, early enough that a throw from one still maps. Once, because the registry is owned here.
    let wireMVCDrained = await wireMVCDrainedHeaders(from: responseHeaders)
    let wireMVCResult = try await wireMVCSettled(
        wireMVCProduced,
        drained: wireMVCDrained,
        errorMapping: errorMapping
    )
    switch wireMVCResult {
    case .stream(var streaming):
        streaming.headerFields = wireMVCResolved(streaming.headerFields, applying: wireMVCDrained.contributions)
        try await streaming.send(on: responseSender)
    case .buffered(var buffered):
        buffered.headerFields = wireMVCResolved(buffered.headerFields, applying: wireMVCDrained.contributions)
        try await buffered.send(on: responseSender)
    }
}

/// The terminal-local discriminant: what a streaming route decided to send. Never named by a user.
public enum WireMVCTerminalOutcome<Producer: WireMVCBodyProducer> {
    case stream(WireMVCStreamingOutcome<Producer>)
    case buffered(WireMVCOutcome)
}

/// The generated terminal for a streaming route.
///
/// **Discriminate inside the `do`/`catch`, consume the sender once, outside it** — preserving the
/// single-consume-site invariant the buffered terminal already maintains. The alternative (sending inside
/// the `do`) does not compile: the ownership checker reports `'responseSender' consumed more than once`,
/// because a throwing send inside the `do` can reach the `catch`. The soundness rule is the checker's.
///
/// `building` carries everything that can fail *before* the head goes out — scope entry, parameter binding,
/// the handler call, the header drain — so all of it still maps through `errorMapping` exactly as a
/// buffered route's does. Nothing after the first byte can be mapped, which is inherent to streaming and is
/// why `Producer` is only reached once `building` has returned.
///
/// `Producer` is inferred from `building`'s return type, which is what lets the generated code stream a
/// handler returning an opaque type it cannot spell.
public func wireMVCStreamingTerminal<Producer: WireMVCBodyProducer, Sender: HTTPResponseSender & ~Copyable>(
    responseSender: consuming Sender,
    responseHeaders: consuming ResponseHeaderRegistry,
    building: () async throws -> WireMVCStreamingOutcome<Producer>,
    // `async` because a mapped refusal may still await — and it no longer drains: the registry is owned
    // by this function and resolved onto whichever branch ran, so a middleware's contributed fields reach
    // a mapped `403` without a second drain. That mattered because a middleware's fields used to survive a
    // 200 and vanish from every `@ErrorResponse` status, which is exactly the path most likely to need
    // them: a cross-origin caller cannot read a 403 whose `Access-Control-Allow-Origin` was dropped.
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable {
    let wireMVCProduced: Result<WireMVCStreamingOutcome<Producer>, any Error>
    do {
        wireMVCProduced = .success(try await building())
    } catch let wireMVCError {
        wireMVCProduced = .failure(wireMVCError)
    }
    // Between the handler and the head: late enough that a deferred contribution reads what the handler
    // did, early enough that a throw from one still maps. Once, because the registry is owned here.
    let wireMVCDrained = await wireMVCDrainedHeaders(from: responseHeaders)
    let wireMVCResult = try await wireMVCSettled(
        wireMVCProduced,
        drained: wireMVCDrained,
        errorMapping: errorMapping
    )
    switch wireMVCResult {
    case .stream(var streaming):
        streaming.headerFields = wireMVCResolved(streaming.headerFields, applying: wireMVCDrained.contributions)
        try await streaming.send(on: responseSender)
    case .buffered(var buffered):
        buffered.headerFields = wireMVCResolved(buffered.headerFields, applying: wireMVCDrained.contributions)
        try await buffered.send(on: responseSender)
    }
}

/// The generated terminal for a streaming route that reads the request body.
///
/// A separate overload rather than an optional reader, because `collectBody` **consumes** the reader and a
/// closure only borrows it: emitting the collection inside `building` produces
/// `'reader' is borrowed and cannot be consumed`. Hoisting it above the call would compile but move the read
/// outside the mapped region, so a malformed body would escape `@ErrorResponse` instead of becoming a status.
/// Collecting here keeps both — the reader is consumed in a function that owns it, inside the same `do` whose
/// `catch` maps.
public func wireMVCStreamingTerminal<
    Producer: WireMVCBodyProducer,
    Sender: HTTPResponseSender & ~Copyable,
    Reader: AsyncReader & ~Copyable
>(
    responseSender: consuming Sender,
    responseHeaders: consuming ResponseHeaderRegistry,
    collectingBodyFrom reader: consuming sending Reader,
    building: ([UInt8]) async throws -> WireMVCStreamingOutcome<Producer>,
    // `async` because a mapped refusal may still await — and it no longer drains: the registry is owned
    // by this function and resolved onto whichever branch ran, so a middleware's contributed fields reach
    // a mapped `403` without a second drain. That mattered because a middleware's fields used to survive a
    // 200 and vanish from every `@ErrorResponse` status, which is exactly the path most likely to need
    // them: a cross-origin caller cannot read a 403 whose `Access-Control-Allow-Origin` was dropped.
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable, Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
    let wireMVCProduced: Result<WireMVCStreamingOutcome<Producer>, any Error>
    do {
        let requestBody = try await WireMVCRequest.collectBody(reader)
        wireMVCProduced = .success(try await building(requestBody))
    } catch let wireMVCError {
        wireMVCProduced = .failure(wireMVCError)
    }
    // Between the handler and the head: late enough that a deferred contribution reads what the handler
    // did, early enough that a throw from one still maps. Once, because the registry is owned here.
    let wireMVCDrained = await wireMVCDrainedHeaders(from: responseHeaders)
    let wireMVCResult = try await wireMVCSettled(
        wireMVCProduced,
        drained: wireMVCDrained,
        errorMapping: errorMapping
    )
    switch wireMVCResult {
    case .stream(var streaming):
        streaming.headerFields = wireMVCResolved(streaming.headerFields, applying: wireMVCDrained.contributions)
        try await streaming.send(on: responseSender)
    case .buffered(var buffered):
        buffered.headerFields = wireMVCResolved(buffered.headerFields, applying: wireMVCDrained.contributions)
        try await buffered.send(on: responseSender)
    }
}
