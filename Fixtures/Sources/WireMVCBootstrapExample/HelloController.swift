import BasicContainers
import HTTPAPIs
import HTTPTypes
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

    // M5.5 Phase 3: this controller declares no `@ErrorResponse`, so `TenantMissing` is unmapped here.
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
