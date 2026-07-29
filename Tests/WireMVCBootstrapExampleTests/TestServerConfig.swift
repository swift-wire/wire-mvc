// The retroactive `NIOHTTPServer: WireMVCTestServer` conformance. The generated `.wiremvc(_:)` factory
// emits both mode branches, and the live one hands this app's `NIOHTTPServer` to `serveForSuite`, whose
// bound requires that conformance — so it has to be imported by this module. Conformance lookup is
// module-wide, so this one import covers the generated file too.
import WireMVCTestingNIOHTTPServer

package import Wire
package import WireMVCBootstrapExample

// Supersede the app's production `ServerConfig` (fixed port 8080) with an OS-ephemeral port (0) for this
// test target, so this suite's server doesn't collide with the sibling replace-suite's on a shared fixed
// port. The `.wiremvc()` suite trait reads the actual bound port back. Provider-for-provider `@Replaces`: this
// supersedes the app's `@Provides serverConfig()`, also demonstrating `@Replaces` on a config value.

@Provides @Replaces
package func testServerConfig() -> ServerConfig {
    ServerConfig(host: "127.0.0.1", port: 0)
}
