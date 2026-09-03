public import AsyncStreaming
import BasicContainers
public import HTTPTypes

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The extraction contract every parameter binding implements. `@Controller`'s generated witness
/// calls `bind` once per handler parameter to produce the value it passes to the handler. Hosting
/// the logic here (rather than inlining it in the macro) keeps the macro a thin, binding-agnostic
/// dispatcher and lets users add their own bindings: define a `@propertyWrapper` conforming to
/// `RequestBound` and `@Controller` uses it uniformly.
/// What the code generator must do differently for a binding — stated on the binding's *declaration*, where
/// the plugin can read it (see `Documentation/Notes/ExtensibleBindingsAndResponses.md`).
///
/// Deliberately **not** a wire position. Where a value goes is the binding's own behaviour, and nothing the
/// generator needs to know; these are the two things it cannot infer from a function body it never reads.
public enum WireMVCBindingObligation: Sendable {
    /// The route reads the request body, so the terminal must collect it. At most one binding per route.
    case body
    /// The binding names a `{name}` path placeholder, so the route template must contain one.
    case path
    /// The binding reads the request body **incrementally**, so the terminal hands it the reader instead of
    /// collecting the body first. At most one binding per route, and never alongside `.body` — the reader
    /// cannot be both collected and streamed. See ``RequestBodyReading``.
    case readerBody
    /// The binding hands the **handler** a stream to pull from, rather than a finished value.
    ///
    /// Where `.readerBody` reduces the body to something small before the handler runs, this lets the
    /// handler act on the body as it arrives — reject an upload after its first field, write each part
    /// somewhere as it lands. The terminal constructs the stream, lends it to the handler `inout`, and keeps
    /// the reader in its own frame for the duration.
    ///
    /// The binding names its stream type with `stream:`, and the generator constructs it —
    /// `MultipartParts(request: request, reader: reader)`. That is a **spelling**, not a protocol
    /// requirement, and it has to be: the stream's type depends on the reader, and a protocol's
    /// `associatedtype` is fixed by the conformance before any reader exists. The same reasoning as the
    /// response side's `codec:`.
    ///
    /// **Construction only.** The stream must still conform to ``LentBodyStream``, whose `validateRequest()`
    /// the terminal calls on the constructed value, before the handler runs and before anything is
    /// committed to a response. Rejecting a request the stream cannot be produced from involves no reader,
    /// so it is a requirement rather than a spelling — and it has to be, because the duplex shape runs the
    /// handler *after* the head, where a check deferred to the handler truncates a response instead of
    /// mapping to a status.
    ///
    /// The parameter must be `consuming`: a stream is used up once, through a `withParts`-style entry point
    /// that consumes it. `inout` is not a matter of taste or of a missing feature — calling a consuming
    /// method on an `inout` binding demands a replacement value, and a stream has none.
    case bodyStream
}

public protocol RequestBound {
    /// The value handed to the handler parameter.
    associatedtype Value

    /// Produce the bound value from the request. `name` is the binding name (the attribute argument
    /// if given, else the parameter name). `pathParameters` are the router's matched `{name}`
    /// values; `body` is the request body, collected once by the witness (`nil` for routes without
    /// a body binding).
    ///
    /// The `[String: Substring]` shape is a pre-1.0 public decision, not a settled one: it appears in two
    /// public protocols, so changing it is cheap now and expensive after 1.0. See #175.
    static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Value
}

