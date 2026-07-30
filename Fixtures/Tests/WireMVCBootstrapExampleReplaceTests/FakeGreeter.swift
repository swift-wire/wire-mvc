package import Wire
package import WireMVCBootstrapExample

// The test double: supersedes the app's `RealGreeter` for the `Greeter` key via `@Replaces`. Because this
// target re-composes the app's graph (the app carries `_WireExports.swift`), `@Replaces`
// makes this fake win over the app's real binding instead of colliding. `GET /hello/Alice` then answers
// the fake's `FAKE:Alice` rather than the real `Hello, Alice!`.

@Singleton(as: Greeter.self)
@Replaces
package struct FakeGreeter: Greeter {
    @Inject package init() {}
    package func greet(_ name: String) -> String { "FAKE:\(name)" }
}
