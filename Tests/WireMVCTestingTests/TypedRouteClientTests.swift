import AsyncStreaming
import BasicContainers
import Foundation
import HTTPAPIs
import HTTPTypes
import Testing

@testable import WireMVCTesting

// The runtime a generated per-controller client funnels through: path templating, the query string, and the
// non-2xx rule. Driven against a hand-written handler over the in-process transport, so these are the same
// mechanics a generated method exercises without needing the codegen.

/// Echoes the resolved request line so a test can assert what reached the route, and answers a non-2xx for
/// paths that ask for one.
private struct RouteEchoHandler: HTTPServerRequestHandler {
    typealias RequestContext = InProcessRequestContext
    typealias Reader = InProcessReader
    typealias ResponseSender = InProcessResponseSender

    func handle(
        request: HTTPRequest,
        requestContext: consuming InProcessRequestContext,
        reader: consuming sending InProcessReader,
        responseSender: consuming sending InProcessResponseSender
    ) async throws {
        var received = UniqueArray<UInt8>()
        _ = try await reader.collect(into: &received, maximumSize: 1_000_000)

        let path = request.path ?? ""
        if path.hasPrefix("/fail") {
            var body = UniqueArray<UInt8>(copying: Array("nope".utf8))
            try await responseSender.sendAndFinish(HTTPResponse(status: .unauthorized), buffer: &body)
            return
        }
        var body = UniqueArray<UInt8>(copying: Array(#""\#(path)""#.utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
}

@Suite struct TypedRouteClientTests {
    /// Templating is done by the runtime, not the generated method, so the template in emitted code reads
    /// exactly like the one on the route.
    @Test func placeholdersAreSubstituted() {
        let resolved = TestClient.resolve(template: "/notes/{id}", pathParameters: ["id": "x"], query: [])
        #expect(resolved == "/notes/x")
    }

    /// A path parameter is one component: a value containing `/` or a space must not reshape the URL.
    @Test func pathValuesArePercentEncoded() {
        let resolved = TestClient.resolve(template: "/notes/{id}", pathParameters: ["id": "a/b c"], query: [])
        #expect(resolved == "/notes/a%2Fb%20c")
    }

    /// Query items are appended in the order the route declares them, each component encoded — including the
    /// separators `urlQueryAllowed` would otherwise let through.
    @Test func queryItemsAreAppendedAndEncoded() {
        let resolved = TestClient.resolve(
            template: "/todos",
            pathParameters: [:],
            query: [(name: "q", value: "a&b"), (name: "page", value: "2")]
        )
        #expect(resolved == "/todos?q=a%26b&page=2")
    }

    /// No query items → no trailing `?`.
    @Test func noQueryLeavesThePathAlone() {
        #expect(TestClient.resolve(template: "/todos", pathParameters: [:], query: []) == "/todos")
    }

    /// The resolved line is what actually reaches the route, not just what the helper computed.
    @Test func theResolvedPathReachesTheRoute() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(mode, on: mode.makeTestServer(), handler: RouteEchoHandler(), services: []) {
            let response = try await TestClient.current.routeResponse(
                method: "GET",
                path: "/notes/{id}",
                pathParameters: ["id": "alpha"],
                query: [(name: "verbose", value: "true")]
            )
            #expect(try response.json(String.self) == "/notes/alpha?verbose=true")
        }
    }

    /// A non-2xx becomes a throw carrying the status, the body, and the route that produced it — the typed
    /// methods return a decoded value, so this is where a failure surfaces.
    @Test func nonSuccessThrowsWithStatusAndBody() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(mode, on: mode.makeTestServer(), handler: RouteEchoHandler(), services: []) {
            let error = try await #require(throws: WireMVCRouteError.self) {
                try await TestClient.current.routeResponse(method: "GET", path: "/fail")
            }
            #expect(error.status == .unauthorized)
            #expect(error.bodyText == "nope")
            #expect(error.route == "GET /fail")
            #expect(error.description.contains("401"))
        }
    }

    /// The `@JSONBody` form sets `Content-Type` and sends the encoded value.
    @Test func jsonBodyIsEncodedAndSent() async throws {
        struct Payload: Codable { let note: String }
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(mode, on: mode.makeTestServer(), handler: RouteEchoHandler(), services: []) {
            let response = try await TestClient.current.routeResponse(
                method: "POST",
                path: "/notes",
                json: Payload(note: "hi")
            )
            #expect(response.status == 200)
        }
    }
}