/// A request binding that is **also a graph binding**, resolved from the request scope rather than
/// constructed by the generated witness.
///
/// ``RequestBound`` is a property wrapper generic over the handler's parameter type, and its `bind` is
/// `static` for that reason: `Path<String>` has nothing to hold, so there is nothing to construct and
/// nothing to inject into. That is right for a binding that *decodes* — a path segment, a header, a JSON
/// body — where everything needed is already in the request.
///
/// It is not enough for a binding that *resolves*. Producing the value may need a store to read from, a
/// policy engine to consult, the caller the request scope built — none of which a static method can reach.
/// So the worker is an ordinary `@Scoped(seed:)` type with `@Inject` members like any other, and `bind` is
/// an instance method on the instance the scope constructed.
///
/// **It takes two declarations, and cannot take one.** A parameter attribute has to be a property wrapper —
/// the language allows nothing else there — and the wrapper's instance holds the value the call site
/// supplies, while the worker's holds what the graph supplied. No single type can have both initialisers be
/// total. So the wrapper stays what it always was and names its worker:
///
///     @RequestBinding(DocumentAuthorizer.self)
///     @propertyWrapper
///     public struct AuthorizedDocument {
///         public var wrappedValue: Document
///         public init(wrappedValue: Document) { self.wrappedValue = wrappedValue }
///         public init(wrappedValue: Document, _ name: String) { self.wrappedValue = wrappedValue }
///     }
///
///     @Scoped(seed: HTTPRequest.self)
///     public struct DocumentAuthorizer: ScopedRequestBound {
///         public typealias Value = Document
///         @Inject var documents: DocumentStore
///         @Inject var policies: PolicyEngine
///         @Inject var caller: Caller
///
///         public func bind(
///             name: String, request: HTTPRequest,
///             pathParameters: [String: Substring], body: [UInt8]?
///         ) async throws -> Document { … }
///     }
///
/// Neither declaration is told about the scope, and the controller is told about neither. `@RequestBinding`
/// declares swift-wire's `.injectsFromGraph` capability, so a route parameter naming the wrapper is what
/// makes the scope entry yield the worker, one hop out.
///
/// **The seam is already on the right side of the scope**, which is what makes this cheap: binding happens
/// *after* `_wireEnterScope` in every generated route, so there is no reordering, no lazy handle and no
/// assisted parameter. The instance arrives on the scope entry alongside the controller, because a route
/// parameter naming a scope binding is what tells swift-wire to hand it back.
///
/// **What it buys is not brevity.** A route that takes a `Document` cannot skip the authorisation check,
/// because the check is how a `Document` comes into existence — where a handler that loads and then
/// authorises restates that ordering per route, and a new route that omits the second line compiles,
/// serves, and is unauthorised with nothing but review to catch it. An unauthorised route stops being
/// writable, which is the same idiom one level in: authentication is already a precondition of the scope
/// existing.
///
/// > Important: the binding's scope must be the **controller's** scope. A `@Singleton @Controller` enters
/// > no scope, so there is nothing to resolve the binding from, and the generator says so rather than
/// > emitting a reference to a value that was never constructed.
///
/// **`Sendable`, where ``RequestBound`` is not**, and the asymmetry is the whole difference between them.
/// A `RequestBound`'s `bind` is `static`, so no instance of it is ever stored anywhere; a worker *is* an
/// instance, held on the scope entry the generated route reads and — for an OpenAPI operation — on the
/// generated conformer, which is `Sendable`. Requiring it here is what makes a worker that cannot be one
/// fail on its own declaration rather than as `stored property '_wireWorker_X' … contains non-Sendable
/// type` inside emitted code the author did not write. An internal worker gets the conformance inferred
/// and never notices; a `public` one has to say it, which is ordinary for a `public` type in a graph.
public protocol ScopedRequestBound: Sendable {
    /// The value handed to the handler parameter.
    associatedtype Value

    /// Produce the bound value from the request, on the instance the scope constructed. The parameters are
    /// ``RequestBound/bind(name:request:pathParameters:body:)``'s, and mean the same things; what differs
    /// is `self`, which is why this exists.
    func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> Value
}

extension ScopedRequestBound {
    /// The coding-aware entry point the generated witness calls, defaulted for the same reason
    /// ``RequestBound``'s is: a binding that does not care about coding inherits this and ignores it.
    public func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?,
        coding: WireMVCCoding
    ) async throws -> Value {
        try await bind(name: name, request: request, pathParameters: pathParameters, body: body)
    }

    /// Like `bind`, but `nil` for an absent value rather than a throw — the instance counterpart of
    /// ``RequestBound/bindOptional(name:request:pathParameters:body:coding:)``, backing an optional or
    /// defaulted handler parameter.
    public func bindOptional(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?,
        coding: WireMVCCoding = .default
    ) async throws -> Value? {
        do {
            return try await bind(
                name: name,
                request: request,
                pathParameters: pathParameters,
                body: body,
                coding: coding
            )
        } catch let error as WireMVCBindingError where error.isAbsence {
            return nil
        }
    }
}

