// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import HTTPAPIs
package import HTTPTypes
import Logging
package import NIOHTTPServer
import ServiceLifecycle
package import Wire
package import WireMVC
import WireMVCRouter

// A third `@WireMVCBootstrap` app, whose subject is a **typed** `@NotFound`: a fallback that answers with
// a JSON body through `@JSONResponse`, rather than writing the response itself through `@RawRoute`.
//
// The other two bootstrap fixtures cover the other two fallbacks. `WireMVCBootstrapExample` writes a raw
// one, and `WireMVCFallbackExample` declares none and gets the synthesised 404. A typed fallback goes
// through the same terminal a route does, so what this app proves is that the terminal's guarantees hold
// with no route template behind them: the body is encoded with the app's coding, the response states its
// `Content-Length`, a global `@Middleware`'s header reaches it, and both the handler's own `@ErrorResponse`
// and the Bootstrap's map what it throws.

package enum StampKeys {
    package static let factory = FactoryKey()
}

/// Contributes `x-stamp: global` on the way in; it must reach the typed fallback as well as `/ping`.
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
        try await input.contributing { headers in
            headers.add(.set(.init("x-stamp")!, "global"))
        } then: { input in
            try await next(input)
        }
    }
}

/// The fallback's body, and the body its route-scope error mapping answers with.
package struct Problem: Codable, Sendable, Equatable {
    package let detail: String
    package init(detail: String) { self.detail = detail }
}

/// Thrown by the fallback when asked for a path that once existed; mapped at **route** scope, to 410 with
/// a body.
package struct Withdrawn: Error {
    package let reason: String
}

/// Thrown by the fallback when asked to; mapped at the **Bootstrap**'s scope, which is the global tier, to
/// a bodiless 503.
package struct Unavailable: Error {}

package struct Pong: Codable, Sendable, Equatable {
    package let alive: Bool
    package init(alive: Bool) { self.alive = alive }
}

/// One route, so a matched request has somewhere to go and a wrong method is a 405 rather than a 404.
@Singleton
@Controller("/ping")
package struct PingController: Sendable {
    @Inject package init() {}

    @Get
    @JSONResponse
    package func ping() -> Pong { Pong(alive: true) }
}

@Singleton
@WireMVCBootstrap
@Middleware(StampKeys.factory)
@ErrorResponse(Unavailable.self, .serviceUnavailable)
package struct TypedFallbackBootstrap: Sendable {
    @Inject package init() {}

    /// The fallback, typed. `@Query` binds as it does on a route, because it needs no template; only
    /// `@Path` would, and is diagnosed. `hint` is how the tests reach each error tier.
    @NotFound
    @JSONResponse(status: .notFound)
    @ErrorResponse(Withdrawn.self, .gone, { Problem(detail: $0.reason) })
    package func notFound(@Query hint: String?) throws -> Problem {
        switch hint {
        case "withdrawn": throw Withdrawn(reason: "this was withdrawn")
        case "unavailable": throw Unavailable()
        default: return Problem(detail: "no route matches this request")
        }
    }

    package func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(
            logger: Logger(label: "WireMVCTypedFallbackExample"),
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
