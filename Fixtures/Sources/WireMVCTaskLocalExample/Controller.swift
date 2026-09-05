// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes
import Logging
import Wire
import WireMVC

// `WireMVCTaskLocalLogging`'s bindings compose in because this *target depends on it* — activation is
// depend-to-activate, and the plugin finds it by its dependency on the `Wire` product
// (`WireMVCBuildPlugin.swift`). Imports have nothing to do with it: the generated graph emits its own
// `import WireMVCTaskLocalLogging` to name the providers. So there is deliberately no import here —
// nothing in this file names one of its symbols.

/// What the route reports back, so the driver can assert on what the *handler* actually held.
struct Probe: Codable, Sendable {
    /// The marker the task-local logger was bound with, read off the injected logger's metadata.
    let loggerMarker: String
    /// The runtime's own request id, as it appears on the injected logger.
    let loggerRuntimeID: String
    /// The same id reached through `WireMVCRequest.id` — the app-side extraction binding below.
    let injectedRequestID: String
    /// Every metadata key on the logger, sorted. Asserting on the whole set is how the fixture shows
    /// there is no *second* id field; a spot-check for a present key could never show that.
    let metadataKeys: [String]
}

enum ProbeMetadata {
    /// The key the driver binds its marker under.
    static let marker = "probe-marker"
    /// Stands in for `hb.request.id` — the framework-specific key a runtime puts its own id under.
    static let runtimeRequestID = "runtime.request.id"
}

/// The app-side recipe `WireMVCTaskLocalLogging` documents but cannot ship: an app knows which runtime it
/// is on, so it can name the metadata key that runtime uses and republish the id as `WireMVCRequest.id`.
///
/// Deliberately `@Provides` **without** `@Contributes`: the id is already on the line under the runtime's
/// key, so contributing it would put a second, redundant id field beside it.
@Scoped(seed: HTTPRequest.self)
enum RuntimeRequestID {
    @Provides(WireMVCRequest.id)
    static func id() -> String {
        Logger.current[metadataKey: ProbeMetadata.runtimeRequestID].map { "\($0)" } ?? ""
    }
}

@Scoped(seed: HTTPRequest.self)
@Controller("/probe")
struct ProbeController: Sendable {
    /// Unkeyed, so it resolves to `WireMVCTaskLocalLogging`'s request-scoped binding — which takes its
    /// base from `Logger.current` rather than from the app-scoped logger.
    @Inject var logger: Logger
    /// Resolves to the app's extraction binding above, not to anything WireMVC provides.
    @Inject(WireMVCRequest.id) var requestID: String

    @Get
    @JSONResponse
    func get() -> Probe {
        logger.info("probe handled")
        return Probe(
            loggerMarker: logger[metadataKey: ProbeMetadata.marker].map { "\($0)" } ?? "<absent>",
            loggerRuntimeID: logger[metadataKey: ProbeMetadata.runtimeRequestID].map { "\($0)" }
                ?? "<absent>",
            injectedRequestID: requestID,
            // `Logger` exposes metadata only per key; the whole set lives on its handler.
            metadataKeys: logger.handler.metadata.keys.sorted()
        )
    }
}
