import Synchronization
import Wire
import WireMVC

/// A global probe the middleware bumps, so the self-test can observe that the middleware ran around the
/// handler. A real logging/metrics middleware would log or record a metric; this records a count.
let requestProbe = Atomic<Int>(0)

/// Factory-key namespace for the request-log middleware. A generic type can't host a `static let` key,
/// so the key lives on a small non-generic namespace.
enum RequestLogMiddlewareKeys {
    static let factory = FactoryKey()
}

/// A non-transforming request middleware, generic over the box (`Input == NextInput`) but dep-free.
/// `@Factory` makes it a factory template keyed by `RequestLogMiddlewareKeys.factory`; a controller
/// consumes it with `@Middleware(RequestLogMiddlewareKeys.factory)` and the build plugin synthesises
/// `_WireFactory_RequestLogMiddlewareKeys_factory` and lifts it onto the controller.
@Factory(RequestLogMiddlewareKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
struct RequestLogMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        requestProbe.add(1, ordering: .relaxed)
        return try await next(input)
    }
}
