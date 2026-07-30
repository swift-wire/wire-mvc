import Wire
import WireMVC

/// A concrete dependency the session middleware injects — an ordinary Wire binding.
@Singleton
struct SessionStore: Sendable {
    func lookup(_ token: String) -> String? { token.isEmpty ? nil : "session:\(token)" }
}

/// Factory-key namespace for the generic-with-deps session middleware. A generic type can't host a
/// `static let` key, so the key lives on a small non-generic namespace.
enum SessionMiddlewareKeys {
    static let factory = FactoryKey()
}

/// A generic-with-deps middleware: generic over the box roles (the *assisted* axis), with a concrete
/// `@Inject` dependency. `@Factory` marks it a factory template keyed by `SessionMiddlewareKeys.factory`;
/// a controller consumes it with `@Middleware(SessionMiddlewareKeys.factory)` and the build plugin
/// synthesises `_WireFactory_SessionMiddlewareKeys_factory` and lifts it onto the controller. Model B,
/// non-transforming: it reads a session via the injected store and passes the box through.
@Factory(SessionMiddlewareKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
struct SessionMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var store: SessionStore

    typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    typealias NextInput = Input

    func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        let token = input.peekedRequest.headerFields[HTTPField.Name("x-session")!] ?? ""
        _ = store.lookup(token)
        return try await next(input)
    }
}
