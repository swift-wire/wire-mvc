public import HTTPTypes

// The request-dispatch side of the keyed harness (H2.2b). The generated keyed `.wiremvc(_:)` factory builds
// each subject's variant contributor proxy against the variant graph and registers its routes on the router
// directly, so the variant witness *is* the registered instance — there is no production branch to take and
// nothing held in a task-local. Each scoped route's generated dispatch reads the request's ``CorrelationID``
// back off the `X-WireMVC-Test-Binds` header, pulls that controller's doubles from its ``TestBindStore``, and
// enters request scope with them, so a `@BindType`d slot resolves to the supplied mock. A request arriving
// without the header — a keyless suite, or a keyed route driven through `withClient` — finds no doubles and
// is answered with the harness's explicit 500.
//
// The doubles travel by header + store rather than by task-local because a `withClient(supplying:)` closure runs
// client-side, in a task subtree disjoint from the server's: the id on the request is the only thread
// connecting the two.

/// Read a request's ``CorrelationID`` from its `X-WireMVC-Test-Binds` header, or `nil` if the header is
/// absent or malformed — the dispatch side's entry point, keeping the header name and `HTTPTypes` lookup in
/// one place so the generated route code stays a single call. `nil` for every production request (the header
/// is only ever stamped by a ``TestClient`` carrying a binding).
public func wireMVCTestCorrelationID(in request: HTTPRequest) -> CorrelationID? {
    guard let name = HTTPField.Name(wireMVCTestBindsHeader),
        let value = request.headerFields[name]
    else { return nil }
    return correlationID(fromHeaderValue: value)
}
