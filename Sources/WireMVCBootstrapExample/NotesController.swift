import HTTPTypes
package import Wire
import WireMVC

// Two request-scoped controllers exercising the keyed harness's two subject-match shapes:
//
//  • `NotesController` (direct injection) — injects the `@BindType`-able `any NoteBackend` directly, AND
//    borrows a plain app `@Singleton` (`NoteStamp`). The borrow is the shape H2.2a's borrow fix unblocked:
//    the scope-entry thunk binds the app singleton as a local outside the `@Sendable` thunk, then rebuilds
//    the request scope around it. `GET /notes/{id}` → the mock's answer under a keyed suite, the real one else.
//
//  • `AccountController` (the `@Scopable` cascade) — reaches the mock ONLY through a `@Scopable`'d app
//    `@Singleton` (`AccountRegistry`) that reads `any NoteBackend` at its `init`. Under a keyed suite the
//    registry is lifted into the request scope and rebuilt per entry, so its `init` reads the supplied mock —
//    the Phase-2 distinguishing property. `GET /account/{id}` → the mock's init-read value under a keyed suite.
//
// `NoteBackend` is app-scoped so a singleton can inject it; under a `@BindType` the leaf is lifted into the
// request scope per entry, so each request still resolves its own supplied double.

/// The backend slot a `TestingKey`'s `@BindType` substitutes. A protocol (existential) so a mock matches the
/// producer/consumer directly. `note` is `async` so a test mock can suspend inside the lookup (e.g. on a
/// barrier), letting a test prove two differently-mocked requests interleave in-flight.
package protocol NoteBackend: Sendable {
    func note(_ id: String) async -> String
}

/// The production backend. `package` for re-composition.
package final class RealNoteBackend: NoteBackend {
    package init() {}
    package func note(_ id: String) async -> String { "real:\(id)" }
}

/// The app-scoped producer of `NoteBackend` — app-scoped so `AccountRegistry` (a `@Singleton`) can inject it;
/// a `@BindType` lifts the leaf into the request scope per entry, so a directly-injecting request-scoped
/// controller still resolves the per-request double.
package enum NoteBackendProvider {
    @Provides package static func backend() -> any NoteBackend { RealNoteBackend() }
}

/// A plain app `@Singleton` `NotesController` borrows — the borrow the scope-entry thunk lifts out as a
/// local. Shared across every request; never reconstructed per scope.
@Singleton
package struct NoteStamp: Sendable {
    @Inject package init() {}
    package func stamp(_ value: String) -> String { "stamped:\(value)" }
}

/// An app `@Singleton` that reads `any NoteBackend` **at its `init`** — the Phase-2 property. Marked
/// `@Scopable` by the test's `TestingKey`, it is lifted into the request scope and rebuilt per entry under a
/// keyed suite, so this init read sees the supplied mock. `AccountController` reaches the mock only through it.
@Singleton
package struct AccountRegistry: Sendable {
    package let tag: String
    @Inject package init(backend: any NoteBackend) async {
        self.tag = await backend.note("init")
    }
}

/// The route's JSON response. `package` so a re-composing test target decodes it.
package struct Note: Codable, Sendable {
    package let value: String
    package init(value: String) { self.value = value }
}

@Scoped(seed: HTTPRequest.self)
@Controller("/notes")
package struct NotesController: Sendable {
    @Inject var backend: any NoteBackend  // direct injection of the `@BindType`-able slot
    @Inject var stamp: NoteStamp  // borrowed app `@Singleton` — the borrow fix

    @Get("/{id}")
    @JSONResponse
    package func note(@Path id: String) async -> Note {
        Note(value: stamp.stamp(await backend.note(id)))
    }
}

@Scoped(seed: HTTPRequest.self)
@Controller("/account")
package struct AccountController: Sendable {
    @Inject var registry: AccountRegistry  // the `@Scopable`'d singleton — NoteBackend is reached only via it

    @Get("/{id}")
    @JSONResponse
    package func account(@Path id: String) -> Note {
        Note(value: registry.tag)  // the registry's init-time read of the (mocked, under a keyed suite) backend
    }
}

// Three more seed-scoped controllers that exercise the keyed harness's "key every controller" model — under
// `.wiremvc(key)` each is keyed and its variant proxy takes the key's Doubles, whether or not it uses a mock.

/// A mock-IGNORING controller — injects only the seed. Its variant proxy takes the Doubles and ignores them;
/// a keyed request must still supply them (else 500), the uniform rule.
@Scoped(seed: HTTPRequest.self)
@Controller("/ping")
package struct PingController: Sendable {
    @Inject package init(request: HTTPRequest) {}
    @Get("/")
    @JSONResponse
    package func ping() -> Note { Note(value: "pong") }
}

/// A factory-carrying controller — its `@Middleware(AccessLogKeys.factory)` gives the contributor proxy a
/// lifted `_wireFactory_<key>`. The variant proxy re-emits it and the facade constructs it (the swift-wire
/// factory-facade fix); under a keyed suite it enters and serves like any other.
@Scoped(seed: HTTPRequest.self)
@Controller("/logged")
@Middleware(AccessLogKeys.factory)
package struct LoggedController: Sendable {
    @Inject package init(request: HTTPRequest) {}
    @Get("/")
    @JSONResponse
    package func logged() -> Note { Note(value: "logged") }
}

/// A request-scoped intermediate — injects the `@Scopable`'d `AccountRegistry`. It is neither `@BindType`d nor
/// `@Scopable`'d, so it is the Level-2 transitive hop the mock threads *through*.
@Scoped(seed: HTTPRequest.self)
package struct CartService: Sendable {
    @Inject package init(registry: AccountRegistry) { self.registry = registry }
    package let registry: AccountRegistry
}

/// The Level-2 subject — injects only the request-scoped `CartService`, reaching the mock through
/// `CartService → AccountRegistry(lifted, init reads the mock)`. Under "key every controller" it is keyed with
/// no extra mark, so the mock threads the transitive chain end to end.
@Scoped(seed: HTTPRequest.self)
@Controller("/cart")
package struct CartController: Sendable {
    @Inject var cart: CartService
    @Get("/{id}")
    @JSONResponse
    package func cart(@Path id: String) -> Note { Note(value: cart.registry.tag) }
}
