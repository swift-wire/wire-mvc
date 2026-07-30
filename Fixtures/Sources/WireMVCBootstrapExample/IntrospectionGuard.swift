package import Wire
package import WireMVC

// A guard on the introspection route only — declared via `@Middleware(IntrospectionGuardKeys.factory)` on the
// Bootstrap's `mountIntrospectionAt` method. It observes (prints) then forwards; a real one would check an
// admin credential and short-circuit (write 403) for non-admins. Route-scoped, NOT global: it folds around
// just `/wiring` (via the proxy's generated `registerIntrospection`), unlike the global `AccessLog`. The
// method-level `@Middleware` factory is lifted onto the global-middleware proxy exactly as a route-scope
// controller middleware is.

/// Factory-key namespace for the introspection guard.
package enum IntrospectionGuardKeys {
    package static let factory = FactoryKey()
}

/// Logs `introspection-guard: <path>` for requests to the guarded introspection route, then forwards.
@Factory(IntrospectionGuardKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
package struct IntrospectionGuard<
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
        print("introspection-guard: \(input.peekedRequest.path ?? "/")")
        return try await next(input)
    }
}
