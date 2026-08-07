package import Wire
package import WireMVC

// A route-scope middleware contributing response header fields — the session-cookie shape, minus the store.
// It exercises both halves of `ResponseHeaderRegistry` on a live route:
//
//   • `add` — a value known on the way in.
//   • `onSend` — a value that cannot exist until the handler has run. This is the one that makes the whole
//     design necessary: a middleware cannot set a header *after* `next`, because the terminal already wrote
//     the response during it. Registering a closure on the way in and evaluating it at drain is what a real
//     session middleware needs, since its cookie depends on what the handler did to the session.
//
// Two contributions also pin the ordering: the route's own `@ResponseHeader` runs first, then this, so a
// `.set` here wins — and `.append` accumulates rather than replacing.

package enum StampKeys {
    package static let factory = FactoryKey()

    /// Stands in for a session store: set by the handler, read by the middleware at drain time.
    package nonisolated(unsafe) static var lastGreeted: String?
}

@Factory(StampKeys.factory)
@MiddlewareFactory
package struct StampMiddleware<
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
        let headers = input.responseHeaders
        headers.add(.set(.init("x-stamp")!, "middleware"))
        // Evaluated at drain — after the handler ran, before the response head exists.
        headers.onSend {
            guard let greeted = StampKeys.lastGreeted else { return [] }
            return [.append(.setCookie, "greeted=\(greeted); Path=/")]
        }
        return try await next(input)
    }
}
