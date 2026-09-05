// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import HTTPTypes

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// The reverse of `RequestBound.bind`: the server turns a request into a value, and a client turns a value
// back into a request. Both directions live on the binding, so **where a value goes on the wire is the
// binding's own behaviour, in code the compiler checks** — not metadata a generator has to be told.
//
// This is what lets the generated typed client stop filtering parameters by wrapper name
// (`$0.wrapper == "Header"`, `"JSONBody"`, …) and so stop being the reason a binding declared outside
// WireMVC cannot appear in a request. See `Documentation/Notes/ExtensibleBindingsAndResponses.md`.

/// A request under construction, as a client assembles it.
///
/// The server side is handed a finished `HTTPRequest`; this is its counterpart on the way out. It carries
/// **no body slot** — deliberately. A body is supplied by returning it from
/// ``RequestBodySendable/sendBody(name:value:into:coding:)``,
/// and the generated client asks exactly one binding for one, so "at most one binding supplies the body" is
/// structurally impossible to violate rather than a rule needing a runtime check.
public struct WireMVCOutgoingRequest: Sendable {
    /// `{name}` template values, keyed by placeholder name.
    public var pathParameters: [String: String] = [:]

    /// Query items, in insertion order. An array rather than a dictionary because a name may repeat.
    public var query: [(name: String, value: String)] = []

    /// Request header fields.
    public var headers: [String: String] = [:]

    public init() {}
}

/// A binding that can write itself into an outgoing request.
///
/// Opt-in, and separate from ``RequestBound``: adding a requirement there would break every conformance
/// outside this package (see `RequestBinding.swift`). A binding that does not conform simply cannot be sent
/// by the generated typed client, and its route is reported rather than silently dropped.
public protocol RequestSendable {
    /// The value this binding sends. Declared here rather than inherited from ``RequestBound``, so a
    /// **streaming** binding — which implements ``RequestBodyReading`` and never ``RequestBound`` — can
    /// still be sent by the generated client. The inheritance carried nothing but this associated type; the
    /// codegen emits `Wrapper<T>.send(…)` and never requires the two protocols to travel together.
    associatedtype Value

    /// Place `value` into `request` under `name` — the wire name, which is the attribute's argument
    /// (`@Query("q")`) when given and the parameter's own name otherwise.
    ///
    /// `coding` is passed for the same reason `bind` receives it: a date is not only a JSON concern. A
    /// `@Query since: Date` must serialise through the same transcoder it will be parsed with, or the client
    /// and server disagree about date format.
    static func send(
        name: String,
        value: Value,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws
}

/// A binding that supplies the request body — and may write path/query/header entries alongside it.
///
/// One protocol rather than two calls, so a binding needing a body *and* a header (a signed payload with its
/// digest in a header) does both in one place. The body is *returned* rather than written into the request,
/// which is what makes a second body unrepresentable.
public protocol RequestBodySendable {
    /// The value this binding sends as the request body. See ``RequestSendable/Value`` for why it is
    /// declared here rather than inherited.
    associatedtype Value

    static func sendBody(
        name: String,
        value: Value,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String)
}

// ─────────────────────────────────────────────────────────────────────────────
// The built-ins, as ordinary instances of the seam
// ─────────────────────────────────────────────────────────────────────────────

extension Path: RequestSendable where T: LosslessStringConvertible {
    public static func send(
        name: String,
        value: T,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws {
        request.pathParameters[name] = String(describing: value)
    }
}

extension Query: RequestSendable where T: LosslessStringConvertible {
    public static func send(
        name: String,
        value: T,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws {
        request.query.append((name: name, value: String(describing: value)))
    }
}

extension Header: RequestSendable where T: LosslessStringConvertible {
    public static func send(
        name: String,
        value: T,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws {
        request.headers[name] = String(describing: value)
    }
}

extension JSONBody: RequestBodySendable where T: Decodable & Encodable {
    public static func sendBody(
        name: String,
        value: T,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        ([UInt8](try coding.encoder().encode(value)), "application/json")
    }
}

// Optionality is *not* handled here. The generated code calls `Wrapper<T>.bind` / `.bindOptional` on the
// non-optional underlying type (`RequestBinding.swift:149`), so a binding never sees `T?`; the client half
// mirrors that by simply not calling `send` for an absent optional. Keeping the split in the same place on
// both sides is what lets one conformance serve required, optional and defaulted parameters alike.
