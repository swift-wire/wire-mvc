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
}
#endif
