package import HTTPAPIs
package import HTTPTypes
import Logging
package import NIOHTTPServer
import ServiceLifecycle
package import Wire
package import WireMVC
package import WireMVCRouter

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
package struct PingController: Sendable {
    @Inject package init() {}

    @Get
    @JSONResponse
    package func ping() -> Pong { Pong(ok: true) }
}

/// No `@NotFound` — that absence is the fixture.
@Singleton
@WireMVCBootstrap
@Middleware(StampKeys.factory)
package struct FallbackBootstrap: Sendable {
    @Inject package init() {}

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
