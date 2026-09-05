// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncStreaming
import BasicContainers
import Foundation
import HTTPAPIs
import HTTPTypes
import Synchronization
import Testing
import WireMVC

@testable import WireMVCTesting

// The runtime a generated per-controller client funnels through: path templating, the query string, and the
// non-2xx rule. Driven against a hand-written handler over the in-process transport, so these are the same
// mechanics a generated method exercises without needing the codegen.

/// Echoes the resolved request line so a test can assert what reached the route, and answers a non-2xx for
/// paths that ask for one.
private struct RouteEchoHandler: HTTPServerRequestHandler {
    typealias RequestContext = WireMVCContext<InProcessRequestContext>
    typealias Reader = InProcessReader
    typealias ResponseSender = InProcessResponseSender

    func handle(
        request: HTTPRequest,
        requestContext: consuming WireMVCContext<InProcessRequestContext>,
        reader: consuming sending InProcessReader,
        responseSender: consuming sending InProcessResponseSender
    ) async throws {
        var received = UniqueArray<UInt8>()
        _ = try await reader.collect(into: &received, maximumSize: 1_000_000)

        let path = request.path ?? ""
        if path.hasPrefix("/echo-body") {
            var body = UniqueArray<UInt8>(copying: Array(#"""#.utf8))
            body.append(moving: received.startIndex..<received.endIndex, from: &received)
            var closing = UniqueArray<UInt8>(copying: Array(#"""#.utf8))
            body.append(moving: closing.startIndex..<closing.endIndex, from: &closing)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
            return
        }
        if path.hasPrefix("/fail") {
            var body = UniqueArray<UInt8>(copying: Array("nope".utf8))
            try await responseSender.sendAndFinish(HTTPResponse(status: .unauthorized), buffer: &body)
            return
        }
        var body = UniqueArray<UInt8>(copying: Array(#""\#(path)""#.utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }
}

/// Counts completed writes, so a reader can observe how far ahead the handler got. A reference because
/// `Mutex` is non-copyable and the handler must be a `Sendable` value.
private final class WriteProgress: Sendable {
    private let count = Mutex(0)
    func recordWrite() { count.withLock { $0 += 1 } }
    var completed: Int { count.withLock { $0 } }
}

/// Streams three chunks, counting the writes it has completed so a reader can observe how far ahead it got.
private struct ChunkedHandler: HTTPServerRequestHandler {
    typealias RequestContext = WireMVCContext<InProcessRequestContext>
    typealias Reader = InProcessReader
    typealias ResponseSender = InProcessResponseSender

    let progress: WriteProgress

    func handle(
        request: HTTPRequest,
        requestContext: consuming WireMVCContext<InProcessRequestContext>,
        reader: consuming sending InProcessReader,
        responseSender: consuming sending InProcessResponseSender
    ) async throws {
        var writer = try await responseSender.send(HTTPResponse(status: .ok))
        for chunk in ["one", "two"] {
            var buffer = UniqueArray<UInt8>(copying: Array(chunk.utf8))
            await writer.write(buffer: &buffer)
            progress.recordWrite()
        }
        var last = UniqueArray<UInt8>(copying: Array("three".utf8))
        await writer.finish(buffer: &last, finalElement: nil)
        progress.recordWrite()
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
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: RouteEchoHandler(),
            services: []
        ) {
            let response = try await TestClient.forSuite.routeResponse(
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
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: RouteEchoHandler(),
            services: []
        ) {
            let error = try await #require(throws: WireMVCRouteError.self) {
                try await TestClient.forSuite.routeResponse(method: "GET", path: "/fail")
            }
            #expect(error.status == .unauthorized)
            #expect(error.bodyText == "nope")
            #expect(error.route == "GET /fail")
            #expect(error.description.contains("401"))
        }
    }

    /// The raw form hands over the response head and a body reader, applying no status rule — and the head
    /// is the whole `HTTPResponse`, so a raw route's own framing is assertable where a status code alone
    /// would lose it.
    @Test func theRawFormHandsOverTheHeadAndReader() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: RouteEchoHandler(),
            services: []
        ) {
            let text = try await TestClient.forSuite.performRawRoute(method: "GET", path: "/fail") {
                response,
                reader in
                // A non-2xx is not a failure for a raw route: the closure still runs.
                #expect(response.status == .unauthorized)
                return try await reader.collectText()
            }
            #expect(text == "nope")
        }
    }

    /// The request body is the proposal's `HTTPClientRequestBody`, so both directions of a raw shim carry
    /// `perform`'s shape. A caller streaming into the writer reaches the route as one body — collected today,
    /// since neither transport is incremental yet, but expressed in the shape that survives that change.
    @Test func aStreamedRequestBodyReachesTheRoute() async throws {
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: RouteEchoHandler(),
            services: []
        ) {
            let echoed = try await TestClient.forSuite.performRawRoute(
                method: "POST",
                path: "/echo-body",
                body: .restartable { writer in
                    var writer = writer
                    var first = UniqueArray<UInt8>(copying: Array("one".utf8))
                    await writer.write(buffer: &first)
                    var last = UniqueArray<UInt8>(copying: Array("two".utf8))
                    await writer.finish(buffer: &last, finalElement: nil)
                }
            ) { response, reader in
                #expect(response.status == .ok)
                return try await reader.collectText()
            }
            // The handler echoes the request body it received, so the two writes arrive as one body.
            #expect(echoed == #""onetwo""#)
        }
    }

    /// In-process genuinely streams. The handler writes three chunks and records how many it has completed;
    /// the test reads one and checks the handler has *not* run ahead. That is only true if `write` suspends
    /// on the rendezvous until the reader takes the chunk — i.e. real backpressure, with no socket.
    @Test func inProcessAppliesBackpressurePerChunk() async throws {
        let progress = WriteProgress()
        let handler = ChunkedHandler(progress: progress)
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: handler,
            services: []
        ) {
            let all = try await TestClient.forSuite.performRawRoute(method: "GET", path: "/chunks") {
                response,
                reader in
                #expect(response.status == .ok)

                // The head arrived before the body was written at all — a buffered transport could not do
                // this, because it only has a response once the handler has returned.
                var reader = reader
                var collected: [String] = []
                var done = false
                while !done {
                    try await reader.read { buffer, final in
                        if buffer.count > 0 {
                            var chunk: [UInt8] = []
                            var consumer = buffer.consumeAll()
                            while let byte = consumer.next() { chunk.append(byte) }
                            collected.append(String(decoding: chunk, as: UTF8.self))
                            // The handler cannot be more than one chunk ahead of us: it is suspended in
                            // `write` until this read releases it.
                            #expect(progress.completed <= collected.count)
                        }
                        if final != nil { done = true }
                    }
                }
                return collected
            }
            #expect(all == ["one", "two", "three"])
        }
    }

    /// The `@JSONBody` form sets `Content-Type` and sends the encoded value.
    @Test func jsonBodyIsEncodedAndSent() async throws {
        struct Payload: Codable { let note: String }
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: RouteEchoHandler(),
            services: []
        ) {
            let response = try await TestClient.forSuite.routeResponse(
                method: "POST",
                path: "/notes",
                json: Payload(note: "hi")
            )
            #expect(response.status == 200)
        }
    }
}