extension RequestBound {
    /// The coding-aware entry point the generated witness calls.
    ///
    /// A defaulted extension method rather than a new protocol requirement: `RequestBound` is public and
    /// documented as user-extensible, so adding a requirement would break every conformance outside this
    /// package. A binding that does not care about coding — a path or header value — inherits this and
    /// ignores it; the ones that do decode a body override it.
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?,
        coding: WireMVCCoding
    ) async throws -> Value {
        try await bind(name: name, request: request, pathParameters: pathParameters, body: body)
    }
}

extension RequestBound {
    /// Like `bind`, but returns `nil` when the value is simply absent (a missing path/query/header),
    /// while still throwing on a type mismatch. Backs optional (`T?`) and defaulted (`= expr`)
    /// handler parameters.
    public static func bindOptional(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?,
        coding: WireMVCCoding = .default
    ) async throws -> Value? {
        do {
            return try await bind(
                name: name,
                request: request,
                pathParameters: pathParameters,
                body: body,
                coding: coding
            )
        } catch let error as WireMVCBindingError where error.isAbsence {
            return nil
        }
    }
}

/// Collects the request body off the streaming reader into bytes, consuming the reader. The witness
/// calls this once per request (only for routes with a body binding) and hands the result to every
/// binding's `bind`.
public enum WireMVCRequest {
    public static func collectBody<Reader: AsyncReader & ~Copyable>(
        _ reader: consuming Reader,
        maximumSize: Int = 1_000_000
    ) async throws -> [UInt8]
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
        var buffer = UniqueArray<UInt8>()
        do {
            _ = try await reader.collect(into: &buffer, maximumSize: maximumSize)
        } catch {
            throw WireMVCBindingError.malformedBody
        }
        let span = buffer.span
        var bytes = [UInt8]()
        bytes.reserveCapacity(span.count)
        for index in 0..<span.count {
            bytes.append(span[index])
        }
        return bytes
    }
}

/// A binding failure the generated witness maps to a client-error status.
public enum WireMVCBindingError: Error {
    case missingPathParameter(String)
    case pathParameterTypeMismatch(String, String)
    case missingQueryParameter(String)
    case queryParameterTypeMismatch(String, String)
    case missingHeader(String)
    case headerTypeMismatch(String, String)
    case unsupportedMediaType
    case malformedBody

    /// The status the generated witness sends for this failure. `@JSONBody`'s content-type rules
    /// land here: 415 for a contradictory `Content-Type`, 422 for a malformed body; missing/
    /// mismatched path/query/header values are 400.
    public var status: HTTPResponse.Status {
        switch self {
        case .unsupportedMediaType:
            return .unsupportedMediaType  // 415
        case .malformedBody:
            return .unprocessableContent  // 422
        case .missingPathParameter, .pathParameterTypeMismatch,
            .missingQueryParameter, .queryParameterTypeMismatch,
            .missingHeader, .headerTypeMismatch:
            return .badRequest  // 400
        }
    }

    /// Whether this failure is a plain absence (vs a type mismatch or content-type error), so
    /// `bindOptional` can turn it into `nil` for optional/defaulted parameters.
    var isAbsence: Bool {
        switch self {
        case .missingPathParameter, .missingQueryParameter, .missingHeader: return true
        default: return false
        }
    }
}

// The binding wrappers are *unconstrained* structs so an optional parameter (`@Query x: T?`) is a
// valid backing `Wrapper<T?>`; the extraction (`RequestBound`/`bind`) lives on a constrained
// extension, and the macro calls it on the non-optional underlying type (`Wrapper<T>.bind` /
// `.bindOptional`), so `T: LosslessStringConvertible` is still enforced where it matters. A
// genuinely non-convertible required parameter is a compile error at the generated `bind` call.

/// `@Path name: T` — binds a `{name}` path template placeholder, converting via
/// `LosslessStringConvertible`.
///
/// Carries `@RequestBinding` like any binding declared outside this package. WireMVC's own bindings being
/// exempt is what let the generator keep naming them: `.path` here is the same obligation a user binding
/// states, read the same way, so `namesPathPlaceholder` has one rule rather than a name test plus a lookup.
@RequestBinding(.path)
@propertyWrapper
public struct Path<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T, _ name: String) { self.wrappedValue = wrappedValue }
}

