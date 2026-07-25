public import HTTPTypes

// The request-dispatch side of the keyed harness (H2.2b). The generated keyed `.wiremvc(_:)` factory builds
// the H2.2a variant contributor proxy once (against the reused production graph) and binds it to a per-key
// `@TaskLocal` *around* `serveForSuite`, so it rides the serve task tree into every request handler; each
// scoped route's generated dispatch, on a request that carries the `X-WireMVC-Test-Binds` header, reads the
// request's ``CorrelationID`` back off the header, pulls that closure's doubles from the per-key
// ``TestBindStore``, and enters request scope through that variant proxy — so a `@BindType`d slot resolves to
// the supplied mock. A request served where the task-local is unbound (a keyless `.wiremvc()` suite, or any
// production serving) reads `nil` and takes the untouched production scope entry.
//
// The task-local replaces an earlier process-global holder: a suite-level value bound around `serve`
// propagates to the handler (structured child tasks inherit it) *and* isolates across concurrently-served
// suites, so parallel keyless and keyed suites can't cross. The per-request doubles still travel by header +
// ``TestBindStore`` — a `withBindValues` closure runs client-side, in a task subtree disjoint from the server's.

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
