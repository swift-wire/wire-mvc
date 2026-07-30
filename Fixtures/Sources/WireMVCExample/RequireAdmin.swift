import Wire
import WireMVC

/// Factory-key namespace for the route-scope admin gate.
enum RequireAdminKeys {
    static let factory = FactoryKey()
}

/// A route-scope gate (Model B), generic over the box but dep-free. If the `x-admin` header isn't
/// `true`, this middleware *is* the one that handles the request: it writes a 403 itself (consuming the
/// sender), and the box becomes `.responded` so the handler is skipped. It still calls `next` — every
/// middleware runs — it just hands `next` a box that's already been responded to. `@Factory` makes it a
/// template consumed with `@Middleware(RequireAdminKeys.factory)`.
@Factory(RequireAdminKeys.factory)
@MiddlewareFactory  // bare → positional: <Ctx, Reader, Sender> map to the roles in order (canonical)
struct RequireAdmin<
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
        let isAdmin = input.peekedRequest.headerFields[HTTPField.Name("x-admin")!] == "true"
        guard input.isPending, !isAdmin else {
            return try await next(input)
        }
        return try await next(
            input.responding { sender in
                var writer = sender
                try await writer.sendAndFinish(HTTPResponse(status: .forbidden))
            }
        )
    }
}
