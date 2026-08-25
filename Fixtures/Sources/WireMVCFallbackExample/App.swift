package import HTTPAPIs
package import HTTPTypes
import Logging
package import NIOHTTPServer
import ServiceLifecycle
package import Wire
package import WireMVC
package import WireMVCMiddleware
import WireMVCRouter

// A second `@WireMVCBootstrap` app whose whole point is what it *does not* declare: no `@NotFound`.
//
// Every other fixture writes one, so the plugin's **synthesised** 404 — the fallback most real apps get,
// precisely because they never think about it — was emitted by nothing under test. A global `@Middleware`
// contributing a response header therefore reached matched routes and the authored fallback while silently
// missing the synthesised one, and no fixture could tell.
//
// Deliberately minimal otherwise: one route, one global middleware, no error tiers, no scopes. Anything
// more would make a failure here ambiguous.

package enum StampKeys {
    package static let factory = FactoryKey()
}

/// Contributes a header on the way in. It must reach the synthesised 404 as well as `/ping`.
@Factory(StampKeys.factory)
@MiddlewareFactory
package struct Stamp<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        input.responseHeaders.add(.set(.init("x-stamp")!, "global"))
        return try await next(input)
    }
}

package struct Pong: Codable, Sendable, Equatable {
    package let ok: Bool
    package init(ok: Bool) { self.ok = ok }
}

@Singleton
@Controller("/ping")
@Middleware(ControllerStampKeys.factory)
package struct PingController: Sendable {
    @Inject package init() {}

    @Get
    @JSONResponse
    package func ping() -> (headers: HTTPFields, body: Pong) {
        ([.cacheControl: "max-age=5"], Pong(ok: true))
    }
}

/// No `@NotFound` — that absence is the fixture.
@Singleton
@WireMVCBootstrap
@Middleware(StampKeys.factory)
@Middleware(GateKeys.factory)
@Middleware(CORSMiddlewareKeys.factory)
package struct FallbackBootstrap: Sendable {
    @Inject package init() {}

    /// The middleware's dependency, supplied through the graph like any other. `.oneOf` with credentials is
    /// the combination worth exercising: allowed *because* it names one origin per response, where `.all`
    /// with credentials traps at construction.
    @Provides package static let cors = CORSConfiguration(
        allowOrigin: .oneOf(["https://allowed.example"]),
        allowMethods: [.get, .post],
        allowHeaders: [.contentType],
        allowCredentials: true,
        exposedHeaders: [.init("x-stamp")!],
        maxAge: .seconds(600)
    )

    package func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(
            logger: Logger(label: "WireMVCFallbackExample"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
    }

    package func createRouteBuilder<Server: HTTPServer>(
        for server: borrowing Server
    ) -> some FinalizableHTTPServerRouteBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable
    {
        TrieRouteBuilder(for: server)
    }
}

// MARK: - The gate path

package enum GateKeys {
    package static let factory = FactoryKey()
}

/// A gate: it answers `/gated` itself rather than letting the terminal run, which is the one path where
/// `respondingWith` matters.
///
/// A gate short-circuits the terminal, so the terminal's drain never happens — contributions would vanish on
/// exactly the responses that most want them (a `401` needing its challenge, a redirect needing a cookie set
/// on the way out). `respondingWith` drains into the outcome before sending; raw `responding` hands over the
/// sender and does not, which is why it is documented as being for streaming.
///
/// It also uses `.setIfAbsent`, the verb that exists so a contributor can defer: `Stamp` runs outside this
/// and has already set `x-stamp`, so this one's value must lose.
@Factory(GateKeys.factory)
@MiddlewareFactory
package struct Gate<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        input.responseHeaders.add(.setIfAbsent(.init("x-stamp")!, "gate"))
        guard input.peekedRequest.path?.hasPrefix("/gated") == true else {
            return try await next(input)
        }
        // Responds *with an outcome*, so whatever middleware contributed is drained into it. The challenge
        // is the route's own; the `x-stamp` above it comes from the global tier.
        let responded = try await input.respondingWith(
            .status(.unauthorized, headerFields: [.wwwAuthenticate: #"Bearer realm="fixture""#])
        )
        return try await next(responded)
    }
}

// MARK: - A controller-scope contributor alongside the global one

package enum ControllerStampKeys {
    package static let factory = FactoryKey()
}

/// Contributes at **controller** scope while `Stamp` contributes at **global** scope. Both write to the
/// same registry, so both fields must reach the response.
@Factory(ControllerStampKeys.factory)
@MiddlewareFactory
package struct ControllerStamp<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        input.responseHeaders.add(.set(.init("x-controller")!, "controller"))
        return try await next(input)
    }
}
