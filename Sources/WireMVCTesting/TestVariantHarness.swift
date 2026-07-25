public import HTTPTypes
import Synchronization

// The request-dispatch side of the keyed harness (H2.2b). The generated keyed `.wiremvc(_:)` factory builds
// the H2.2a variant contributor proxy once (against the reused production graph) and parks it in a
// per-key ``WireMVCVariantProxyBox``; each scoped route's generated dispatch, on a request that carries the
// `X-WireMVC-Test-Binds` header, reads the request's ``CorrelationID`` back off the header, pulls that
// closure's doubles from the per-key ``TestBindStore``, and enters request scope through the parked variant
// proxy — so a `@BindType`d slot resolves to the supplied mock. A request with no header, or under a graph
// the keyless `.wiremvc()` stood up, takes the untouched production scope entry.

/// A set-once, `Sendable` holder for a key's H2.2a variant contributor proxy. The generated keyed factory
/// builds the proxy from the graph (via the `Wire.bootstrap<Variant>_<Subject>Contributor(wireGraph:)`
/// facade) and ``set(_:)``s it before the server starts serving; each scoped route's dispatch ``get()``s it
/// per request. `Mutex`-guarded so the write (suite entry) happens-before the reads (request handlers), with
/// no data race. `Proxy` is the concrete generated variant-proxy type, so the dispatch calls its stored
/// `_wireEnterScope` closure directly — no boxing.
public final class WireMVCVariantProxyBox<Proxy: Sendable>: Sendable {
    private let storage = Mutex<Proxy?>(nil)

    /// A new, empty box — one per (key, subject), held as a generated static.
    public init() {}

    /// Park the built variant proxy. Called once by the generated keyed factory at suite entry, before
    /// serving begins, so every request handler that later reads it sees the built value.
    public func set(_ proxy: Proxy) {
        storage.withLock { $0 = proxy }
    }

    /// The parked variant proxy, or `nil` if the box was never set — which the dispatch treats as a missing
    /// double (an explicit 500), so a keyed request under a graph that didn't build the proxy fails loudly
    /// rather than silently taking the production path.
    public func get() -> Proxy? {
        storage.withLock { $0 }
    }
}

/// Read a request's ``CorrelationID`` from its `X-WireMVC-Test-Binds` header, or `nil` if the header is
/// absent or malformed — the dispatch side's entry point, keeping the header name and `HTTPTypes` lookup in
/// one place so the generated route code stays a single call. `nil` for every production request (the header
/// is only ever stamped by ``TestClient`` inside a `withBindValues` closure).
public func wireMVCTestCorrelationID(in request: HTTPRequest) -> CorrelationID? {
    guard let name = HTTPField.Name(wireMVCTestBindsHeader),
        let value = request.headerFields[name]
    else { return nil }
    return correlationID(fromHeaderValue: value)
}
