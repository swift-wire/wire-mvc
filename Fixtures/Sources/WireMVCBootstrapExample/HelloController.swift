import BasicContainers
package import HTTPAPIs
package import HTTPTypes
package import Wire
import WireMVC

// One app-scoped controller. `@Singleton @Controller` is all it needs — WireMVC collates it and the
// generated `@main` registers it. `GET /hello/{name}` → `{"message":"Hello, {name}!"}`.
//
// Generic over `G: Greeter` (the opaque-injection lift): `@Inject let greeter: G` resolves to whichever
// binding produces the `Greeter` key — the app's `RealGreeter`, or a test target's `@Replaces` fake.
// `package` (and package response/error types) so a same-package test target can re-compose it.

@Singleton
@Controller("/hello")
package struct HelloController<G: Greeter> {
    @Inject let greeter: G
    /// The same binding `StampMiddleware` injects — how the handler's result reaches a middleware that
    /// contributes a header after the handler has run.
    @Inject let greetingLog: GreetingLog

    @Get("/{name}")
    @JSONResponse
    package func hello(@Path name: String) -> Greeting {
        Greeting(message: greeter.greet(name))
    }

    // A raw route on an otherwise typed controller. `@RawRoute` hands the handler the primitives and it
    // writes the response itself, so nothing about the payload is derivable — but the request line still is,
    // which is what the generated shim gives a suite: `rawGreeting(name:)` for `GET /hello/raw/{name}`.
    @Get("/raw/{name}")
    @RawRoute
    package func rawGreeting<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        pathParameters: [String: Substring],
        responseSender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        let name = pathParameters["name"].map(String.init) ?? "?"
        var body = UniqueArray<UInt8>(copying: Array("raw:\(greeter.greet(name))".utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
    }

    // Response headers, both sources at once: a route-scope constant, and a computed field returned in a
    // labelled response tuple that also picks the status. The constant is `.append`ed so the two `Vary`
    // values stay separate field lines rather than folding.
    @Get("/etag/{name}")
    @JSONResponse
    @ResponseHeader(.vary, "Accept-Encoding")
    @ResponseHeader(.vary, "Origin", .append)
    @ResponseHeader(.cacheControl, "no-store")
    package func etagged(
        @Path name: String
    ) -> (status: HTTPResponse.Status, headers: HTTPFields, body: Greeting) {
        let greeting = Greeting(message: greeter.greet(name))
        return (.created, [.eTag: "\"\(name.count)\""], greeting)
    }

    // Middleware contributing header fields, over a route that also sets its own. Pins the full order:
    // route constants, then the handler's returned fields, then middleware — so the middleware's
    // `x-stamp: middleware` beats the route's constant, and its deferred `Set-Cookie` (registered on the
    // way in, evaluated after the handler ran) appears alongside.
    @Get("/stamped/{name}")
    @JSONResponse
    @Middleware(StampKeys.factory)
    @ResponseHeader(.init("x-stamp")!, "route")
    @ResponseHeader(.cacheControl, "no-store")
    package func stamped(@Path name: String) -> Greeting {
        // Written to the graph-injected store, which the middleware reads at drain — the handler and the
        // middleware meet through the graph, not through a global.
        greetingLog.record(name, for: name)
        return Greeting(message: greeter.greet(name))
    }

    // Constants with a plain body return — the statics-only path. Worth a fixture of its own: it is the
    // one shape that shares no code with the tuple path, and it shipped broken until a golden test caught
    // it (the contribution array was passed straight to `headerFields:`, which takes `HTTPFields`).
    @Get("/cached/{name}")
    @JSONResponse
    @ResponseHeader(.cacheControl, "public, max-age=60")
    package func cached(@Path name: String) -> Greeting {
        Greeting(message: greeter.greet(name))
    }

    // The bodiless tuple — a computed redirect, the shape 12 of the hummingbird-examples redirect sites
    // need. **No response annotation**: the return type says both things one would carry — no `body` label
    // means no body, `status:` means the status is computed — so `@ResponseStatus` here would declare
    // nothing and is a diagnostic.
    @Get("/moved/{name}")
    package func moved(@Path name: String) -> (status: HTTPResponse.Status, headers: HTTPFields) {
        (.found, [.location: "/hello/\(name)"])
    }

    // The **error** path's contributions, which the served path's tiers above say nothing about. A
    // middleware registers on the way in and cannot know whether the handler will succeed, so a field it
    // contributed has to reach a mapped refusal as well — and this is the shape where losing it hurts
    // most: a browser cannot read a response whose CORS field was dropped, and a `401` without the
    // `WWW-Authenticate` an outer middleware registered is not a well-formed challenge.
    //
    // Mapped by the composition root's global `@ErrorResponse(TenantMissing.self, .badRequest)`, so this
    // also pins that the drain reaches the outermost tier and not only a route-scope mapping.
    // No `@ResponseHeader` here on purpose. Whether a route's *constants* should reach a mapped refusal
    // is a separate question with a real argument on both sides — a `Content-Type` constant would be
    // wrong on a bodiless status — and this route is about the middleware drain, which has no such
    // argument against it. The constants stay out so the test cannot be read as settling it.
    @Get("/refused/{name}")
    @JSONResponse
    @Middleware(StampKeys.factory)
    package func refused(@Path name: String) throws -> Greeting {
        // Recorded *before* the throw, so the middleware's deferred closure has something to find. That is
        // the point of the test: the drain runs after the handler on this path too.
        greetingLog.record(name, for: name)
        throw TenantMissing()
    }

    // This controller declares no `@ErrorResponse`, so `TenantMissing` is unmapped here.
    // The `@WireMVCBootstrap` composition root's global `@ErrorResponse(TenantMissing.self, .badRequest)`
    // is the default tier folded into this route's terminal — so `GET /hello/tenant` returns 400.
    @Get("/tenant")
    @JSONResponse
    package func tenant() throws -> Greeting {
        throw TenantMissing()
    }
}

package struct Greeting: Codable, Sendable {
    package let message: String
    package init(message: String) { self.message = message }
}

package struct TenantMissing: Error {
    package init() {}
}
