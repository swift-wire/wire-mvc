// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// The response half of the extension point — the mirror of `RequestBinding.swift` / `RequestSending.swift`.
//
// A response mode is a **pair**: which terminal builds the response, and what turns the handler's return
// into bytes. `@JSONResponse` is (buffered, a JSON codec); `@HTMLResponse` is (streaming, a producer).
// Until now the code generator knew those two by name — three literal string comparisons in
// `ResponseCodegen`, one more in `RouteCodegen`, two more in the client — so a third mode was not writable
// outside WireMVC at all. It now reads the pair off the mode's **macro declaration**, the same way
// `@RequestBinding` is read off a binding's type declaration.
//
// See `Documentation/Notes/ExtensibleBindingsAndResponses.md`.

/// Which terminal a response mode uses — the whole of what the generator must decide before it can emit a
/// route, and not something it can infer from a handler it never runs.
public enum WireMVCResponseTerminal: Sendable {
    /// The body is encoded up front and sent with the head: `WireMVCOutcome`.
    case buffered
    /// The head goes out first and the body is written incrementally: `WireMVCStreamingOutcome`.
    case streaming
    /// There is no body at all — `@ResponseStatus`. A mode rather than a special case, so that every
    /// response annotation is an instance of this seam and the generator has no name test left anywhere.
    case bodiless
}

/// What the generated typed client hands back for this mode.
///
/// Two cases, not an open set, because there are genuinely two: either the body decodes back into the type
/// the handler returned, or it does not decode at all and the client hands back text. The second exists for
/// markup — an `@HTMLResponse` handler returns `some HTML`, an opaque type the client could not name even if
/// markup were decodable, and what a test wants to assert on is the markup itself.
public enum WireMVCResponseClientBody: Sendable {
    /// `Codec<ReturnType>.decodeResponseBody(…)` — the client gets the handler's own return type back.
    case decoded
    /// The response body as a `String`, undecoded.
    case text
}

/// States what a response-mode annotation *is*, on the macro declaration that introduces it.
///
///     @ResponseMode(.buffered, codec: "YAMLCodec")
///     @attached(peer)
///     public macro YAMLResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
///
/// `codec` is a **spelling**, not a metatype, for two reasons. A codec is generic over the value it encodes
/// (`YAMLCodec<Value>`, conforming conditionally — exactly the shape `FormBody<Value>` has on the request
/// side), and an unbound generic metatype is not a legal expression: `YAMLCodec.self` fails to infer, so a
/// typed parameter would force every mode declaration to write a meaningless `YAMLCodec<Never>.self`. And it
/// would buy nothing: the generator emits `YAMLCodec.encodeResponseBody(…)` into the *consumer's* module,
/// where the compiler checks it against ``WireMVCResponseEncoding`` anyway. The request side already works
/// this way — `RouteCodegen` emits `FormBody<Login>.bind(…)` as a spelling too.
///
/// Read by the build plugin, which already re-parses every Wire-aware dependency module, so a mode declared
/// in a library is usable in any consumer without WireMVC knowing its name.
@attached(peer)
public macro ResponseMode(
    _ terminal: WireMVCResponseTerminal,
    codec: String? = nil,
    client: WireMVCResponseClientBody = .decoded
) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

// ─────────────────────────────────────────────────────────────────────────────
// The two halves a codec implements
// ─────────────────────────────────────────────────────────────────────────────

/// A codec's **server** half, for a `.buffered` mode: the handler's return, encoded.
///
/// Returns the content type alongside the bytes, for the reason `RequestBodySendable.sendBody` does and
/// `WireMVCBodyProducer.contentType` does: **a content type belongs to the codec**. The terminal seeds it
/// only when the route named none, so a route's own `@ResponseHeader(.contentType, …)` still wins.
///
/// Not required by ``ResponseMode(_:codec:client:)`` — the generated call site is where the compiler
/// checks the signature.
/// Conforming is how a codec author finds out at their own declaration that they got it wrong, rather than
/// in generated code, and is the reason this protocol exists at all.
public protocol WireMVCResponseEncoding {
    associatedtype Value
    static func encodeResponseBody(
        _ value: Value,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String)
}

/// A codec's **client** half, for a `.decoded` mode: the response body, back into the handler's return type.
///
/// This is the half the design note originally omitted, and omitting it is not neutral: with the server side
/// alone, a `@YAMLResponse` route generates a typed client that parses the body as JSON. The request side has
/// carried both directions since `RequestBodySendable`; this is its mirror.
public protocol WireMVCResponseDecoding {
    associatedtype Decoded
    static func decodeResponseBody(_ bytes: [UInt8], coding: WireMVCCoding) throws -> Decoded
}

// ─────────────────────────────────────────────────────────────────────────────
// The built-ins, as ordinary instances of the seam
// ─────────────────────────────────────────────────────────────────────────────

/// `@JSONResponse`'s codec. Generic over the value with conditional conformances, so one type serves both
/// directions and neither is available for a value that cannot travel that way.
///
/// A caseless enum: it is a namespace for two static functions and has no instances.
public enum WireMVCJSONCodec<Value> {}

extension WireMVCJSONCodec: WireMVCResponseEncoding where Value: Encodable {
    public static func encodeResponseBody(
        _ value: Value,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        // Plain `application/json`, no charset — matching what the OpenAPI generator emits
        // (`ContentType.applicationJSON`), since one app serves both kinds of route.
        ([UInt8](try coding.encoder().encode(value)), "application/json")
    }
}

extension WireMVCJSONCodec: WireMVCResponseDecoding where Value: Decodable {
    public static func decodeResponseBody(_ bytes: [UInt8], coding: WireMVCCoding) throws -> Value {
        try coding.decoder().decode(Value.self, from: Data(bytes))
    }
}
