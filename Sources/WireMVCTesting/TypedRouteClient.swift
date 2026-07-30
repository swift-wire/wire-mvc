public import Foundation
public import HTTPTypes

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

    /// Drive a `@RawRoute` and return its response **as-is**, including a non-2xx.
    ///
    /// A raw route writes its own response — status, framing and all — so there is no declared type to
    /// decode and no status that counts as the failure case: a route may answer `404` or stream a
    /// `206` by design. The generated shim therefore returns ``TestResponse`` rather than a value, and
    /// this does not throw for status the way ``routeResponse(method:path:pathParameters:query:headers:)``
    /// does. What it still gives is the *path*: the template comes from the route's own verb annotation, so
    /// renaming the route breaks the test.
    public func rawRouteResponse(
        method: String,
        path: String,
        pathParameters: [String: String] = [:],
        query: [(name: String, value: String)] = [],
        headers: [String: String] = [:]
    ) async throws -> TestResponse {
        try await send(
            method,
            Self.resolve(template: path, pathParameters: pathParameters, query: query),
            body: nil,
            headers: headers
        )
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
        let status = HTTPResponse.Status(code: response.status)
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
