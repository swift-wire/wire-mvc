public import HTTPTypes
public import Logging
public import Wire
// The keys only — no WireMVC type appears in a public signature here.
import WireMVC

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// The **default** logging target: WireMVC mints the request logger itself, from the app-scoped logger
// plus a per-request correlation id. Nothing outside the graph is consulted, so it behaves identically
// on every runtime — the native proposal server, Hummingbird and Vapor via `WireMVCServerTransport`,
// and OpenAPI controllers.
//
// The alternative is `WireMVCTaskLocalLogging`, which *adopts* whatever logger the runtime already
// bound as a task-local (Hummingbird's, carrying `hb.request.id`). Depend on exactly one: both provide
// the unkeyed request-scoped `Logger`, so taking both is a duplicate-binding error. Because activation
// is depend-to-activate and transitive, these are application-level dependencies — a *library* that
// depended on one would force that choice on everything downstream.
//
// Every binding here is `@Replaces`-able from the app (a consumer superseding a dependency's binding
// for the same key is exactly what `@Replaces` does), so "custom id scheme" and "custom logger" need
// no configuration surface of their own.

/// The app-scoped logger, under ``WireMVCApplication/logger``. A plain labelled logger — replace it
/// from the app to control the label, log level, or handler:
///
///     @Provides(WireMVCApplication.logger)
///     @Replaces
///     func appLogger() -> Logger { Logger(label: "my-app") }
@Provides(WireMVCApplication.logger)
public func wireMVCApplicationLogger() -> Logger {
    Logger(label: "WireMVC")
}

/// The request-scoped logging bindings. A `@Scoped(seed:)` block, so both producers land in the
/// `HTTPRequest` scope without repeating the seed — and both are therefore constructed fresh per
/// request, from that request.
@Scoped(seed: HTTPRequest.self)
public enum WireMVCRequestLogging {
    /// The per-request correlation id, under ``WireMVCRequest/id``.
    ///
    /// Prefers an id the caller already supplied, so a request keeps one identity across services:
    /// `X-Request-Id` first, then the trace-id field of a W3C `traceparent`. Falls back to a fresh
    /// UUID when the request carries neither.
    ///
    /// One declaration doing both jobs: it is the injectable `WireMVCRequest.id` binding *and* the
    /// `request-id` field on every log line. That is the shape every field takes here.
    ///
    /// Replace it from the app for a different scheme (a ULID, or trusting a different header) — the
    /// replacement inherits the contribution, since `@Replaces` supersedes the whole binding:
    ///
    ///     @Provides(WireMVCRequest.id)
    ///     @Replaces
    ///     static func requestID(request: HTTPRequest) -> String { … }
    @Provides(WireMVCRequest.id)
    @Contributes(to: WireMVCLogMetadata.stringEntries, atKey: WireMVCLogMetadata.requestID)
    public static func requestID(request: HTTPRequest) -> String {
        if let supplied = header("x-request-id", of: request), !supplied.isEmpty {
            return supplied
        }
        // traceparent: <version>-<trace-id>-<parent-id>-<flags>; the trace-id is the correlating part.
        if let traceparent = header("traceparent", of: request) {
            let fields = traceparent.split(separator: "-")
            if fields.count >= 2, !fields[1].isEmpty { return String(fields[1]) }
        }
        return UUID().uuidString
    }

    /// The request-scoped logger — the **unkeyed** `Logger` binding, so a request-scoped type's bare
    /// `@Inject var logger: Logger` resolves here.
    ///
    /// It is the app logger with every contributed field folded in, so handler log lines correlate
    /// without any per-call-site work, and a new field is a `@Contributes` rather than an edit here. The
    /// app logger arrives as a borrowed app singleton (keyed, hence `@Bind`); it is not reconstructed
    /// per request.
    @Provides
    public static func requestLogger(
        @Bind(WireMVCApplication.logger) base: Logger,
        @Bind(WireMVCLogMetadata.stringEntries) fields: [String: String]
    ) -> Logger {
        var logger = base
        for (key, value) in fields { logger[metadataKey: key] = .string(value) }
        return logger
    }

    /// Read a header by name, tolerating a name the `HTTPField.Name` parser rejects.
    static func header(_ name: String, of request: HTTPRequest) -> String? {
        guard let field = HTTPField.Name(name) else { return nil }
        return request.headerFields[field]
    }
}
