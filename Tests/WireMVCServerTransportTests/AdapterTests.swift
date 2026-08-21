#if ServerTransport
import AsyncStreaming
import Middleware
import BasicContainers
import HTTPAPIs
import HTTPTypes
import OpenAPIRuntime
import ServiceLifecycle
import Testing
import WireMVC
import WireMVCServerTransport

/// A minimal in-process `ServerTransport` — enough `{name}` matching to populate `pathParameters` and
/// drive the registered handlers. Stands in for a framework's transport (Hummingbird/Vapor).
final class MockTransport: ServerTransport, @unchecked Sendable {
    private struct Registration {
        let method: HTTPRequest.Method
        let template: [String]
        let handler:
            @concurrent @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            )
    }

    private var registrations: [Registration] = []

    func register(
        _ handler:
            @concurrent @Sendable @escaping (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
                HTTPResponse, HTTPBody?
            ),
        method: HTTPRequest.Method,
        path: String
    ) throws {
        registrations.append(.init(method: method, template: Self.segments(path), handler: handler))
    }

    func send(
        _ method: HTTPRequest.Method,
        _ path: String,
        body: HTTPBody? = nil
    ) async throws -> (
        HTTPResponse, [UInt8]
    ) {
        let requestSegments = Self.segments(path)
        for registration in registrations where registration.method == method {
            guard let params = Self.match(template: registration.template, path: requestSegments) else { continue }
            let request = HTTPRequest(method: method, scheme: nil, authority: nil, path: path)
            let (response, responseBody) = try await registration.handler(request, body, .init(pathParameters: params))
            let bytes: [UInt8]
            if let responseBody {
                bytes = Array(try await HTTPBody.ByteChunk(collecting: responseBody, upTo: 1_000_000))
            } else {
                bytes = []
            }
            return (response, bytes)
        }
        return (HTTPResponse(status: .notFound), [])
    }

    /// Like `send`, but returns the response `HTTPBody` **uncollected** so a test can pull chunks
    /// incrementally — collecting (as `send` does) would hang on an unbounded streamed body.
    func sendStreaming(
        _ method: HTTPRequest.Method,
        _ path: String,
        body: HTTPBody? = nil
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let requestSegments = Self.segments(path)
        for registration in registrations where registration.method == method {
            guard let params = Self.match(template: registration.template, path: requestSegments) else { continue }
            let request = HTTPRequest(method: method, scheme: nil, authority: nil, path: path)
            return try await registration.handler(request, body, .init(pathParameters: params))
        }
        return (HTTPResponse(status: .notFound), nil)
    }

    private static func segments(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func match(template: [String], path: [String]) -> [String: Substring]? {
        guard template.count == path.count else { return nil }
        var params: [String: Substring] = [:]
        for (templateSegment, pathSegment) in zip(template, path) {
            if templateSegment.hasPrefix("{"), templateSegment.hasSuffix("}") {
                params[String(templateSegment.dropFirst().dropLast())] = pathSegment[...]
            } else if templateSegment != pathSegment {
                return nil
            }
        }
        return params
    }
}