extension Path: RequestBound where T: LosslessStringConvertible {
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> T {
        guard let raw = pathParameters[name] else {
            throw WireMVCBindingError.missingPathParameter(name)
        }
        guard let value = T(String(raw)) else {
            throw WireMVCBindingError.pathParameterTypeMismatch(name, String(raw))
        }
        return value
    }
}

/// `@Query name: T` — binds a query-string item, converting via `LosslessStringConvertible`.
///
/// The bare form: a binding with no obligation on the generator. Recognition needs no argument — a binding
/// is recognised by *having* this attribute.
@RequestBinding
@propertyWrapper
public struct Query<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T, _ name: String) { self.wrappedValue = wrappedValue }
}

extension Query: RequestBound where T: LosslessStringConvertible {
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> T {
        guard let query = request.path?.split(separator: "?", maxSplits: 1).dropFirst().first else {
            throw WireMVCBindingError.missingQueryParameter(name)
        }
        for pair in query.split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1)
            guard String(keyValue[0]) == name else { continue }
            let raw = keyValue.count > 1 ? percentDecoded(keyValue[1]) : ""
            guard let value = T(raw) else {
                throw WireMVCBindingError.queryParameterTypeMismatch(name, raw)
            }
            return value
        }
        throw WireMVCBindingError.missingQueryParameter(name)
    }
}

/// Percent-decode a query value (`%XX` escapes), without full Foundation's `removingPercentEncoding`
/// — which isn't in FoundationEssentials, the module the Linux toolchain resolves here. Keeps query
/// binding identical on macOS and Linux. Malformed escapes are passed through byte-for-byte.
private func percentDecoded(_ input: Substring) -> String {
    let source = Array(input.utf8)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(source.count)
    var index = 0
    while index < source.count {
        if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
            let highNibble = hexNibble(source[index + 1]), let lowNibble = hexNibble(source[index + 2])
        {
            bytes.append(highNibble << 4 | lowNibble)
            index += 3
        } else {
            bytes.append(source[index])
            index += 1
        }
    }
    // String(bytes:encoding:) needs full Foundation (absent on Linux); this stdlib UTF-8 decode is intended.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: bytes, as: UTF8.self)
}

private func hexNibble(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    default: return nil
    }
}

/// `@Header name: T` — binds an HTTP header value, converting via `LosslessStringConvertible`.
@RequestBinding
@propertyWrapper
public struct Header<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T, _ name: String) { self.wrappedValue = wrappedValue }
}

extension Header: RequestBound where T: LosslessStringConvertible {
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> T {
        guard let fieldName = HTTPField.Name(name), let raw = request.headerFields[fieldName] else {
            throw WireMVCBindingError.missingHeader(name)
        }
        guard let value = T(raw) else {
            throw WireMVCBindingError.headerTypeMismatch(name, raw)
        }
        return value
    }
}

/// `@JSONBody name: T` — decodes the JSON request body into `T`. Content-type rules: 415 on a
/// contradictory `Content-Type`, lenient on a missing one, 422 on malformed JSON.
///
/// `.body`, so the terminal collects the request body for it and the typed client asks it for one — the
/// same two consequences a `@FormBody` or `@YAMLBody` gets from the same word.
@RequestBinding(.body)
@propertyWrapper
public struct JSONBody<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

extension JSONBody: RequestBound where T: Decodable {
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> T {
        let contentType = request.headerFields[.contentType]
        if let contentType, !contentType.hasPrefix("application/json") {
            throw WireMVCBindingError.unsupportedMediaType  // 415
        }
        return try Self.decode(body: body, coding: .default)
    }

    /// The coding-aware form: `@JSONBody` is the binding that actually reads settings.
    public static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?,
        coding: WireMVCCoding
    ) async throws -> T {
        let contentType = request.headerFields[.contentType]
        if let contentType, !contentType.hasPrefix("application/json") {
            throw WireMVCBindingError.unsupportedMediaType  // 415
        }
        return try decode(body: body, coding: coding)
    }

    private static func decode(body: [UInt8]?, coding: WireMVCCoding) throws -> T {
        guard let body else { throw WireMVCBindingError.malformedBody }  // 422
        do {
            return try coding.decoder().decode(T.self, from: Data(body))
        } catch {
            throw WireMVCBindingError.malformedBody  // 422
        }
    }
}
