public import Foundation
public import HTTPTypes

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The typed HTTP client a suite's tests drive, over whichever transport the suite's ``WireMVCTestMode``
// stood up. The surface is the small verb set a controller test needs — `get`/`post`/`patch`/`delete` —
// each returning a `TestResponse` that exposes the status, the raw body text, and typed JSON decoding. A
// test reaches the running suite's client through `withClient(supplying:)` (bound to that block's doubles) or
// `withClient` (bound to none) — never ambiently, so every client states which binding it carries.
//
// The verbs are transport-agnostic: they build a method/path/body/headers triple and hand it to the
// ``Transport``. `.loopback` renders it as a `URLRequest` and drives one real round-trip over
// `URLSession`; `.inProcess` renders it as an `HTTPRequest` and calls the finalized handler directly. A
// test therefore reads identically in either mode — switching a suite between them is a one-word change.

/// A typed HTTP client bound to a running suite's transport. Each call drives one request and returns a
/// ``TestResponse``.
public struct TestClient: Sendable {
    /// How a built request reaches the app.
    enum Transport: Sendable {
        /// A real HTTP round-trip to the suite server's loopback host + port.
        case loopback(host: String, port: Int)
        /// The in-memory exchange channel. A request is submitted and answered incrementally: the head
        /// arrives before the body exists, and body chunks cross a rendezvous, so this transport streams.
        case inProcess(InProcessDispatch)
    }

    let transport: Transport

    /// The correlation id this client was handed when it was created, if any — a client obtained from a
    /// `withClient(supplying:)` body carries that block's id, so requests it drives resolve to *that* block's doubles
    /// no matter where they are called from. `nil` for a client from `withClient`, which supplies no doubles.
    let boundCorrelationID: CorrelationID?

    init(host: String, port: Int, boundCorrelationID: CorrelationID? = nil) {
        self.transport = .loopback(host: host, port: port)
        self.boundCorrelationID = boundCorrelationID
    }

    init(dispatch: InProcessDispatch, boundCorrelationID: CorrelationID? = nil) {
        self.transport = .inProcess(dispatch)
        self.boundCorrelationID = boundCorrelationID
    }

    /// This client's transport, pinned to `id`. The generated per-controller client is built from this, so
    /// holding the client *is* holding the binding — two clients from two nested blocks address their own
    /// doubles rather than both resolving to the innermost.
    public func bound(to id: CorrelationID) -> TestClient {
        TestClient(transport: transport, boundCorrelationID: id)
    }

    private init(transport: Transport, boundCorrelationID: CorrelationID?) {
        self.transport = transport
        self.boundCorrelationID = boundCorrelationID
    }

    /// The client for the running `@Suite(.wiremvc(…))` suite, bound for the duration of the suite by
    /// ``WireMVCTesting/serveForSuite(on:handler:services:runTests:)`` or
    /// ``WireMVCTesting/driveInProcess(handler:services:runTests:)``. Read it inside a suite-trait suite
    /// read through ``forSuite``; `nil` outside such a suite.
    @TaskLocal static var currentStorage: TestClient?

    /// The running suite's client, for the framework's `withClient` entry points to hand
    /// out. Deliberately **not** public: a client is only meaningful with a binding decision attached — with
    /// a correlation id from `withClient(supplying:)`, or explicitly without one from `withClient(for:)` — so tests reach
    /// it through those rather than ambiently. Available only inside a suite the trait scopes; outside one
    /// there is no app to reach, so this precondition-fails.
    static var forSuite: TestClient {
        guard let client = currentStorage else {
            preconditionFailure(
                "A WireMVC test client is only available inside an @Suite(.wiremvc(…)) suite — "
                    + "reach it through withClient(supplying:) or withClient(for:)"
            )
        }
        return client
    }

    /// `GET path`.
    public func get(_ path: String, headers: [String: String] = [:]) async throws -> TestResponse {
        try await send("GET", path, body: nil, headers: headers)
    }

    /// `POST path` with `json` encoded as the JSON body (`Content-Type: application/json`).
    public func post(
        _ path: String,
        json: some Encodable,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        try await send("POST", path, body: try JSONEncoder().encode(json), headers: jsonHeaders(headers))
    }

    /// `PATCH path` with `json` encoded as the JSON body (`Content-Type: application/json`).
    public func patch(
        _ path: String,
        json: some Encodable,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        try await send("PATCH", path, body: try JSONEncoder().encode(json), headers: jsonHeaders(headers))
    }

    /// `DELETE path`.
    public func delete(_ path: String, headers: [String: String] = [:]) async throws -> TestResponse {
        try await send("DELETE", path, body: nil, headers: headers)
    }

    private func jsonHeaders(_ headers: [String: String]) -> [String: String] {
        var merged = headers
        merged["Content-Type"] = "application/json"
        return merged
    }

    /// The one send both surfaces funnel through — the untyped verbs above and the generated typed clients'
    /// `routeResponse`, which layers path templating and the non-2xx rule on top.
    /// Send any method. The named verbs above cover the ones a typed route declares; this is for the rest —
    /// a CORS preflight's `OPTIONS`, a `HEAD`, anything a `@RawRoute` serves. Public because without it a
    /// suite simply cannot reach those, which made CORS preflight untestable.
    public func send(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        switch transport {
        case .loopback:
            let request = makeRequest(method, path, body: body, headers: headers)
            let (data, response) = try await Self.session.data(for: request)
            return TestResponse(head: Self.head(of: response), body: data)
        case .inProcess(let dispatch):
            // The buffered surface over a streaming transport: start the exchange, then drain it whole.
            let exchange = try await dispatch.start(makeHTTPRequest(method, path, headers: headers), body: body)
            guard let head = try await exchange.startedHead() else {
                // The handler returned without sending a response. Live, the server would abort the
                // connection; in-process there is nothing to abort, so surface it as a distinguishable
                // status rather than a plausible-looking 500.
                return TestResponse(head: nil, body: Data())
            }
            return TestResponse(head: head, body: try await exchange.drainBody())
        }
    }

