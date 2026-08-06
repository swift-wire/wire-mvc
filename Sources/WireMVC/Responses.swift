import BasicContainers
public import HTTPAPIs
public import HTTPTypes

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The response a route produces, computed *before* the response sender is touched — a status, header
/// fields, and an already-encoded body (or none). The generated witness builds one of these (mapping a
/// binding failure to its status), then calls `send(on:)` exactly once, so the `consuming` sender is
/// consumed on a single path. `Sendable` (bytes + status + fields) so it can be captured by a handler.
///
/// A **struct**, where this was a two-case enum (`.body(bytes, status)` / `.status(status)`). The cases
/// only ever differed in whether a body was present — which `body: [UInt8]?` says directly — so adding a
/// third component would have meant duplicating the header fields across both payloads. `.status(_:)` and
/// `.body(_:_:)` survive as static factories, so every construction site is unchanged; only a `switch` over
/// the old cases has to become a read of `body`.
public struct WireMVCOutcome: Sendable {
    /// The response status.
    public var status: HTTPResponse.Status

    /// The response header fields. ``json(_:status:headerFields:coding:)`` seeds
    /// `Content-Type: application/json`; ``status(_:headerFields:)`` and ``body(_:_:headerFields:)`` seed
    /// nothing, because neither knows what the bytes are.
    public var headerFields: HTTPFields

    /// The already-encoded body, or `nil` for a bodiless response — the two shapes the enum's cases used
    /// to carry.
    ///
    /// The distinction picks which `sendAndFinish` overload ``send(on:)`` calls. That is a hint, not a
    /// guarantee: the proposal's bodiless convenience is defined as the buffer form with an empty buffer,
    /// so a `204` and a `200` with zero bytes reach a default conformer identically. It matters only for a
    /// conformer that overrides the requirement to fuse head and body into one transport frame.
    public var body: [UInt8]?

    public init(status: HTTPResponse.Status, headerFields: HTTPFields = [:], body: [UInt8]? = nil) {
        self.status = status
        self.headerFields = headerFields
        self.body = body
    }

    /// A bodiless response — what a `@ResponseStatus` route sends, and what an
    /// `@ErrorResponse(E.self, .status)` mapping folds into the terminal's `catch`.
    ///
    /// `headerFields` is what makes a status-only response able to say the thing its status requires: a
    /// `401` without `WWW-Authenticate` is not a well-formed challenge (RFC 9110 §11.6.1).
    public static func status(
        _ status: HTTPResponse.Status,
        headerFields: HTTPFields = [:]
    ) -> WireMVCOutcome {
        WireMVCOutcome(status: status, headerFields: headerFields)
    }

    /// A response with an already-encoded body. Nothing is inferred from the bytes — a caller handing over
    /// raw bytes owns their `Content-Type`.
    public static func body(
        _ bytes: [UInt8],
        _ status: HTTPResponse.Status,
        headerFields: HTTPFields = [:]
    ) -> WireMVCOutcome {
        WireMVCOutcome(status: status, headerFields: headerFields, body: bytes)
    }

    /// Encode an `Encodable` value as a JSON body with the given status — the outcome-building
    /// convenience an `@ErrorResponse` mapping spells (`.json(Problem(e.message), status: .badRequest)`).
    /// Throwing (encoding can fail); a throw from a mapping propagates out to the framework like any
    /// other unmapped error. Mirrors `WireMVCResponse.json`, surfaced on `WireMVCOutcome` so a mapping
    /// returns one directly.
    ///
    /// `Content-Type: application/json` is seeded unless `headerFields` already carries one, so a caller
    /// can override the spelling (a `+json` media type, a charset) without losing the default everywhere
    /// else. Plain `application/json`, no charset — matching what the OpenAPI generator emits
    /// (`ContentType.applicationJSON`), since one app serves both kinds of route.
    public static func json<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status = .ok,
        headerFields: HTTPFields = [:],
        coding: WireMVCCoding = .default
    ) throws -> WireMVCOutcome {
        let data = try coding.encoder().encode(value)
        var fields = headerFields
        if fields[.contentType] == nil { fields[.contentType] = "application/json" }
        return WireMVCOutcome(status: status, headerFields: fields, body: [UInt8](data))
    }

    /// Send this outcome on the response sender, consuming it. The sender is `consuming` (not `consuming
    /// sending`): the terminal consumes it within its own region, and through a middleware fold it
    /// arrives from the box's `withContents` as a plain `consuming` value (not `sending`).
    public func send<Sender: HTTPResponseSender & ~Copyable>(
        on sender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable {
        let response = HTTPResponse(status: status, headerFields: headerFields)
        if let body {
            var buffer = UniqueArray<UInt8>(copying: body)
            try await sender.sendAndFinish(response, buffer: &buffer)
        } else {
            try await sender.sendAndFinish(response)
        }
    }
}

/// Response encoding the generated witness calls. `@JSONResponse` routes go through `json`;
/// `@ResponseStatus` routes build `.status` inline in the witness.
public enum WireMVCResponse {
    /// `@JSONResponse[(status:)]` — encode an `Encodable` return as a JSON body.
    public static func json<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status,
        headerFields: HTTPFields = [:],
        coding: WireMVCCoding = .default
    ) throws -> WireMVCOutcome {
        try WireMVCOutcome.json(value, status: status, headerFields: headerFields, coding: coding)
    }
}