/// A hand-written `RouteContributor` (what `@Controller` generates) — generic over the builder, its
/// closures driving the proposal reader/sender.
struct HelloController: RouteContributor {
    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(
        on builder: inout Builder,
        coding: WireMVCCoding
    ) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        builder.register(method: .get, path: "/hello") { _, _, _, _, responseSender in
            var body = UniqueArray<UInt8>(copying: "Well, hello!".utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
        builder.register(method: .post, path: "/echo") { _, _, _, reader, responseSender in
            var collected = UniqueArray<UInt8>()
            _ = try await reader.collect(into: &collected, maximumSize: 1_000_000)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &collected)
        }
        builder.register(method: .get, path: "/users/{id}") { _, _, pathParameters, _, responseSender in
            let id = pathParameters["id"].map(String.init) ?? "?"
            var body = UniqueArray<UInt8>(copying: "user \(id)".utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
    }
}

/// An unbounded event producer that counts what it has handed out, so a test can assert the handler
/// never runs far ahead of the consumer (backpressure).
actor CountingEventSource {
    private(set) var producedCount = 0

    func next() -> [UInt8] {
        producedCount += 1
        return Array("data: tick \(producedCount)\n\n".utf8)
    }
}

/// A raw streaming (SSE) controller — what `@Controller` would emit for a `@RawRoute`. It drives the
/// sender incrementally (`send` head → one `write` per event) rather than `sendAndFinish`, so it
/// exercises the adapter's streaming path.
struct StreamingController: RouteContributor {
    let source: CountingEventSource

    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(
        on builder: inout Builder,
        coding: WireMVCCoding
    ) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        let source = self.source
        builder.register(method: .get, path: "/events") { _, _, _, _, responseSender in
            var fields = HTTPFields()
            fields[.contentType] = "text/event-stream"
            var writer = try await responseSender.send(HTTPResponse(status: .ok, headerFields: fields))
            // Cancellation-aware, as a real SSE handler must be: when the transport releases the body
            // (client disconnect), the bound handler task is cancelled and the loop exits.
            while !Task.isCancelled {
                var chunk = UniqueArray<UInt8>(copying: await source.next())
                try await writer.write(buffer: &chunk)
            }
            var end = UniqueArray<UInt8>()
            try await writer.finish(buffer: &end, finalElement: nil)
        }
    }
}

/// A request-body producer that counts the chunks it has handed out, so a test can assert the handler is
/// fed **on demand** rather than from a body the bridge drained up front.
actor CountingChunkSource {
    static let chunkSize = 64 * 1024
    private(set) var producedCount = 0

    func next() -> HTTPBody.ByteChunk {
        producedCount += 1
        return ArraySlice(repeatElement(UInt8(producedCount % 256), count: Self.chunkSize))
    }
}

/// An `HTTPBody` sequence that pulls each chunk from the source only when its consumer asks — the shape a
/// real transport's request body has, and the only shape that can tell "streamed" apart from "collected".
/// A `nil` `limit` never ends, which is what makes the unbounded test decisive: a bridge that collects
/// before dispatching would hang rather than fail.
struct PulledChunks: AsyncSequence, Sendable {
    typealias Element = HTTPBody.ByteChunk

    let source: CountingChunkSource
    let limit: Int?

    struct AsyncIterator: AsyncIteratorProtocol {
        let source: CountingChunkSource
        let limit: Int?
        var delivered = 0

