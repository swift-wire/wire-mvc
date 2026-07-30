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
