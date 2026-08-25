import Synchronization
package import Wire
package import WireMVC

// A route-scope middleware contributing response header fields — the session-cookie shape, with a real
// injected store rather than a stand-in. It exercises both halves of `ResponseHeaderRegistry` on a live
// route:
//
//   • `add` — a value known on the way in.
//   • `onSend` — a value that cannot exist until the handler has run. This is the one that makes the whole
//     design necessary: a middleware cannot set a header *after* `next`, because the terminal already wrote
//     the response during it. Registering a closure on the way in and evaluating it at drain is what a real
//     session middleware needs, since its cookie depends on what the handler did to the session.
//
// It is also the **injected axis** of a middleware factory (`@Factory` + `@Inject`) doing the job it was
// designed for — the design record's own example is a session middleware with `@Inject var store:
// SessionStore`. The controller injects the same binding, so handler and middleware meet through the graph.

/// Stands in for a session store: an ordinary `@Singleton` Wire binding that both the controller and the
/// middleware inject.
///
/// **Keyed**, because two requests are in flight at once under a parallel suite and must not see each
/// other's value — a real session store is keyed by session id; this one by the name in the path. A class
/// with a `Mutex` rather than a struct, since a struct storing a `~Copyable` `Mutex` would itself become
/// non-copyable.
///
/// A per-request store would need neither the key nor the lock, which is what a real session store wants —
/// but whether a middleware factory can inject a `@Scoped(seed:)` binding is untested, and finding out is
/// not this fixture's job.
@Singleton
package final class GreetingLog: Sendable {
    private let entries = Mutex<[String: String]>([:])

    @Inject package init() {}

    package func record(_ greeting: String, for key: String) {
        entries.withLock { $0[key] = greeting }
    }

    package func greeting(for key: String) -> String? {
        entries.withLock { $0[key] }
    }
}

package enum StampKeys {
    package static let factory = FactoryKey()
}

@Factory(StampKeys.factory)
@MiddlewareFactory
package struct StampMiddleware<
    Ctx: HTTPServerCapability.RequestContext & ~Copyable,
    Reader: AsyncReader & ~Copyable,
    Sender: HTTPResponseSender & ~Copyable
>: Middleware
where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields?, Sender.Writer: ~Copyable {
    @Inject var log: GreetingLog

    package typealias Input = RequestResponseMiddlewareBox<Ctx, Reader, Sender>
    package typealias NextInput = Input

    package func intercept<Return: ~Copyable>(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Return
    ) async throws -> Return {
        // The key is read off the request on the way in — the middleware knows *which* request this is
        // before the handler runs, just not what the handler will do with it.
        let key = String(input.peekedRequest.path?.split(separator: "/").last ?? "")
        return try await input.contributing { headers in
            headers.add(.set(.init("x-stamp")!, "middleware"))
            // Evaluated at drain — after the handler ran and wrote to the store, before the response head
            // exists. The closure is still not `@Sendable`, so it can capture per-request state: that
            // capability is what a linear registry keeps and a `Mutex`-guarded `Sendable` one would cost.
            headers.onSend { [log] in
                guard let greeting = log.greeting(for: key) else { return [] }
                return [.append(.setCookie, "greeted=\(greeting); Path=/")]
            }
        } then: { input in
            try await next(input)
        }
    }
}
