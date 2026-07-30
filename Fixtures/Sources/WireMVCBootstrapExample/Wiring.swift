package import Wire

// The graph's plain bindings. `@Singleton`/`@Provides` make each a node `Wire.bootstrap()` constructs and
// injects — the controller injects `Greeter`, the composition root injects `ServerConfig`. Every
// participating declaration is `package` (with `package import Wire`) so a test target in this package can
// re-parse and re-compose these bindings — and supersede one with `@Replaces`.

/// The greeting contract the controller injects behind an `as:` key. A protocol (not a concrete type) so a
/// test target can supersede the app's real implementation with a fake via `@Replaces` — the
/// opaque-injection lift: the controller is generic over `G: Greeter`, resolved to whichever binding
/// produces the `Greeter` key.
package protocol Greeter: Sendable {
    func greet(_ name: String) -> String
}

/// The production greeter, bound under the `Greeter` key. `package` so a same-package test target can
/// re-compose (and replace) it across the module boundary.
@Singleton(as: Greeter.self)
package struct RealGreeter: Greeter {
    @Inject package init() {}
    package func greet(_ name: String) -> String { "Hello, \(name)!" }
}

/// The server bind config the composition root injects. `package` so a test target re-composing the app can
/// supersede the production port with an OS-ephemeral `0` — see `serverConfig()`.
package struct ServerConfig: Sendable {
    package let host: String
    package let port: Int
    package init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// The production binding for `ServerConfig` — a `@Provides` factory binding the fixed production port
/// `8080`. Its provider form lets a test target's `@Provides @Replaces` supersede it
/// provider-for-provider, swapping in an ephemeral port so parallel test servers don't collide on `8080`.
@Provides package func serverConfig() -> ServerConfig {
    ServerConfig(host: "127.0.0.1", port: 8080)
}
