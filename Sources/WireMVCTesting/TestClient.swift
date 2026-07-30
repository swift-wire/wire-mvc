public import Foundation
public import HTTPTypes

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The typed HTTP client a suite's tests drive, over whichever transport the suite's ``WireMVCTestMode``
// stood up. The surface is the small verb set a controller test needs — `get`/`post`/`patch`/`delete` —
// each returning a `TestResponse` that exposes the status, the raw body text, and typed JSON decoding. A
// test reaches the running suite's client through the static `TestClient.current`.
//
// The verbs are transport-agnostic, and now so is everything beneath them: each builds an `HTTPRequest` and
// starts a ``TestExchange``. In process the app's handler fills that exchange; live, a proposal
// `HTTPClient.perform` is piped into one. A test therefore reads identically in either mode — switching a
// suite between them is a one-word change — and both stream.

/// A typed HTTP client bound to a running suite's transport. Each call drives one request and returns a
/// ``TestResponse``.
public struct TestClient: Sendable {
    /// How a built request reaches the app.
    enum Transport: Sendable {
        /// The in-memory exchange channel. A request is submitted and answered incrementally: the head
        /// arrives before the body exists, and body chunks cross a rendezvous, so this transport streams.
        case inProcess(InProcessDispatch)
        #if NIOHTTPServer
        /// A real HTTP round-trip, driven by a proposal `HTTPClient` and piped into an exchange — so a live
        /// suite reads incrementally exactly as an in-process one does.
        case live(LiveDispatch)
        #endif
    }

    let transport: Transport

#if NIOHTTPServer
    init(dispatch: LiveDispatch) {
        self.transport = .live(dispatch)
    }
#endif

    init(dispatch: InProcessDispatch) {
        self.transport = .inProcess(dispatch)
    }

    /// The client for the running `@Suite(.wiremvc(…))` suite, bound for the duration of the suite by
    /// ``WireMVCTesting/serveForSuite(on:handler:services:runTests:)`` or
    /// ``WireMVCTesting/driveInProcess(handler:services:runTests:)``. Read it inside a suite-trait suite
    /// (e.g. `TestClient.current.post(...)`); `nil` outside such a suite.
    @TaskLocal static var currentStorage: TestClient?

    /// The client for the running `@Suite(.wiremvc(…))` suite. Available only inside a suite the trait
    /// scopes — outside one there is no app to reach, so this precondition-fails.
    public static var current: TestClient {
        guard let client = currentStorage else {
            preconditionFailure("TestClient.current is only available inside an @Suite(.wiremvc(…)) suite")
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
    func send(
        _ method: String,
        _ path: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> TestResponse {
        // The buffered surface over what is now a streaming transport either way: start the exchange, then
        // drain it whole.
        try await Self.buffered(startExchange(method, path, body: body, headers: headers))
    }

    /// Start one exchange on whichever transport this client carries. The two differ only in who fills it —
    /// the app's handler in process, a proposal `HTTPClient` live — so everything above this is
    /// transport-agnostic.
    func startExchange(
        _ method: String,
        _ path: String,
        body: Data?,
        headers: [String: String]
    ) async throws -> TestExchange {
        let request = makeHTTPRequest(method, path, headers: headers)
        switch transport {
        case .inProcess(let dispatch):
            return try await dispatch.start(request, body: body)
        #if NIOHTTPServer
        case .live(let dispatch):
            return try await dispatch.start(request, body: body)
        #endif
        }
    }

    /// Drain an exchange whole — what the untyped verbs and the generated typed methods do over what is
    /// otherwise a streaming transport.
    private static func buffered(_ exchange: TestExchange) async throws -> TestResponse {
        guard let head = try await exchange.startedHead() else {
            // The producer finished without a response. Live, a server aborts the connection; in-process
            // there is nothing to abort — either way there is no head, which `status` reports as
            // `TestResponse.unanswered` rather than a plausible-looking 500.
            return TestResponse(head: nil, body: Data())
        }
        return TestResponse(head: head, body: try await exchange.drainBody())
    }

    /// The correlation header value for the current request, or `nil` outside a `withBindValues` closure.
    /// Inside one the task-local carries the request's correlation id; stamping it lets the dispatch pull
    /// that closure's doubles from the store. Shared by both transports so the keyed harness works in
    /// either mode.
    private var correlationHeaderValue: String? {
        WireMVCTesting.currentCorrelationID?.rawValue.uuidString
    }

    /// Build the `HTTPRequest` for one call. Both transports take one: in-process hands it to the handler,
    /// and the live transport addresses it at the bound port before performing it. The correlation header is
    /// stamped here, so the keyed harness reads it identically either way.
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
