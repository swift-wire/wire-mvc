package import Wire
package import WireMVC

// A global middleware (M5.5 Phase 5): the composition root's `@Middleware(AccessLogKeys.factory)` folds this
// around *every* request — matched routes and the `@NotFound` fallback alike — via the generated
// global-middleware proxy's `wrapGlobalMiddleware`. Non-transforming (`Input == NextInput`), the constraint
// the front layer requires (the router is fixed on its box type).
//
// A global `@Middleware` is **factory-form** (generic over the box), the same shape as `WireMVCExample`'s
// reusable middleware, so `.create(Handler box)` produces a middleware over the router's box. A concrete
// by-type middleware can't compose in the non-transforming generic chain, and is diagnosed.

/// Factory-key namespace for the access-log middleware. A generic type can't host a `static let` key, so it
/// lives on a small non-generic namespace.
package enum AccessLogKeys {
    package static let factory = FactoryKey()
}

/// Logs `method path` for every request, then forwards. The `access:` line is what the CI boot-probe greps
/// to prove the global tier runs on both a matched route and the 404 fallback.
@Factory(AccessLogKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
package struct AccessLog<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let request = input.peekedRequest
        print("access: \(request.method.rawValue) \(request.path ?? "/")")
        return try await next(input)
    }
}
