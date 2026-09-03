import BasicContainers
package import HTTPAPIs
import HTTPTypes
import Logging
package import NIOHTTPServer
package import Wire
package import WireMVC
import WireMVCRouter

// The WireMVC-native composition root. `@Singleton` makes it a graph binding (its `@Inject` resolves);
// `@WireMVCBootstrap` makes the plugin generate the program entry point (`@main`) for a program consumer,
// or the companion `.wiremvc()` suite-trait factory for a test consumer. There is no `main.swift` and no
// hand-written `@main` — `swift run WireMVCBootstrapExample` bootstraps the graph, constructs this type,
// registers the collated `HelloController` onto the package `WireRouter`, and serves on `127.0.0.1:8080`
// (the port its `ServerConfig` binding carries).

@Singleton
@WireMVCBootstrap
@ErrorResponse(TenantMissing.self, .badRequest)  // global default tier — folds into every route
@Middleware(AccessLogKeys.factory)  // global front layer — wraps every request incl. the 404 fallback
package struct AppBootstrap {
    @Inject let config: ServerConfig
    @Inject let startup: StartupReport

    /// The **pre-step**: runs before `Wire.bootstrap`, and its return value is the graph's `inputs:`.
    ///
    /// This is where the one-time work that must precede construction goes — `LoggingSystem.bootstrap`
    /// and its metrics/tracing counterparts, which trap on a second call — and where the values the graph
    /// cannot derive for itself are read and handed in. Being pre-graph it can inject nothing; that is the
    /// trade for running first.
    ///
    /// Under a test bundle the generated entry routes this through `WireMVCTesting.preparedOnce`, so a
    /// second suite reuses the first one's result instead of re-running the once-per-process work.
    package static func prepare() async throws -> AppInputs {
        StartupProbe.recordPrepare()
        // Where `LoggingSystem.bootstrap(...)` would go: before the graph, so the first binding to log
        // already has the real handler installed.
        return AppInputs(
            serverConfig: ServerConfig(host: "127.0.0.1", port: 8080),
            releaseChannel: "stable"
        )
    }

    // Returns the *concrete* server, not `some HTTPServer`: the proposal's `Reader`/`ResponseSender`
    // are `~Copyable`, which a bare `some HTTPServer` opaque return can't express. The generated
    // `@main` binds to whatever concrete type this returns.
    package func createServer() throws -> NIOHTTPServer {
        NIOHTTPServer(
            logger: Logger(label: "WireMVCBootstrapExample"),
            configuration: try .init(
                bindTarget: .hostAndPort(host: config.host, port: config.port),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )
    }

    // The package-provided `TrieRouteBuilder` is a `FinalizableHTTPServerRouteBuilder`: `WireMVC.apply`
    // registers routes onto it, and the generated `@main` `finalize()`s it into the immutable
    // `FrozenTrieRouter` the server serves (build → freeze → serve).
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

    // Mount the graph's wiring model (`introspect()` as JSON) at `/wiring`. Returning `nil` skips it.
    // The generated `@main` registers it before `finalize()`, so it's a real route (the front layer wraps it).
    // The route-scoped `@Middleware` guards *only* `/wiring` (folded via the proxy's `registerIntrospection`),
    // unlike the global `@Middleware(AccessLogKeys.factory)` on the type.
    @Middleware(IntrospectionGuardKeys.factory)
    package func mountIntrospectionAt() -> String? { "/wiring" }

    // The fallback for unmatched requests — a `@RawRoute` handler that writes the response
    // itself. Being a Bootstrap method it's DI-capable (it could use `self.config`); the generated `@main`
    // registers it via `registerNotFound`, before `finalize()`, so it's a real route (the global tiers
    // fold into it). Without it, the plugin would synthesise a plain 404.
    //
    // Its sender is declared **`consuming sending`**, the other half of the acceptance case (see
    // `PingController.pingSending` in the fallback fixture for the folded half). A `@NotFound` is the
    // fold-less shape by construction: `registerNotFound` folds no middleware, so it can never be handed a
    // transformed sender, which is why it was the one route this spelling could never work on.
    @NotFound
    @RawRoute
    package func handleNotFound<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming sending Sender
    ) async throws where Sender.Writer: ~Copyable {
        var body = UniqueArray<UInt8>(copying: Array("no route here\n".utf8))
        try await responseSender.sendAndFinish(HTTPResponse(status: .notFound), buffer: &body)
    }
}
