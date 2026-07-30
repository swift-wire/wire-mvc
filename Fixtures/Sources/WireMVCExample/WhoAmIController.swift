import HTTPTypes
import Synchronization
import Wire
import WireMVC

// A request-scoped controller — the M5.4 case. `@Scoped(seed: HTTPRequest.self) @Controller` makes the
// controller a *bridge* proxy: it's constructed fresh per request from the request seed (via the
// plugin-generated `_wireEnterScope` thunk), injecting a request-scoped `RequestInfo` built from that
// same seed, alongside the app-`@Singleton` `UserStore` (shared across every request).

/// A global probe the request-scoped resource's `@Teardown` bumps, so the self-test can observe that
/// request-scope teardown actually fires (M5.4.5).
let scopeTeardownProbe = Atomic<Int>(0)

/// A request-scoped resource carrying a `@Teardown` — verifies request-scope teardown runs per request
/// (the generated witness's async `defer` over the scope-entry thunk's teardown closure), consistent with
/// singleton-scope teardown. A real one would be a per-request connection/transaction; this bumps a probe.
@Scoped(seed: HTTPRequest.self)
struct RequestResource: Sendable {
    @Inject init(request: HTTPRequest) {}
    @Teardown func close() { scopeTeardownProbe.add(1, ordering: .relaxed) }
}

/// A request-scoped value built from the `HTTPRequest` seed — its `path` reflects the request that
/// opened the scope, so two requests see two different instances. Its `@Inject init` is **async** and
/// awaits the borrowed app-`@Singleton` `UserStore`, so the example verifies swift-wire constructs a
/// request-scoped binding through an `async` init (the scope-entry thunk emitting `await`), not only a
/// synchronous one — the path the sessions example sidestepped by deferring its async read to a handler.
@Scoped(seed: HTTPRequest.self)
struct RequestInfo: Sendable {
    let path: String
    let tag: String
    @Inject init(request: HTTPRequest, store: UserStore) async {
        self.path = request.path ?? ""
        self.tag = await store.tag(for: request.path ?? "")
    }
}

struct WhoAmI: Codable, Sendable {
    let path: String
    let tag: String
    let storeShared: Bool
}

@Scoped(seed: HTTPRequest.self)
@Controller("/whoami")
struct WhoAmIController: Sendable {
    @Inject var info: RequestInfo  // request-scoped — fresh per request, async-constructed
    @Inject var resource: RequestResource  // request-scoped — @Teardown fires per request (M5.4.5)
    @Inject var store: UserStore  // app singleton — shared

    @Get
    @JSONResponse
    func get() async throws -> WhoAmI {
        WhoAmI(path: info.path, tag: info.tag, storeShared: (try? store.find("42")) != nil)
    }
}