        mutating func next() async -> HTTPBody.ByteChunk? {
            if let limit, delivered == limit { return nil }
            delivered += 1
            return await source.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: source, limit: limit) }
}

/// A controller whose routes read the request body incrementally — what `@Controller` emits for a
/// streaming request binding (`@MultipartStream`), reduced to the part the bridge has to get right.
struct StreamingRequestController: RouteContributor {
    let source: CountingChunkSource

    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(
        on builder: inout Builder,
        coding: WireMVCCoding
    ) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        // Reads three chunks and answers — *without* ever reaching the end of the body. A handler that
        // decides against a body it has begun to receive is the whole point of the streaming tier.
        builder.register(method: .post, path: "/three") { _, _, _, reader, responseSender in
            var reader = reader
            var chunks = 0
            while chunks < 3 {
                try await reader.read { buffer, _ in
                    chunks += 1
                    buffer.removeAll()
                }
            }
            var body = UniqueArray<UInt8>(copying: "read \(chunks)".utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
        // Reads and writes at once: head out first, then one response chunk per request chunk. The
        // response-body-processing shape, and the arrangement that fails if the bridge serialises the two
        // halves — the request body is still arriving after the register closure has returned its body.
        builder.register(method: .post, path: "/echo-stream") { _, _, _, reader, responseSender in
            var reader = reader
            var writer = try await responseSender.send(HTTPResponse(status: .ok))
            var ended = false
            while !ended {
                var chunkBytes: [UInt8] = []
                ended = try await reader.read { buffer, finalElement in
                    var index = buffer.startIndex
                    while index != buffer.endIndex {
                        let span = buffer.nextSpan(after: &index, maximumCount: .max)
                        for position in 0..<span.count { chunkBytes.append(span[position]) }
                    }
                    return finalElement != nil
                }
                if !chunkBytes.isEmpty {
                    var out = UniqueArray<UInt8>(copying: chunkBytes)
                    try await writer.write(buffer: &out)
                }
            }
            var end = UniqueArray<UInt8>()
            try await writer.finish(buffer: &end, finalElement: nil)
        }
        // Consumes a body past the 1 MB the bridge used to cap every request at, so how much a route
        // will accept is WireMVC's policy (`streamBody`'s `maximumSize`) rather than the adapter's.
        builder.register(method: .post, path: "/count") { _, _, _, reader, responseSender in
            var total = 0
            try await WireMVCRequest.streamBody(reader, into: &total) { count, span in
                count += span.count
            }
            var body = UniqueArray<UInt8>(copying: "\(total)".utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
    }
}

/// Contributes a response header field on the way in, exactly as a real controller-scope middleware does.
/// It reaches the registry off the box, which on this path exists only because the `ServerTransport` bridge
/// constructs the courier itself.
struct StampMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        input.responseHeaders.add(.set(.init("x-stamp")!, "adapter"))
        return try await next(input)
    }
}

/// A hand-written contributor shaped like the generated witness: read the registry off the courier, build
/// the box over the *unwrapped* context, fold, and drain at the terminal.
struct StampedController: RouteContributor {
    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(
        on builder: inout Builder,
        coding: WireMVCCoding
    ) throws
    where
        Builder.RequestContext: ~Copyable & ResponseHeaderCarrying,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        builder.register(method: .get, path: "/stamped") { request, requestContext, _, reader, responseSender in
            let registry = requestContext.responseHeaders
            let box = RequestResponseMiddlewareBox.pending(
                request: request,
                requestContext: requestContext.takeBase(),
                reader: reader,
                responseSender: responseSender,
                responseHeaders: registry
            )
            let chain = wireCompose {
                StampMiddleware<Builder.RequestContext.Base, Builder.Reader, Builder.ResponseSender>()
            }
            try await chain.intercept(input: box) { finalBox in
                let drain = finalBox.responseHeaders
                return try await finalBox.withPendingContents { _, _, _, sender in
                    try await WireMVCOutcome.status(
                        .ok,
                        headerFields: WireMVCResponseHeaders.resolved(middleware: try await drain.drain())
                    ).send(on: sender)
                }
            }
        }
    }
}

/// A graph whose single controller contributes a header field through a middleware.
struct StampedGraph: WireMVCComposable {
    var routeContributors: [any RouteContributor] { [StampedController()] }
    var services: [any Service] { [] }
}

/// The mechanism `ServiceContext` (and so distributed tracing) rides on. A plain `@TaskLocal` rather than
/// the real thing on purpose: `ServiceContext.current` *is* a task-local, so what has to be proven is that
/// task-locals survive the bridge — proving it without taking a dependency on swift-distributed-tracing.
enum TracingProbe {
    @TaskLocal static var traceID: String?
}

/// Reads the ambient task-local at two points that are not the same: inside the register closure's
/// unstructured `Task` (one-shot), and from the streaming body producer, which runs *after* that closure
/// has returned its response head.
struct TracingController: RouteContributor {
    func registerWireRoutes<Builder: HTTPServerRouteBuilder>(
        on builder: inout Builder,
        coding: WireMVCCoding
    ) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        builder.register(method: .get, path: "/trace") { _, _, _, _, responseSender in
            var body = UniqueArray<UInt8>(copying: (TracingProbe.traceID ?? "<none>").utf8)
            try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
        }
        // The sharper case: each chunk is produced after the register closure returned, so this reads the
        // task-local at a point where the host's `withValue` scope has long exited. Task-local values are
        // copied into an unstructured `Task` at creation, so they should outlive that scope.
        builder.register(method: .get, path: "/trace-stream") { _, _, _, _, responseSender in
            var writer = try await responseSender.send(HTTPResponse(status: .ok))
            for index in 1...3 {
                var chunk = UniqueArray<UInt8>(
                    copying: "\(index):\(TracingProbe.traceID ?? "<none>")\n".utf8
                )
                try await writer.write(buffer: &chunk)
            }
            try await writer.finish()
        }
    }
}

struct TracingGraph: WireMVCComposable {
    var routeContributors: [any RouteContributor] { [TracingController()] }
    var services: [any Service] { [] }
}

/// Stands in for `Wire.bootstrap()`'s collated graph. No `@BackgroundService` contributors here, so
/// `services` is empty — the routes are what this adapter test drives.
struct TestGraph: WireMVCComposable {
    var routeContributors: [any RouteContributor] { [HelloController()] }
    var services: [any Service] { [] }
}

/// A graph whose single controller streams an unbounded SSE response.
struct StreamingGraph: WireMVCComposable {
    let source: CountingEventSource
    var routeContributors: [any RouteContributor] { [StreamingController(source: source)] }
    var services: [any Service] { [] }
}

