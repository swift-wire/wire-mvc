import AsyncStreaming
import BasicContainers
import Foundation
import HTTPAPIs
import HTTPTypes
import Testing

@testable import WireMVCTesting

// Unit coverage for the in-process transport, independent of the codegen: a hand-written
// `HTTPServerRequestHandler` over the in-memory associated types, driven through
// `WireMVCTesting.runSuite(.inProcess, …)` — the same entry point a generated suite factory uses. It
// covers the two response shapes a real route takes (the typed path's one-shot `sendAndFinish` and the raw
// path's `send(_:)` + incremental `write`/`finish`) plus the request body reader, which the in-package
// fixture app's GET-only routes can't reach.

/// Echoes the request body, its method/path, and any header the request asked to be reflected. `/stream`
/// takes the raw path (`send` then incremental writes); everything else takes the one-shot path.
private struct EchoHandler: HTTPServerRequestHandler {
    typealias RequestContext = InProcessRequestContext
    typealias Reader = InProcessReader
    typealias ResponseSender = InProcessResponseSender

    func handle(
        request: HTTPRequest,
        requestContext: consuming InProcessRequestContext,
        reader: consuming sending InProcessReader,
        responseSender: consuming sending InProcessResponseSender
    ) async throws {
        // `collect(into:maximumSize:)` — the growing overload `WireMVCRequest.collectBody` uses. The
        // capped `collect(into:)` treats the buffer's *initial* free capacity as a hard limit, so an empty
        // `UniqueArray` would silently discard the whole body.
        var received = UniqueArray<UInt8>()
        _ = try await reader.collect(into: &received, maximumSize: 1_000_000)

        if request.path == "/stream" {
            // The raw/streaming path: head first, then two separate writes, then a `finish` carrying a
            // final chunk. In-process buffers them, so the driver sees the concatenation.
            var writer = try await responseSender.send(HTTPResponse(status: .accepted))
            var first = UniqueArray<UInt8>(copying: Array("one".utf8))
            try await writer.write(buffer: &first)
            var second = UniqueArray<UInt8>(copying: Array("two".utf8))
            try await writer.write(buffer: &second)
            var last = UniqueArray<UInt8>(copying: Array("three".utf8))
            try await writer.finish(buffer: &last, finalElement: nil)
            return
        }

        var body = UniqueArray<UInt8>(copying: Array("\(request.method.rawValue) \(request.path ?? "")|".utf8))
        body.append(moving: received.startIndex..<received.endIndex, from: &received)
        if let name = HTTPField.Name("X-Echo"), let value = request.headerFields[name] {
            var suffix = UniqueArray<UInt8>(copying: Array("|\(value)".utf8))
            body.append(moving: suffix.startIndex..<suffix.endIndex, from: &suffix)
        }
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
}

/// A handler that returns without ever responding — the one case with no wire analogue, since live the
/// server aborts the connection instead.
private struct SilentHandler: HTTPServerRequestHandler {
    typealias RequestContext = InProcessRequestContext
    typealias Reader = InProcessReader
    typealias ResponseSender = InProcessResponseSender

    func handle(
        request: HTTPRequest,
        requestContext: consuming InProcessRequestContext,
        reader: consuming sending InProcessReader,
        responseSender: consuming sending InProcessResponseSender
    ) async throws {}
}

@Suite struct InProcessTransportTests {
    private struct Payload: Codable, Equatable {
        let note: String
    }

    /// `runSuite` points `TestClient.current` at the handler for the duration of the body, and each verb
    /// reaches it with its method and path intact.
    @Test func driverBindsClientAndRoutesMethodAndPath() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(mode, on: mode.makeTestServer(), handler: EchoHandler(), services: []) {
            let get = try await TestClient.current.get("/hello")
            #expect(get.status == 200)
            #expect(get.bodyText == "GET /hello|")

            let delete = try await TestClient.current.delete("/hello")
            #expect(delete.bodyText == "DELETE /hello|")
        }
        // The client is scoped to the run, exactly as it is for a live transport.
        #expect(TestClient.currentStorage == nil)
    }

    /// A JSON body reaches the handler through ``InProcessReader`` — the request-body path a GET-only route
    /// never exercises — and the `Content-Type` the client sets arrives as a header field.
    @Test func requestBodyAndHeadersReachTheHandler() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(mode, on: mode.makeTestServer(), handler: EchoHandler(), services: []) {
            let response = try await TestClient.current.post(
                "/notes",
                json: Payload(note: "hi"),
                headers: ["X-Echo": "seen"]
            )
            #expect(response.status == 200)
            #expect(response.bodyText == #"POST /notes|{"note":"hi"}|seen"#)
        }
    }

    /// The raw path: `send(_:)` records the head, and the writer's incremental `write`s and terminating
    /// `finish` accumulate into one body. In-process buffers rather than streams, so the client sees the
    /// whole concatenation — the route logic is covered, its streaming *behaviour* is not.
    @Test func streamedWritesAccumulateIntoOneBody() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(mode, on: mode.makeTestServer(), handler: EchoHandler(), services: []) {
            let response = try await TestClient.current.get("/stream")
            #expect(response.status == 202)
            #expect(response.bodyText == "onetwothree")
        }
    }

    /// A handler that never responds has no status to report, so the client surfaces `-1` rather than
    /// inventing a plausible 500.
    @Test func handlerThatNeverRespondsIsDistinguishable() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(mode, on: mode.makeTestServer(), handler: SilentHandler(), services: []) {
            let response = try await TestClient.current.get("/anything")
            #expect(response.status == -1)
            #expect(response.body.isEmpty)
        }
    }

    /// The correlation header the keyed harness rides on. One request builder serves both transports, so
    /// this is the whole of that behaviour. In-process it lands
    /// on the `HTTPRequest`'s header fields, where `wireMVCTestCorrelationID` reads it back — the same
    /// function the generated dispatch calls.
    @Test func correlationHeaderIsStampedOnTheInProcessRequest() async throws {
        let client = TestClient(dispatch: InProcessDispatch())

        let outside = client.makeHTTPRequest("GET", "/notes", headers: [:])
        #expect(wireMVCTestCorrelationID(in: outside) == nil)

        let store = TestBindStore<Int>()
        try await WireMVCTesting.withBindValues(1, in: store) {
            let inside = client.makeHTTPRequest("GET", "/notes", headers: [:])
            #expect(wireMVCTestCorrelationID(in: inside) == WireMVCTesting.currentCorrelationID)
        }

        // And gone again once the closure exits — the id is task-local, so a request driven afterwards
        // must not carry a stale correlation.
        let after = client.makeHTTPRequest("GET", "/notes", headers: [:])
        #expect(wireMVCTestCorrelationID(in: after) == nil)
    }
}
