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

/// The per-request logger's metadata, as a map anything can contribute to.
///
/// The request logger is built by folding every contribution into the app logger, so adding a field is a
/// `@Contributes` — not an edit to WireMVC. A distributed-tracing integration contributes its trace and
/// span ids this way; so does an app that wants a tenant id on every line:
///
///     enum TracingKeys {
///         static let traceID = BindingKey<String>()
///     }
///
///     @Scoped(seed: HTTPRequest.self)
///     enum TracingMetadata {
///         @Provides(TracingKeys.traceID)
///         @Contributes(to: WireMVCLogMetadata.stringEntries, atKey: "trace-id")
///         static func traceID(span: Span) -> String { span.traceID }
///     }
///
/// A field is therefore an ordinary binding that *also* logs itself: `TracingKeys.traceID` is injectable
/// on its own (`@Inject(TracingKeys.traceID) var traceID: String`) and appears on every log line, from one
/// declaration. The `@Provides` needs its key because `@Contributes` requires a co-located producer and an
/// *unkeyed* producer would declare a second plain `String` binding, colliding with every other field.
///
/// The map is `String`-valued because that is what log metadata overwhelmingly is. A field of another type
/// wants a sibling map (`intEntries`, and so on) folded alongside — deliberately not built until something
/// needs it, since each one is a few lines and guessing the set now would be guessing.
///
/// **Contributors must be request-scoped.** A seed scope's multibindings aggregate from that scope's own
/// contributors only — an app-scoped contribution stays with the default graph and never reaches the
/// request logger. That is a silent omission rather than an error, so it is the one thing to get right.
public enum WireMVCLogMetadata {
    public static let stringEntries = MappedKey<String, String>()

    /// The key the request id is attached under. Exposed so an app formatting its own log lines — or
    /// asserting on them in a test — names the same string the binding writes.
    public static let requestID = "request-id"
}
