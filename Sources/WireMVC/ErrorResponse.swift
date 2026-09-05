// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

// The runtime the generated terminal `catch` folds an `@ErrorResponse` chain onto. Each entry is one
// `wireMVCRespond` call — a typed mapping consulted in order, returning `nil` to fall through to the
// next — with `wireMVCRespondAny` as the `Swift.Error` catch-all (always matches, non-optional). Both
// are declared `throws` (not `rethrows`) so the generated `try` over the whole chain is always valid,
// whether or not a given mapping actually throws — the codegen doesn't need to read each mapping's
// effects. A mapping's own throw propagates out to the framework like any other unmapped error.
// See Notes/RouteErrorHandling.md.

/// Apply a typed error mapping if the thrown error is an `E`, else `nil` (fall through). The mapping is a
/// static `(E) throws -> WireMVCOutcome` — a referenced method or an inline closure; `E` is inferred from
/// it, so the generated call is just `wireMVCRespond(to: error, <mapping>)`.
public func wireMVCRespond<E: Error>(
    to error: any Error,
    _ respond: (E) throws -> WireMVCOutcome
) throws -> WireMVCOutcome? {
    guard let typed = error as? E else { return nil }
    return try respond(typed)
}

/// The `Swift.Error` catch-all — always matches, so it needs no cast and yields a non-optional outcome
/// (the terminal of the chain). A separate name (not an `E == any Error` overload) keeps the generated
/// call unambiguous.
public func wireMVCRespondAny(
    to error: any Error,
    _ respond: (any Error) throws -> WireMVCOutcome
) throws -> WireMVCOutcome {
    try respond(error)
}

/// The body-returning form — `@ErrorResponse(E.self, .notFound, { e in Problem(…) })`.
///
/// The pair form answers with a status and nothing else, which is all a response *without* a body can
/// carry. This one exists for the response that documents a body: the closure produces the value, and the
/// status says which response it belongs to. Both are needed because only the document knows which is
/// legal — a spec-driven adapter can then require the form that matches what it declares.
///
/// The matched type is passed explicitly rather than inferred: the closure's parameter is often written
/// without an annotation, and `E` has to be pinned for the cast.
public func wireMVCRespond<E: Error, Body: Encodable>(
    to error: any Error,
    as type: E.Type,
    status: HTTPResponse.Status,
    _ body: (E) throws -> Body
) throws -> WireMVCOutcome? {
    guard let typed = error as? E else { return nil }
    return try .json(body(typed), status: status)
}

/// The catch-all's body-returning form: always matches, so it yields a non-optional outcome.
public func wireMVCRespondAny<Body: Encodable>(
    to error: any Error,
    status: HTTPResponse.Status,
    _ body: (any Error) throws -> Body
) throws -> WireMVCOutcome {
    try .json(body(error), status: status)
}
