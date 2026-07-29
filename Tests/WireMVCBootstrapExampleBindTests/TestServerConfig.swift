package import Wire
package import WireMVCBootstrapExample
// The retroactive `NIOHTTPServer: WireMVCTestServer` conformance. The generated `.wiremvc(_:)` factory
// emits both mode branches, and the live one hands this app's `NIOHTTPServer` to `serveForSuite`, whose
// bound requires that conformance — so it has to be imported by this module. Conformance lookup is
// module-wide, so this one import covers the generated file too.
import WireMVCTestingNIOHTTPServer

// Supersede the app's production `ServerConfig` (fixed port 8080) with an OS-ephemeral port (0), so this
// suite's server doesn't collide with the sibling suites' on a shared fixed port. The generated suite trait
// reads the actual bound port back. Provider-for-provider `@Replaces`.

@Provides @Replaces
package func testServerConfig() -> ServerConfig {
    ServerConfig(host: "127.0.0.1", port: 0)
}