    /// The client's own `URLSession`, with cookie handling switched off at the **configuration** level.
    ///
    /// `URLSession.shared` manages cookies through the process-wide `HTTPCookieStorage`: it stores every
    /// `Set-Cookie` a route sends and then replaces an explicitly-set `Cookie` header with whatever it holds
    /// for that host. A suite that logs in twice therefore sends the second session's cookie on a request
    /// that explicitly carries the first, and the route answers as the wrong user — silently.
    ///
    /// `URLRequest.httpShouldHandleCookies = false` is the documented per-request opt-out, and setting it
    /// alone **did not stop the rewriting on Linux CI** — a suite still received the previous login's cookie
    /// on a request explicitly carrying another. Why it had no effect there is not established: it is not
    /// referenced in `URLSessionTask.swift` or `HTTPURLProtocol.swift` upstream, which is suggestive but not
    /// conclusive, and no upstream issue was found. This removes the storage instead of asking the request
    /// to bypass it, which does not depend on knowing the answer.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // A test client must observe the server, not a cache. Once a route answers with a freshness
        // directive — `Cache-Control: max-age=…`, which is an ordinary thing for a route to return — the
        // session will serve a later identical GET out of its cache, replaying both the stale body and the
        // stale head. That reads as a server bug: a request with different headers appears to be ignored,
        // and a request carrying `Origin` comes back without its CORS fields because the cached copy was
        // stored for a request that had none. Both are the cache answering, and neither reaches the server.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Rebuild the proposal's response head from Foundation's. `URLSession` reports the status and header
    /// fields separately from the body, so this is the loopback transport's one lossy seam — header *order*
    /// and repeated fields are not recoverable from `allHeaderFields`.
    private static func head(of response: URLResponse) -> HTTPResponse? {
        guard let http = response as? HTTPURLResponse else { return nil }
        var head = HTTPResponse(status: .init(code: http.statusCode))
        for (rawName, rawValue) in http.allHeaderFields {
            guard let rawName = rawName as? String, let name = HTTPField.Name(rawName) else { continue }
            head.headerFields[name] = String(describing: rawValue)
        }
        return head
    }

    /// The correlation header value for this client's requests, or `nil` when it carries no binding. A
    /// client from a `withClient(supplying:)` body is pinned to that block's id; one from `withClient(for:)` is pinned to
    /// nothing and so supplies no doubles. Stamping the id lets the dispatch pull that block's doubles from
    /// the store. Shared by both transports so the keyed harness works in either mode.
    private var correlationHeaderValue: String? {
        boundCorrelationID?.rawValue.uuidString
    }

    /// Build the `URLRequest` for one loopback call. Split from ``send(_:_:body:headers:)`` so the
    /// header-stamping is unit-testable without a round-trip.
    func makeRequest(
        _ method: String,
        _ path: String,
        body: Data?,
        headers: [String: String]
    ) -> URLRequest {
        guard case let .loopback(host, port) = transport else {
            preconditionFailure("makeRequest is the loopback transport's renderer")
        }
        var request = URLRequest(url: URL(string: "http://\(host):\(port)\(path)")!)
        request.httpMethod = method
        request.httpBody = body
        // Belt to `Self.session`'s braces. Correct on Darwin; observed to have no effect on Linux CI, which
        // is why the session carries the actual fix.
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let value = correlationHeaderValue {
            request.setValue(value, forHTTPHeaderField: wireMVCTestBindsHeader)
        }
        return request
    }

    /// Build the `HTTPRequest` for one in-process call — the loopback renderer's counterpart, stamping the
    /// same correlation header so the keyed harness's dispatch reads it identically. The authority is a
    /// placeholder: nothing resolves it, since no connection is made.
    func makeHTTPRequest(
        _ method: String,
        _ path: String,
        headers: [String: String]
    ) -> HTTPRequest {
        var fields = HTTPFields()
        for (name, value) in headers {
            guard let name = HTTPField.Name(name) else { continue }
            fields[name] = value
        }
        if let value = correlationHeaderValue, let name = HTTPField.Name(wireMVCTestBindsHeader) {
            fields[name] = value
        }
        return HTTPRequest(
            method: HTTPRequest.Method(method) ?? .get,
            scheme: "http",
            authority: "in-process",
            path: path,
            headerFields: fields
        )
    }
}

/// The result of a `TestClient` request — the response head and body, with typed JSON decoding.
public struct TestResponse: Sendable {
    /// The full response head: status *and* header fields. Carried whole rather than reduced to a status
    /// code, because a `@RawRoute` writes its own framing — a multipart boundary, a cache header — and a
    /// suite driving one needs to assert it.
    ///
    /// `nil` when the handler returned without responding at all: there is genuinely no head then, and
    /// inventing one would mean an out-of-range `HTTPResponse.Status` (whose `init` preconditions on
    /// `0...999`) or a plausible-looking `500` that hides the bug.
    public let head: HTTPResponse?
    /// The raw response body bytes.
    public let body: Data

    /// The HTTP status code, or ``TestResponse/unanswered`` when the handler never responded.
    public var status: Int { head?.status.code ?? Self.unanswered }

    /// The `status` of a response that was never sent. Not a real HTTP code, so it can't be confused with
    /// one the app chose.
    public static let unanswered = -1

    /// The response body decoded as UTF-8 text.
    public var bodyText: String {
        String(decoding: body, as: UTF8.self)
    }

    /// Decode the response body as JSON into `type`.
    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}