/// A graph whose single controller reads its request body a chunk at a time.
struct StreamingRequestGraph: WireMVCComposable {
    let source: CountingChunkSource
    var routeContributors: [any RouteContributor] { [StreamingRequestController(source: source)] }
    var services: [any Service] { [] }
}

@Suite("WireMVCServerTransport")
struct AdapterTests {
    /// `WireMVCServerTransport.apply` registers the collated (proposal-native) routes onto a
    /// `ServerTransport`; the bridge fabricates a reader from the request `HTTPBody` and a sender that
    /// collects the response, and the transport routes + supplies path parameters.
    @Test
    func servesProposalRoutesOnServerTransport() async throws {
        let transport = MockTransport()
        try WireMVCServerTransport.apply(TestGraph(), to: transport)

        let (hello, helloBody) = try await transport.send(.get, "/hello")
        #expect(hello.status == .ok && String(decoding: helloBody, as: UTF8.self) == "Well, hello!")

        let (echo, echoBody) = try await transport.send(.post, "/echo", body: HTTPBody("round-trip"))
        #expect(echo.status == .ok && String(decoding: echoBody, as: UTF8.self) == "round-trip")

        let (user, userBody) = try await transport.send(.get, "/users/42")
        #expect(user.status == .ok && String(decoding: userBody, as: UTF8.self) == "user 42")

        let (miss, _) = try await transport.send(.get, "/nope")
        #expect(miss.status == .notFound)
    }

    /// A middleware's contributed header field reaches the response **through the bridge**.
    ///
    /// The registry rides the request context, and on this path the courier is constructed by the
    /// `ServerTransport` bridge rather than by `WireMVCContextServer` — a separate construction site that
    /// nothing else exercises. Hummingbird and Vapor both mount through here, so without this the entire
    /// response-header feature runs untested on two of the three runtimes.
    @Test
    func contributedHeaderFieldsReachTheResponseThroughTheBridge() async throws {
        let transport = MockTransport()
        try WireMVCServerTransport.apply(StampedGraph(), to: transport)

        let (response, _) = try await transport.send(.get, "/stamped")
        #expect(response.status == .ok)
        #expect(response.headerFields[.init("x-stamp")!] == "adapter")
    }

    // MARK: - Ambient context across the bridge

    /// Task-local context set by a host middleware reaches a WireMVC handler.
    ///
    /// This is what an `open-telemetry`-style host middleware needs: `ServiceContext.current` is a
    /// task-local, so if task-locals cross the bridge, tracing context does. The bridge dispatches into an
    /// unstructured `Task {}` — which *inherits* task-locals, unlike `Task.detached` — so it should hold;
    /// the point of pinning it is that swapping to `Task.detached` for an unrelated reason would break
    /// tracing silently, with no test and no compiler complaint.
    @Test
    func taskLocalContextReachesTheHandlerThroughTheBridge() async throws {
        let transport = MockTransport()
        try WireMVCServerTransport.apply(TracingGraph(), to: transport)

        let (response, body) = try await TracingProbe.$traceID.withValue("abc-123") {
            try await transport.send(.get, "/trace")
        }
        #expect(response.status == .ok)
        #expect(String(decoding: body, as: UTF8.self) == "abc-123")
    }

    /// The same, for a *streamed* response — where the body is produced after the register closure has
    /// returned and the host's `withValue` scope has exited.
    ///
    /// The value is copied into the unstructured task at creation, so it outlives the scope that set it.
    /// A bridge that produced the body from a task created later, outside that scope, would read `nil`
    /// here while the one-shot case above still passed.
    @Test
    func taskLocalContextSurvivesIntoAStreamedBody() async throws {
        let transport = MockTransport()
        try WireMVCServerTransport.apply(TracingGraph(), to: transport)

        let (head, streamingBody) = try await TracingProbe.$traceID.withValue("abc-123") {
            try await transport.sendStreaming(.get, "/trace-stream")
        }
        #expect(head.status == .ok)
        let body = try #require(streamingBody)

        var text = ""
        for try await chunk in body { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text == "1:abc-123\n2:abc-123\n3:abc-123\n")
    }

