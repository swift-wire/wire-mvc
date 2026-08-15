public import Logging
public import Wire

// The logging contract, declared in the core so every logging target and every app spell the *same*
// keys. Wire matches keyed bindings by the canonical text of the key expression, so the keys have to
// live in one place both `WireMVCLogging` and `WireMVCTaskLocalLogging` (and any app that `@Replaces`
// one of their bindings) can name — otherwise `WireMVCApplication.logger` written against one target
// would not match the other's binding.
//
// Only the *keys* live here. Neither binding is provided by the core: an app picks exactly one
// logging target, and depending on both is a duplicate-binding error on the unkeyed request logger —
// which is the intended "pick one" semantics.
//
// Declaring keys nothing consumes is safe: Wire's single-key diagnostic (7a) errors only on a
// *referenced but undeclared* key, and the no-consumer warning exempts `public` bindings.

/// The **app-scoped** logger — keyed, deliberately. The request-scoped logger is the *unkeyed*
/// `Logger` binding, so a bare `@Inject var logger: Logger` inside a request-scoped type resolves to
/// the per-request one: the easy spelling is the correct one. Outside a request scope that same
/// spelling is a missing-binding error naming `@Scoped(seed: HTTPRequest.self)`, which is the right
/// nudge — reach for `@Inject(WireMVCApplication.logger)` only when you genuinely want the
/// process-wide logger.
public enum WireMVCApplication {
    public static let logger = BindingKey<Logger>()
}

/// The per-request correlation id the request-scoped logger carries as metadata. Keyed so it can be
/// injected on its own (a handler echoing it in a response header, say) without colliding with any
/// other `String` binding. Hangs off the existing `WireMVCRequest` namespace (see RequestBinding.swift)
/// rather than a parallel one — it is a fact about the request.
extension WireMVCRequest {
    public static let id = BindingKey<String>()
}

/// The metadata key the request id is attached under. Exposed so an app formatting its own log lines
/// — or asserting on them in a test — names the same string the bindings write.
public enum WireMVCLogMetadata {
    public static let requestID = "request-id"
}
