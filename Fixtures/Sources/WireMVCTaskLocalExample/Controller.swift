import HTTPTypes
import Logging
import Wire
import WireMVC
// The request-scoped `Logger` binding composes in from here — no symbol in this file names the module,
// but removing the import removes the binding from the graph. Swapping this one line for
// `import WireMVCLogging` is the entire difference between the two logging targets, from an app's side.
import WireMVCTaskLocalLogging

/// What the route reports back, so the driver can assert on what the *handler* actually held.
struct Probe: Codable, Sendable {
    /// The marker the task-local logger was bound with, read off the injected logger's metadata.
    let loggerMarker: String
    /// The request-scoped correlation id, read off the same logger.
    let loggerRequestID: String
    /// The same id injected on its own — the field binding's other job.
    let injectedRequestID: String
}

/// The metadata key the driver binds its probe logger with. Not a Wire key — just a metadata key, chosen
/// so it cannot collide with anything the target itself writes.
enum ProbeMetadata {
    static let marker = "probe-marker"
}

@Scoped(seed: HTTPRequest.self)
@Controller("/probe")
struct ProbeController: Sendable {
    /// Unkeyed, so it resolves to `WireMVCTaskLocalLogging`'s request-scoped binding — which takes its
    /// base from `Logger.current` rather than from the app-scoped logger.
    @Inject var logger: Logger
    @Inject(WireMVCRequest.id) var requestID: String

    @Get
    @JSONResponse
    func get() -> Probe {
        logger.info("probe handled")
        return Probe(
            loggerMarker: logger[metadataKey: ProbeMetadata.marker].map { "\($0)" } ?? "<absent>",
            loggerRequestID: logger[metadataKey: WireMVCLogMetadata.requestID].map { "\($0)" } ?? "<absent>",
            injectedRequestID: requestID
        )
    }
}
