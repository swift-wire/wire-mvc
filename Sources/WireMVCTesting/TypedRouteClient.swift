// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncAlgorithms
public import AsyncStreaming
public import BasicContainers
public import Foundation
public import HTTPAPIs
public import HTTPTypes
import Synchronization

// The runtime half of the generated per-controller clients. `WireMVCRouteGen` emits, for each `@Controller`
// in a test consumer, a `struct <Name>Client` with one method per typed route — the method's parameters are
// the route's `@Path`/`@Query`/`@Header`/`@JSONBody` bindings and its return is the `@JSONResponse` type.
// Those methods are thin: they build the wire values and hand them to `routeResponse` below, which owns the
// path templating, the query string, the send, and the non-2xx rule.
//
// Route shape is derived, not hand-maintained, so a test driving a route through its generated method is
// checked against it: renaming the route, changing a `@Path`'s type, or altering the response body is a
// compile error rather than a runtime surprise. `TestClient`'s untyped verbs remain for what has no derivable
// shape — `@RawRoute` streaming, the `@NotFound` fallback, and any request a test wants to malform
// deliberately.

/// A route answered with a non-2xx status. The typed methods return the decoded response body, so a failure
/// arrives as a throw carrying what the untyped path would have exposed: the status, and the body.
///
/// Asserting one reads:
/// ```swift
/// let error = try await #require(throws: WireMVCRouteError.self) { try await todos.me() }
/// #expect(error.status == .unauthorized)
/// ```
public struct WireMVCRouteError: Error {
    /// The status the route answered with.
    public let status: HTTPResponse.Status
    /// The response body, for a route whose error tier writes one.
    public let body: Data
    /// The request that produced it — `"GET /me"` — so a failure names the route without the test repeating it.
    public let route: String

    /// The response body decoded as UTF-8 text.
    public var bodyText: String {
        String(decoding: body, as: UTF8.self)
    }
}

extension WireMVCRouteError: CustomStringConvertible {
    public var description: String {
        let detail = bodyText.isEmpty ? "" : " — \(bodyText)"
        return "\(route) answered \(status.code) \(status.reasonPhrase)\(detail)"
    }
}

/// Collects a request body a caller streams in. A `Sendable` reference because the writer that fills it is
/// `consuming`-threaded through `HTTPClientRequestBody.produce(into:)`.
final class RequestBodySink: Sendable {
    private let collected = Mutex<[UInt8]>([])

    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        collected.withLock { $0.append(contentsOf: bytes) }
    }

    var bytes: [UInt8] { collected.withLock { $0 } }
}

/// The writer a raw-route shim's request body is produced into — the caller's end of the request, matching
/// what the proposal's `HTTPClient.perform` hands an `HTTPClientRequestBody`.
///
/// Buffer-backed today for the same reason ``TestResponseReader`` is: neither transport streams yet, so the
/// body is collected and sent whole. The *shape* is what matters — a caller writing incrementally, or
/// declaring a seekable body for a resumable upload, compiles against this now and keeps working when the
/// transports become incremental.
public struct TestRequestWriter: CallerAsyncWriter {
    public typealias WriteElement = UInt8
    public typealias WriteFailure = Never
    public typealias FinalElement = HTTPFields?

    let sink: RequestBodySink

    public mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        sink.append(drainBytes(&buffer))
    }

    public consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        sink.append(drainBytes(&buffer))
    }
}

/// The response body reader a raw-route shim hands to its response handler. An `AsyncReader` over the
/// response bytes, matching what the proposal's `HTTPClient.perform` gives its closure — the same shape the
/// route's own handler writes through, read from the other end.
///
/// On the in-process transport this reads the response **as the handler writes it**: each `read` takes one
/// chunk off the exchange's rendezvous channel, so the handler's next `write` cannot proceed until this one
/// is consumed. That is genuine backpressure, in a mode with no socket. The loopback transport still buffers
/// (`URLSession.data` hands back a whole body), so there the first read delivers everything.
public struct TestResponseReader: AsyncReader {
    public typealias ReadElement = UInt8
    public typealias ReadFailure = Never
    public typealias FinalElement = HTTPFields?
    public typealias Buffer = UniqueArray<UInt8>

    /// Where the bytes come from — one buffer, or a live channel.
    private enum Source {
        case buffered(Data)
        case streaming(AsyncChannel<ArraySlice<UInt8>>)
        case exhausted
    }

    private var source: Source

    init(_ bytes: Data) { self.source = .buffered(bytes) }
    /// `AsyncChannel`'s iterator is a stateless handle on the channel's shared storage, so a fresh one per
    /// read takes the next chunk — no iterator has to be carried across isolation.
    init(streaming channel: AsyncChannel<ArraySlice<UInt8>>) { self.source = .streaming(channel) }

