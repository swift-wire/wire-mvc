package import Wire
package import WireMVCBootstrapExample

// Supersede the app's production `ServerConfig` (fixed port 8080) with an OS-ephemeral port (0), so this
// suite's server doesn't collide with the sibling suites' on a shared fixed port. The generated suite trait
// reads the actual bound port back. Provider-for-provider `@Replaces`.

@Provides @Replaces
package func testServerConfig() -> ServerConfig {
    ServerConfig(host: "127.0.0.1", port: 0)
}
