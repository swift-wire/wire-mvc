public import AsyncStreaming
public import HTTPAPIs
public import HTTPTypes
public import Middleware
public import Wire
public import WireMVC

/// Cross-Origin Resource Sharing, as a WireMVC middleware.
///
/// ## Why this ships
///
/// WireMVC owns its middleware box (`RequestResponseMiddlewareBox` — the proposal ships one only in a test
/// module), so Hummingbird's and Vapor's CORS middleware do not port across. Every proposal-native WireMVC
/// app would otherwise write this itself, against a shape no ecosystem supplies. That is the same reason
/// `WireMVCRouter` ships: the native path needs one and nothing else provides it.
///
/// It is **provisional**, and the end state is more specific than "this becomes a shim".
///
/// If the proposal standardises `Middleware` *and* a request/response box, middleware becomes portable and
/// someone writes a standalone `swift-cors-middleware`. That library knows nothing about swift-wire: no
/// `@Factory`, no `@MiddlewareFactory`, no `@Inject` — just a generic `struct` with an ordinary `init`. So a
/// WireMVC app still could not fold it, because `@Middleware(key)` folds either a graph binding by type
/// (concrete, so pinned to one box) or a `@Factory` template (which requires annotating the type).
///
/// What closes that gap is a factory **function** template — `@Factory` on a `@Provides` returning the
/// middleware, generic over the box roles, with its other parameters resolved from the graph:
///
///     @Factory(CORSKeys.factory) @MiddlewareFactory
///     @Provides static func makeCORS<Ctx, Reader, Sender>(
///         configuration: CORSConfiguration
///     ) -> CORSMiddleware<Ctx, Reader, Sender>
///
/// The injected/assisted axis split carries over unchanged; it partitions the function's parameters rather
/// than a type's generic clause. With that, an app folds the third-party middleware directly and **this
/// module is not a shim, it is unnecessary** — the bridge is a capability, not a package. That mechanism is
/// also useful before portability arrives: it is the only way to fold any middleware type you do not own and
/// cannot annotate.
///
/// ## Verbs
///
/// `Access-Control-*` are contributed with `.set`: the middleware is authoritative, and a route that sets
/// its own CORS fields is nearly always a mistake that should not silently win. `Vary` is contributed with
/// `.append`, because it is additive by nature — a route may already vary on `Accept-Encoding`. That split
/// is what Hummingbird hand-rolls in its own CORS middleware; here the verbs say it directly.
///
/// ## Configuration
///
/// Through the graph, like any WireMVC middleware's dependency:
///
///     @Provides let cors = CORSConfiguration(allowOrigin: .oneOf(["https://app.example"]))
///
///     @Singleton @WireMVCBootstrap
///     @Middleware(CORSMiddlewareKeys.factory)
///     struct AppBootstrap { … }
@Factory(CORSMiddlewareKeys.factory)
@MiddlewareFactory
public struct CORSMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var configuration: CORSConfiguration

    public typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    public typealias NextInput = Input

    public func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let request = input.peekedRequest
        // No `Origin`, no CORS. A same-origin request must not gain these fields, and adding `Vary: Origin`
        // to responses that never vary would cost cache hits for nothing.
        guard let origin = request.headerFields[.origin] else {
            return try await next(input)
        }

        // The fields both an actual request and a preflight carry. Contributed to the registry rather than
        // written, so they reach whatever eventually responds — a route's terminal, a gate further in, or
        // the preflight answer below.
        let headers = input.responseHeaders
        if let allowed = configuration.allowOrigin.value(for: origin) {
            headers.add(.set(.accessControlAllowOrigin, allowed))
        }
        if configuration.allowCredentials {
            headers.add(.set(.accessControlAllowCredentials, "true"))
        }
        if configuration.allowOrigin.variesByRequestOrigin {
            headers.add(.append(.vary, "Origin"))
        }

        guard isPreflight(request) else {
            // An actual request: `Expose-Headers` tells the browser which response fields script may read,
            // and is meaningless on a preflight.
            if !configuration.exposedHeaders.isEmpty {
                headers.add(.set(.accessControlExposeHeaders, joined(configuration.exposedHeaders)))
            }
            return try await next(input)
        }

        // A preflight is answered here rather than routed: it is an `OPTIONS` to a path whose real route is
        // some other method, so there is nothing to dispatch to. `respondingWith` drains the contributions
        // above into the outcome — raw `responding` would not, and the origin field would be lost.
        var preflight = HTTPFields()
        preflight[.accessControlAllowMethods] = configuration.allowMethods
            .map(\.rawValue).joined(separator: ", ")
        if !configuration.allowHeaders.isEmpty {
            preflight[.accessControlAllowHeaders] = joined(configuration.allowHeaders)
        }
        if let maxAge = configuration.maxAge {
            preflight[.accessControlMaxAge] = String(maxAge.components.seconds)
        }
        let responded = try await input.respondingWith(.status(.noContent, headerFields: preflight))
        return try await next(responded)
    }

    /// An `OPTIONS` carrying `Access-Control-Request-Method` — the method a preflight asks about. `OPTIONS`
    /// alone is not a preflight; it is a legitimate request in its own right and must still route.
    private func isPreflight(_ request: HTTPRequest) -> Bool {
        request.method == .options && request.headerFields[.accessControlRequestMethod] != nil
    }

    private func joined(_ names: [HTTPField.Name]) -> String {
        names.map(\.rawName).joined(separator: ", ")
    }
}

/// The key an app names in `@Middleware(CORSMiddlewareKeys.factory)`.
///
/// A separate namespace because a generic type cannot host a `static let`, and because naming the key on
/// the annotated type itself (`@Factory(CORSMiddleware.factory)`) is a circular macro reference — the
/// compiler cannot resolve the type mid-expansion. The same reason `@ErrorResponse` cannot take a reference
/// to the annotated controller's own method.
public enum CORSMiddlewareKeys {
    public static let factory = FactoryKey()
}