    public mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>()
        var final: FinalElement?
        switch source {
        case let .buffered(bytes):
            buffer = UniqueArray<UInt8>(copying: Array(bytes))
            source = .exhausted
            // `.some(nil)` — the terminal chunk, carrying no trailers.
            final = .some(nil)
        case let .streaming(channel):
            var iterator = channel.makeAsyncIterator()
            if let chunk = await iterator.next() {
                buffer = UniqueArray<UInt8>(copying: Array(chunk))
            } else {
                source = .exhausted
                final = .some(nil)
            }
        case .exhausted:
            final = .some(nil)
        }
        do {
            return try await body(&buffer, final)
        } catch {
            throw EitherError.second(error)
        }
    }
}

extension TestResponseReader {
    /// Drain the body to bytes. A convenience over `collect(into:maximumSize:)` so a suite asserting a raw
    /// route's payload doesn't manage a buffer.
    public consuming func collectBytes(maximumSize: Int = 1_000_000) async throws -> [UInt8] {
        var buffer = UniqueArray<UInt8>()
        _ = try await collect(into: &buffer, maximumSize: maximumSize)
        let span = buffer.span
        var bytes: [UInt8] = []
        bytes.reserveCapacity(span.count)
        for index in 0..<span.count { bytes.append(span[index]) }
        return bytes
    }

    /// Drain the body and decode it as UTF-8 — the common assertion for a text or framed raw response.
    public consuming func collectText(maximumSize: Int = 1_000_000) async throws -> String {
        String(decoding: try await collectBytes(maximumSize: maximumSize), as: UTF8.self)
    }
}

extension TestClient {
    /// Drive one typed route and return its response, throwing ``WireMVCRouteError`` for any non-2xx. The
    /// single entry point every generated client method funnels through.
    ///
    /// `path` is the route's template as declared (`/notes/{id}`); `pathParameters` supplies each
    /// placeholder. Templating here rather than in the generated method keeps the emitted code free of
    /// string surgery, and means the template in the generated call reads exactly like the one on the route.
    public func routeResponse(
        method: String,
        path: String,
        pathParameters: [String: String] = [:],
        query: [(name: String, value: String)] = [],
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        try await sendRoute(
            method,
            resolved: Self.resolve(template: path, pathParameters: pathParameters, query: query),
            headers: headers,
            body: nil
        )
    }

    /// The generalised body form — `body` is sent verbatim under `contentType`.
    ///
    /// Replaces the `json:` special case for generated clients: a body binding produces its own bytes and
    /// content type via ``RequestBodySendable/sendBody``, so the client no longer needs to know that JSON is
    /// the only codec. `json:` remains for hand-written callers.
    public func routeResponse(
        method: String,
        path: String,
        pathParameters: [String: String] = [:],
        query: [(name: String, value: String)] = [],
        headers: [String: String] = [:],
        body: [UInt8],
        contentType: String
    ) async throws -> TestResponse {
        var merged = headers
        merged["Content-Type"] = contentType
        return try await sendRoute(
            method,
            resolved: Self.resolve(template: path, pathParameters: pathParameters, query: query),
            headers: merged,
            body: Data(body)
        )
    }

    /// The `@JSONBody` form — `json` is encoded as the request body with `Content-Type: application/json`,
    /// matching what the route's `JSONBody` binding decodes.
    public func routeResponse(
        method: String,
        path: String,
        pathParameters: [String: String] = [:],
        query: [(name: String, value: String)] = [],
        headers: [String: String] = [:],
        json: some Encodable
    ) async throws -> TestResponse {
        var merged = headers
        merged["Content-Type"] = "application/json"
        return try await sendRoute(
            method,
            resolved: Self.resolve(template: path, pathParameters: pathParameters, query: query),
            headers: merged,
            body: try JSONEncoder().encode(json)
        )
    }

