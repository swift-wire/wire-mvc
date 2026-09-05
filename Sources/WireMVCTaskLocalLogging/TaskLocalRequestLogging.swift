// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// `HTTPRequest` names the seed scope; it appears in no public signature here, so a plain import.
import HTTPTypes
public import Logging
public import Wire
// The keys only — no WireMVC type appears in a public signature here.
import WireMVC

// The **task-local** logging target: instead of minting a request logger, it adopts whatever logger the
// runtime already bound as a task-local — swift-log's `withLogger` / `Logger.current`.
//
// Where that matters is Hummingbird, which wraps its whole responder chain in
// `withLogger(logger.with(metadataKey: "hb.request.id", …))`. Adopting it means WireMVC's handler log lines
// and Hummingbird's own carry the *same* id, which minting a second one cannot achieve. It was measured
// that the binding survives the `WireMVCServerTransport` bridge's unstructured `Task {}`, including the
// streaming case where the handler outlives the register closure.
//
// It is not the default. Vapor binds no task-local (its request logger is a stored property on `Request`),
// and the native proposal server binds none either, so on those runtimes this target reads the unbound
// default — an empty-label logger — unless the app adds middleware that binds one. `WireMVCLogging` is the
// runtime-independent choice; this is for apps on a runtime that already owns the logger.
//
// Depend on exactly one: both provide the unkeyed request-scoped `Logger`, so taking both is a
// duplicate-binding error. Because activation is depend-to-activate and transitive, these are
// application-level dependencies — a *library* depending on one would force the choice on everything
// downstream.
//
// **No `WireMVCRequest.id` here.** This target deliberately does not provide the id binding, which is the
// one place the two targets are not interchangeable. Minting an id would put a *second* identifier on
// every line beside the runtime's own — two ids for one request, disagreeing, which is precisely the
// confusion adopting the runtime's logger is meant to end. Extracting the runtime's id instead cannot be
// done here either: it lives under a framework-specific key (`hb.request.id`) that a framework-agnostic
// target cannot name, and on a runtime that binds no task-local at all there would be nothing to extract
// and the fallback would be... a minted id, back where we started.
//
// An app knows its runtime, so it can do what this target cannot:
//
//     @Scoped(seed: HTTPRequest.self)
//     enum RuntimeRequestID {
//         @Provides(WireMVCRequest.id)
//         static func id() -> String {
//             Logger.current[metadataKey: "hb.request.id"].map { "\($0)" } ?? ""
//         }
//     }
//
// Note the missing `@Contributes`: the id is already on the line under the runtime's key, so contributing
// it again would re-create the double-id problem. Providing and contributing are separate annotations
// precisely so this case can have one without the other.
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

/// The request-scoped logger — the **unkeyed** `Logger` binding, so a request-scoped type's bare
/// `@Inject var logger: Logger` resolves here.
///
/// The base is `Logger.current`, snapshotted *during the request*: whatever id the runtime put on it is
/// already there, under the runtime's own key. Contributed ``WireMVCLogMetadata/stringEntries`` fold on
/// top exactly as in `WireMVCLogging`, so an app's `@Contributes` log fields keep working unchanged.
///
/// A `@Scoped(seed:)` block for one binding, so adding a second later needs no restructuring.
@Scoped(seed: HTTPRequest.self)
public enum WireMVCTaskLocalRequestLogging {
    @Provides
    public static func requestLogger(
        @Bind(WireMVCLogMetadata.stringEntries) fields: [String: String]
    ) -> Logger {
        WireMVCLogMetadata.applying(fields, to: .current)
    }
}
