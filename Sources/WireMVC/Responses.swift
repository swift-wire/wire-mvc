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
        // The outcome is computed before the sender is touched, so the body — and therefore its length —
        // is already in hand.
        var response = HTTPResponse(status: status, headerFields: headerFields)
        response.stateLengthIfAbsent(body?.count ?? 0)
        if let body {
            var buffer = UniqueArray<UInt8>(copying: body)
            try await sender.sendAndFinish(response, buffer: &buffer)
        } else {
            try await sender.sendAndFinish(response)
        }
    }
}

extension HTTPResponse {
    /// State `Content-Length` when the length is known, the field is absent, and the status permits it.
    ///
    /// Every one-shot response WireMVC writes goes through here, because nothing below it infers a length
    /// — not the `ServerTransport` bridge, not `NIOHTTPServer`, whose only `Content-Length` is the one it
    /// writes for an aborted request. A response that does not say how long it is goes out
    /// `Transfer-Encoding: chunked`, which measured a p99 tail on every server tested (+12 µs on
    /// Hummingbird, +14 on Vapor, +19 on the proposal server) and is worse for `HEAD`, caching and proxies
    /// besides. Public because a hand-written raw route that writes its own head needs the same rule.
    ///
    /// RFC 9110 §8.6 excludes `1xx` and `204`. `304` is excluded for a different reason: it carries the
    /// length the `200` *would* have had, which a response that never computed that body cannot know, so
    /// stating `0` would be a lie rather than an omission.
    ///
    /// An existing value is never replaced. That is what lets a `HEAD` response state the `GET` body's
    /// length, which is deliberately not the length of what it writes.
    public mutating func stateLengthIfAbsent(_ length: Int) {
        guard headerFields[.contentLength] == nil else { return }
        guard status.kind != .informational, status.code != 204, status.code != 304 else { return }
        headerFields[.contentLength] = String(length)
    }
}

/// What a contributor does to a field it names. The vocabulary is the ecosystem's, not an invention here:
/// Go's `Header.Set`/`Add`, the Rust `http` crate's `insert`/`append`, tower-http's
/// `SetResponseHeaderLayer::overriding`/`appending`/`if_not_present`. Every one of them exists because
/// `Set-Cookie` cannot be folded, and every header contributor eventually needs the distinction.
public enum ResponseHeaderVerb: Sendable {
    /// Replace every value this field already has.
    case set
    /// Add a value, keeping the ones already there — a **separate field line**, never a folded value.
    case append
    /// Set only if the field is absent, so a contributor further in wins.
    case setIfAbsent
}

/// One contribution to the response's header fields. The case *is* the verb.
public enum ResponseHeaderContribution: Sendable {
    case set(HTTPField.Name, String)
    case append(HTTPField.Name, String)
    case setIfAbsent(HTTPField.Name, String)

    var name: HTTPField.Name {
        switch self {
        case let .set(name, _), let .append(name, _), let .setIfAbsent(name, _): name
        }
    }

    var value: String {
        switch self {
        case let .set(_, value), let .append(_, value), let .setIfAbsent(_, value): value
        }
    }

    var verb: ResponseHeaderVerb {
        switch self {
        case .set: .set
        case .append: .append
        case .setIfAbsent: .setIfAbsent
        }
    }
}

/// Resolves a response's header fields from every contributor, applied in one defined order:
///
///     controller @ResponseHeader → route @ResponseHeader → handler return → middleware (outer last)
///
/// Annotations and middleware share this vocabulary deliberately. They differ in *when* their value is
/// produced (a compile-time constant versus something computed per request, possibly after the handler
/// ran) and in *reach* (written on what it affects versus applying to routes that never name it) — but
/// not in how contributions combine, so giving them different merge rules would have been an
/// inconsistency rather than a design.
///
/// **Never folds.** Every write goes through `HTTPFields`' multi-value subscript, so repeated fields stay
/// separate field lines. Folding would be legal for list-valued fields (RFC 9110 §5.3 makes the two forms
/// semantically identical) but is forbidden for `Set-Cookie` (RFC 6265 §3) and required-against by HTTP/2
/// (RFC 9113 §8.2.3), so staying multi-line is correct everywhere with no per-field knowledge. A caller
/// who wants one folded line writes the combined value with `.set`.
///
/// Using `HTTPFields`' *single*-value subscript anywhere in here would silently fold every field and break
/// `Set-Cookie` with no other visible symptom. That is the one invariant this type has.
public enum WireMVCResponseHeaders {
    /// The route's fields: its `@ResponseHeader` constants in tier order, then anything the handler
    /// returned in its response tuple, then what middleware contributed — the full order, in one place.
    ///
    /// Middleware last is what lets a policy header set by a wrapping middleware stand; within that tier
    /// the registry has already ordered them outermost-last (see ``ResponseHeaderRegistry``). A middleware
    /// that means to defer to the route says so with `.setIfAbsent` rather than by position.
    public static func resolved(
        statics: [ResponseHeaderContribution] = [],
        // `HTTPFields()`, not `[:]`. The dictionary literal goes through `init(dictionaryLiteral:)` and
        // allocates at every call site that omits this argument — which is every typed route, since only a
        // handler returning response fields in its tuple passes one. Measured: one allocation per call.
        returned: HTTPFields = HTTPFields(),
        middleware: [ResponseHeaderContribution] = []
    ) -> HTTPFields {
        var fields: HTTPFields
        if statics.isEmpty {
            // Nothing precedes the returned fields, so replaying them into an empty set would reproduce
            // exactly what they already are — `applying` maintains a `Set<HTTPField.Name>` and rebuilds a
            // value it was handed. Start from them instead. With statics present this shortcut is wrong:
            // they have to go in first so the returned fields can override them per name.
            fields = returned
        } else {
            fields = HTTPFields()
            for contribution in statics {
                apply(contribution, to: &fields)
            }
            fields = applying(returned: returned, to: fields)
        }
        for contribution in middleware {
            apply(contribution, to: &fields)
        }
        return fields
    }

