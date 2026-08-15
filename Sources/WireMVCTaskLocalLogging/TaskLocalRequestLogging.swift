public import HTTPTypes
public import Logging
public import Wire
// The keys only — no WireMVC type appears in a public signature here.
import WireMVC

// The **task-local** logging target: instead of minting a request logger, it adopts whatever logger the
// runtime already bound as a task-local — swift-log's `withLogger` / `Logger.current`.
//
// Where that matters is Hummingbird, which wraps its whole responder chain in
// `withLogger(logger.with(metadataKey: "hb.request.id", …))`. Adopting it means WireMVC's handler log lines
// and Hummingbird's own carry the *same* id, which minting a second one cannot achieve. spike-30 measured
// that the binding survives the `WireMVCServerTransport` bridge's unstructured `Task {}`, including the
// streaming case where the handler outlives the register closure.
//
// It is not the default. Vapor binds no task-local (its request logger is a stored property on `Request`),
// and the native proposal server binds none either, so on those runtimes this target reads the unbound
// default — an empty-label logger — unless the app adds middleware that binds one. `WireMVCLogging` is the
// runtime-independent choice; this is for apps on a runtime that already owns the logger.
//
// Depend on exactly one. Taking both is a build error, though not the one you might expect: both
// contribute `request-id` to the metadata map, so the duplicate `atKey` is reported first — the two
// unkeyed `Logger` bindings would collide too, but never get that far. Because activation is
// depend-to-activate and transitive, these are application-level dependencies — a *library* depending on
// one would force the choice on everything downstream.
//
// `Logger.current` is read unconditionally, with no is-a-scope-active check. When nothing is bound it
// returns the process-wide default rather than failing, which is exactly what any library reading
// `Logger.current` gets today; a detection scheme would have to compare against swift-log's empty-label
// sentinel, and buying a stringly runtime failure for that is a bad trade.

/// The app-scoped logger, under ``WireMVCApplication/logger`` — a snapshot of the task-local taken at
/// graph construction. Usually nothing is bound that early, so this is normally the `LoggingSystem`
/// default; an app that binds one around its bootstrap gets that instead.
///
/// Note the ordering rule swift-log documents: the unbound default is captured at *first access* and
/// reused for the process lifetime, so `LoggingSystem.bootstrap(_:)` must run before the graph is built.
/// Replace this binding to source the app logger some other way:
///
///     @Provides(WireMVCApplication.logger)
///     @Replaces
///     func appLogger() -> Logger { Logger(label: "my-app") }
@Provides(WireMVCApplication.logger)
public func wireMVCTaskLocalApplicationLogger() -> Logger {
    Logger.current
}

/// The request-scoped logging bindings. A `@Scoped(seed:)` block, so both producers land in the
/// `HTTPRequest` scope and are constructed fresh per request.
@Scoped(seed: HTTPRequest.self)
public enum WireMVCTaskLocalRequestLogging {
    /// The per-request correlation id, under ``WireMVCRequest/id`` — derived from the request exactly as
    /// `WireMVCLogging` derives it, so the id means the same thing whichever target an app picks and
    /// switching between them changes no app code.
    ///
    /// This is deliberately *not* read back out of the adopted logger's metadata. The runtime's own id
    /// lives under a framework-specific key (`hb.request.id`), identifies the request within that one
    /// server, and is already on the line; ``WireMVCRequest/id`` is the cross-service correlation id and
    /// honours an inbound `X-Request-Id` or `traceparent`. Both on a log line is the useful outcome.
    @Provides(WireMVCRequest.id)
    @Contributes(to: WireMVCLogMetadata.stringEntries, atKey: WireMVCLogMetadata.requestID)
    public static func requestID(request: HTTPRequest) -> String {
        WireMVCRequest.correlationID(from: request)
    }

    /// The request-scoped logger — the **unkeyed** `Logger` binding, so a request-scoped type's bare
    /// `@Inject var logger: Logger` resolves here.
    ///
    /// The one line that differs from `WireMVCLogging`: the base is `Logger.current`, snapshotted *during
    /// the request* rather than the app-scoped binding. Contributed fields are folded on top identically,
    /// so an app's `@Contributes` log fields keep working unchanged across a target switch.
    @Provides
    public static func requestLogger(
        @Bind(WireMVCLogMetadata.stringEntries) fields: [String: String]
    ) -> Logger {
        WireMVCLogMetadata.applying(fields, to: .current)
    }
}