    /// A raw streaming (SSE) handler streams through the adapter incrementally: events arrive from an
    /// unbounded response (a buffering bridge would hang), and the handler never runs more than one
    /// event ahead of the consumer (the rendezvous `AsyncChannel`'s backpressure).
    @Test
    func streamsRawResponseWithBackpressure() async throws {
        let source = CountingEventSource()
        let transport = MockTransport()
        try WireMVCServerTransport.apply(StreamingGraph(source: source), to: transport)

        let (head, streamingBody) = try await transport.sendStreaming(.get, "/events")
        #expect(head.status == .ok && head.headerFields[.contentType] == "text/event-stream")
        let body = try #require(streamingBody)

        var events: [String] = []
        var maxLead = 0
        for try await chunk in body {
            events.append(String(decoding: chunk, as: UTF8.self))
            maxLead = max(maxLead, await source.producedCount - events.count)
            if events.count >= 5 { break }
        }

        #expect(events.first == "data: tick 1\n\n" && events.last == "data: tick 5\n\n" && events.count == 5)
        #expect(maxLead <= 1)
    }

    /// The request body reaches the handler **as it arrives**: the route reads three chunks off a body
    /// that never ends and answers, and nothing pulled a fourth.
    ///
    /// The symmetric case to `streamsRawResponseWithBackpressure`, and the one that distinguishes a
    /// streaming bridge from a collecting one at all — the bridge used to drain the whole body before
    /// dispatching, so this body would have been read to its 1 MB ceiling (16 chunks) and failed there,
    /// having never asked the handler whether it wanted them.
    @Test
    func streamsRequestBodyOnDemand() async throws {
        let source = CountingChunkSource()
        let transport = MockTransport()
        try WireMVCServerTransport.apply(StreamingRequestGraph(source: source), to: transport)

        let unbounded = HTTPBody(
            PulledChunks(source: source, limit: nil),
            length: .unknown,
            iterationBehavior: .single
        )
        let (response, body) = try await transport.send(.post, "/three", body: unbounded)

        #expect(response.status == .ok && String(decoding: body, as: UTF8.self) == "read 3")
        #expect(await source.producedCount == 3)
    }

    /// Request and response stream **at the same time**: the response head and its first chunk are out
    /// while the request body is still arriving, which is what an echo or a digesting proxy needs and what
    /// a bridge that drains before dispatching cannot do at any body size.
    ///
    /// Note this pins the *bridge's* behaviour only. Whether a given framework tolerates its request body
    /// being read after the route closure has returned a streaming response is that framework's channel
    /// semantics, and the runtime suites in wire-mvc-examples are where that gets answered.
    @Test
    func streamsRequestAndResponseBodiesConcurrently() async throws {
        let chunks = 3
        let source = CountingChunkSource()
        let transport = MockTransport()
        try WireMVCServerTransport.apply(StreamingRequestGraph(source: source), to: transport)

        let body = HTTPBody(
            PulledChunks(source: source, limit: chunks),
            length: .unknown,
            iterationBehavior: .single
        )
        let (head, responseBody) = try await transport.sendStreaming(.post, "/echo-stream", body: body)
        #expect(head.status == .ok)

        var received = 0
        var producedAtFirstChunk = 0
        for try await chunk in try #require(responseBody) {
            received += 1
            if received == 1 { producedAtFirstChunk = await source.producedCount }
            #expect(chunk.count == CountingChunkSource.chunkSize)
        }

        #expect(received == chunks)
        // The handler may already have gone back for the next chunk by the time the consumer measures, so
        // the bound is "not all of them" rather than exactly one — which is the claim under test.
        #expect(producedAtFirstChunk < chunks)
    }

    /// A body past the bridge's old 1 MB collect ceiling round-trips, so a route's size limit is
    /// WireMVC's (`streamBody`'s `maximumSize`, as on the proposal-native path) rather than the adapter's.
    @Test
    func acceptsRequestBodyLargerThanTheOldCollectCeiling() async throws {
        let chunks = 32  // × 64 KiB = 2 MiB
        let source = CountingChunkSource()
        let transport = MockTransport()
        try WireMVCServerTransport.apply(StreamingRequestGraph(source: source), to: transport)

        let large = HTTPBody(
            PulledChunks(source: source, limit: chunks),
            length: .unknown,
            iterationBehavior: .single
        )
        let (response, body) = try await transport.send(.post, "/count", body: large)

        #expect(response.status == .ok)
        #expect(String(decoding: body, as: UTF8.self) == "\(chunks * CountingChunkSource.chunkSize)")
    }
}
#endif