    /// Apply one contribution.
    ///
    /// Every case here uses the **scalar** `HTTPFields` API rather than the array-valued subscript, which
    /// is a spelling choice with a measured cost: `fields[values: name] = [value]` builds an `Array` to
    /// carry one value, and the `setIfAbsent` spelling built one *just to ask `.isEmpty`*, then another to
    /// write. Measured in process, the array-valued version cost **4 more allocations, 224 more bytes and
    /// ~0.17 µs per contribution** — a third of WireMVC's whole per-request allocation count, for one
    /// header, paid again per contribution and on bridged runtimes too.
    ///
    /// `append` is the case to be careful with: it must add a **separate field line**, never fold into an
    /// existing value, because `Set-Cookie` cannot be folded. `HTTPFields.append(_:)` appends a field, so
    /// it keeps the separate line that `fields[values: name].append(_:)` did — the joined `[name]` getter
    /// is lossy for repeated fields either way, which is what `appendKeepsSeparateFieldLines` pins.
    public static func apply(_ contribution: ResponseHeaderContribution, to fields: inout HTTPFields) {
        let name = contribution.name
        switch contribution.verb {
        case .set: fields[name] = contribution.value
        case .append: fields.append(HTTPField(name: name, value: contribution.value))
        case .setIfAbsent: if fields[name] == nil { fields[name] = contribution.value }
        }
    }

    /// Apply a handler-returned field list, which carries no verbs — a whole list replacing per name.
    ///
    /// Replacement is per *name*, not per value: the first occurrence of a name clears what was there, and
    /// later occurrences of that same name accumulate. So a handler returning two `Set-Cookie`s replaces
    /// the inherited set with both of its own rather than only the last.
    public static func applying(returned: HTTPFields, to base: HTTPFields) -> HTTPFields {
        guard !returned.isEmpty else { return base }
        var result = base
        var replaced: Set<HTTPField.Name> = []
        for field in returned {
            if replaced.insert(field.name).inserted {
                result[values: field.name] = [field.value]
            } else {
                result[values: field.name].append(field.value)
            }
        }
        return result
    }
}

/// Response encoding the generated witness calls. A `.buffered` response mode goes through ``encoded``;
/// a `.bodiless` one builds `.status` inline in the witness.
public enum WireMVCResponse {
    /// Wrap what a codec produced into an outcome — the single buffered emit site, for every mode.
    ///
    /// The codec returns `(bytes, contentType)` and this seeds the content type **only when the route named
    /// none**, so a route's own `@ResponseHeader(.contentType, …)` still wins. That ordering is the whole
    /// reason this is one function rather than something each codec does for itself: it is a property of the
    /// response, not of the encoding.
    public static func encoded(
        _ encoded: (bytes: [UInt8], contentType: String),
        status: HTTPResponse.Status,
        headerFields: HTTPFields = [:]
    ) -> WireMVCOutcome {
        var fields = headerFields
        if fields[.contentType] == nil { fields[.contentType] = encoded.contentType }
        return WireMVCOutcome(status: status, headerFields: fields, body: encoded.bytes)
    }

    /// `@JSONResponse[(status:)]` — encode an `Encodable` return as a JSON body.
    ///
    /// No longer what the generator emits (it goes through ``encoded`` and `WireMVCJSONCodec` like any other
    /// mode), and kept because it is the spelling an `@ErrorResponse` mapping and hand-written code use.
    public static func json<T: Encodable>(
        _ value: T,
        status: HTTPResponse.Status,
        headerFields: HTTPFields = [:],
        coding: WireMVCCoding = .default
    ) throws -> WireMVCOutcome {
        try WireMVCOutcome.json(value, status: status, headerFields: headerFields, coding: coding)
    }
}
