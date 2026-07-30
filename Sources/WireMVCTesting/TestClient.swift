public import Foundation
import HTTPTypes

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The typed HTTP client a suite's tests drive, over whichever transport the suite's ``WireMVCTestMode``
// stood up. The surface is the small verb set a controller test needs — `get`/`post`/`patch`/`delete` —
// each returning a `TestResponse` that exposes the status, the raw body text, and typed JSON decoding. A
// test reaches the running suite's client through the static `TestClient.current`.
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
        /// A direct call into the finalized handler, returning its response head + body (`nil` when the
        /// handler returned without responding).
        case inProcess(@Sendable (HTTPRequest, [UInt8]) async throws -> (head: HTTPResponse, body: [UInt8])?)
    }

    let transport: Transport

    init(host: String, port: Int) {
        self.transport = .loopback(host: host, port: port)
    }

    init(
        dispatch: @escaping @Sendable (HTTPRequest, [UInt8]) async throws -> (head: HTTPResponse, body: [UInt8])?
    ) {
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
        switch transport {
        case .loopback:
            let request = makeRequest(method, path, body: body, headers: headers)
            let (data, response) = try await URLSession.shared.data(for: request)
            return TestResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: data)
        case .inProcess(let dispatch):
            let request = makeHTTPRequest(method, path, headers: headers)
            guard let response = try await dispatch(request, body.map(Array.init) ?? []) else {
                // The handler returned without sending a response. Live, the server would abort the
                // connection; in-process there is nothing to abort, so surface it as a distinguishable
                // status rather than a plausible-looking 500.
                return TestResponse(status: -1, body: Data())
            }
            return TestResponse(status: response.head.status.code, body: Data(response.body))
        }
    }

    /// The correlation header value for the current request, or `nil` outside a `withBindValues` closure.
    /// Inside one the task-local carries the request's correlation id; stamping it lets the dispatch pull
    /// that closure's doubles from the store. Shared by both transports so the keyed harness works in
    /// either mode.
    private var correlationHeaderValue: String? {
        WireMVCTesting.currentCorrelationID?.rawValue.uuidString
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

/// The result of a `TestClient` request — status code and body, with typed JSON decoding.
public struct TestResponse: Sendable {
    /// The HTTP status code.
    public let status: Int
    /// The raw response body bytes.
    public let body: Data

    /// The response body decoded as UTF-8 text.
    public var bodyText: String {
        String(decoding: body, as: UTF8.self)
    }

    /// Decode the response body as JSON into `type`.
    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}