    /// Drive a `@RawRoute`, handing its response head and body reader to `responseHandler`.
    ///
    /// Shaped after the proposal's `HTTPClient.perform(request:body:options:responseHandler:)`: a raw route
    /// owns its response — status, headers, framing and all — so there is nothing to decode and nothing that
    /// counts as the failure case (a route may answer `404` or stream a `206` by design). Handing back the
    /// whole `HTTPResponse` rather than a status code makes a raw route's own framing assertable — the
    /// `Content-Type` boundary of a multipart export, a cache header, a trailer — which a buffered
    /// status-plus-body value cannot express.
    ///
    /// What the shim still derives is the request line: the verb and the path template come from the route's
    /// own annotation, so renaming the route breaks the test.
    ///
    /// - Note: On `.inProcess` this **streams**: the head arrives as soon as the handler sends it, and each
    ///   read takes one chunk off a rendezvous channel, so the handler's next `write` cannot proceed until
    ///   the test consumes this one. Incremental framing and backpressure are both observable with no socket.
    ///   The loopback transport still buffers — `URLSession.data` hands back a whole body — so there the
    ///   first read delivers everything. Making that incremental means either `URLSession.bytes` (with a
    ///   Linux `FoundationNetworking` caveat) or a proposal client, which reintroduces the NIO stack unless
    ///   it sits behind the `NIOHTTPServer` trait. This signature does not change when that lands.
    ///
    /// The request body is the proposal's own `HTTPClientRequestBody`, so both directions carry `perform`'s
    /// shape rather than only the response. A caller sending a fixed buffer writes `body: .data(…)`; one
    /// exercising a route that reads incrementally writes `.restartable { writer in … }` or
    /// `.seekable { offset, writer in … }` and keeps working unchanged when the transports stream.
    public func performRawRoute<Return: ~Copyable>(
        method: String,
        path: String,
        pathParameters: [String: String] = [:],
        query: [(name: String, value: String)] = [],
        headers: [String: String] = [:],
        body: consuming HTTPClientRequestBody<TestRequestWriter>? = nil,
        responseHandler: (HTTPResponse, consuming TestResponseReader) async throws -> Return
    ) async throws -> Return {
        let resolved = Self.resolve(template: path, pathParameters: pathParameters, query: query)
        var requestBody: Data?
        if let body {
            // Drive the caller's body through a writer, exactly as a proposal client does. It is collected
            // rather than streamed to the socket, so a `.seekable` body is produced once from offset 0.
            let sink = RequestBodySink()
            try await body.produce(into: TestRequestWriter(sink: sink))
            requestBody = Data(sink.bytes)
        }
        switch transport {
        case .inProcess(let dispatch):
            // Stream: hand over the head as soon as it is published, and read the body off the rendezvous as
            // the handler writes it.
            let exchange = try await dispatch.start(
                makeHTTPRequest(method, resolved, headers: headers),
                body: requestBody
            )
            guard let head = try await exchange.startedHead() else {
                throw WireMVCTestingError.routeDidNotRespond("\(method) \(resolved)")
            }
            return try await responseHandler(head, TestResponseReader(streaming: exchange.body))
        case .loopback:
            let received = try await send(method, resolved, body: requestBody, headers: headers)
            guard let head = received.head else {
                throw WireMVCTestingError.routeDidNotRespond("\(method) \(resolved)")
            }
            return try await responseHandler(head, TestResponseReader(received.body))
        }
    }

    /// Send an already-resolved request and apply the non-2xx rule. Both public forms resolve the template
    /// themselves, so this takes the finished path.
    private func sendRoute(
        _ method: String,
        resolved: String,
        headers: [String: String],
        body: Data?
    ) async throws -> TestResponse {
        let response = try await send(method, resolved, body: body, headers: headers)
        // A handler that returned without responding has no status to classify — and `Status(code:)`
        // preconditions on `0...999`, so the `unanswered` sentinel must not reach it.
        guard let status = response.head?.status else {
            throw WireMVCTestingError.routeDidNotRespond("\(method) \(resolved)")
        }
        guard status.kind == .successful else {
            throw WireMVCRouteError(status: status, body: response.body, route: "\(method) \(resolved)")
        }
        return response
    }

    /// Substitute `{name}` placeholders and append the query string. Percent-encoding is applied to each
    /// substituted value and query item, so a path parameter containing `/` or a space reaches the route as
    /// one component rather than reshaping the URL.
    static func resolve(
        template: String,
        pathParameters: [String: String],
        query: [(name: String, value: String)]
    ) -> String {
        var path = template
        for (name, value) in pathParameters {
            path = path.replacingOccurrences(of: "{\(name)}", with: percentEncoded(value))
        }
        guard !query.isEmpty else { return path }
        let items = query.map { "\(percentEncoded($0.name))=\(percentEncoded($0.value))" }
        return path + "?" + items.joined(separator: "&")
    }

    /// Percent-encode one path or query *component*. Foundation's `.urlQueryAllowed` is a whole-query set —
    /// it leaves `/`, `&`, `=` and `+` legal, so a path parameter containing any of them would reshape the
    /// URL rather than travel as one component. RFC 3986's unreserved set is the correct basis here:
    /// everything outside it is escaped.
    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? value
    }
}
