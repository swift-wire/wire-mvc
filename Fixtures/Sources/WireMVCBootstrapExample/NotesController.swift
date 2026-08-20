import HTTPTypes
package import Wire
import WireMVC
package import WireMVCElementary

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
/// `@TestScopable` on the type, it is lifted into the request scope and rebuilt per entry under a keyed suite,
/// so this init read sees the supplied mock. `AccountController` reaches the mock only through it. The mark is
/// inert without a `TestingKey`'s `@BindType`, so it doesn't affect production.
@TestScopable
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

/// An **app-scoped** (`@Singleton`) route contributor consuming the `@BindType`'d `NoteBackend` directly — the
/// seedless case (Phase A). `@TestScopable`: under a keyed suite the variant rebuilds it per-request from the
/// doubles alone (no seed), so `/summary` serves the mock; in production it's an ordinary shared singleton
/// built once against the real backend.
@TestScopable
@Singleton
@Controller("/summary")
@Middleware(SummaryAuditKeys.factory)
package struct SummaryController: Sendable {
    @Inject var backend: any NoteBackend

    @Get("/{id}")
    @JSONResponse
    package func summary(@Path id: String) async -> Note {
        Note(value: await backend.note("summary:\(id)"))
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

/// The seed-scoped counterpart to `SummaryController`. Where `LoggedController` carries a factory that injects
/// nothing, this one's `@Middleware(ScopedAuditKeys.factory)` injects the `@BindType`'d `NoteBackend` — so the
/// factory is re-emitted as a variant factory sourcing the mock per request, exactly as the seedless path does.
/// Both the middleware and the handler touch the slot, so one supplied instance records `scoped-audit` then
/// `audited:x`.
@Scoped(seed: HTTPRequest.self)
@Controller("/audited")
@Middleware(ScopedAuditKeys.factory)
package struct AuditedController: Sendable {
    @Inject var backend: any NoteBackend

    @Get("/{id}")
    @JSONResponse
    package func audited(@Path id: String) async -> Note {
        Note(value: await backend.note("audited:\(id)"))
    }
}

// A KEYED binding slot — `@Provides(PrefsKeys.primary)` / `@Inject(PrefsKeys.primary)` (a `BindingKey`),
// mirroring `@Provides(key)` / `@Replaces(key)`. Mocked via the keyed `@BindType(PrefsKeys.primary, …)` form.
package protocol PrefsBackend: Sendable {
    func pref(_ id: String) async -> String
}
package final class RealPrefsBackend: PrefsBackend {
    package init() {}
    package func pref(_ id: String) async -> String { "real-pref:\(id)" }
}
package enum PrefsKeys {
    package static let primary = BindingKey<any PrefsBackend>()
}
@Provides(PrefsKeys.primary)
package func prefsBackend() -> any PrefsBackend { RealPrefsBackend() }

@Scoped(seed: HTTPRequest.self)
@Controller("/prefs")
package struct PrefsController: Sendable {
    @Inject(PrefsKeys.primary) var prefs: any PrefsBackend  // the keyed binding

    @Get("/{id}")
    @JSONResponse
    package func read(@Path id: String) async -> Note { Note(value: await prefs.pref(id)) }
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

/// A **seedless** `@TestScopable` controller with a **parameterless** route — the shape that regressed.
///
/// Its variant witness needs `request` to correlate the suite's per-request doubles, but nothing else about
/// this route does: there is no `@Path`/`@Query`/`@JSONBody` to bind, and no `@Scoped(seed:)` whose entry
/// would need the request as a seed. Both of the conditions that used to decide whether the register closure
/// bound `request` were therefore false, and the emitted preamble referenced a name that was not in scope.
///
/// It is app-`@Singleton` (not `@Scoped(seed:)`) on purpose: `@TestScopable` is what rebuilds it per request
/// under a keyed suite, and that is the path with no seed. Kept here rather than in a test target so the
/// *production* witness is emitted too, and the keyed suite adds the variant on top.
@TestScopable
@Singleton
@Controller("/registry")
package struct RegistryController: Sendable {
    @Inject var registry: AccountRegistry

    @Get
    @JSONResponse
    package func tag() -> Note {
        Note(value: registry.tag)
    }

    /// The sibling shape: the same seedless keyed witness, but a route that *does* bind — a `@JSONBody`, so
    /// `reader` is bound for the body collect and `pathParameters` for the bind call. Pins that the variant
    /// preamble coexists with both rather than only with the no-binding case above.
    @Post("/tag")
    @JSONResponse
    package func retag(@JSONBody note: Note) -> Note {
        Note(value: "\(registry.tag):\(note.value)")
    }
}

/// A **streaming response on a request-scoped controller** — the combination no fixture had.
///
/// Every other `@HTMLResponse` route lives on the app-`@Singleton` `PagesController`, so the streaming
/// terminal had only ever been emitted with an empty scope-entry preamble and prologue. Here both are
/// non-empty *and* the request body is reduced through a lent reader, so the generated `building` carries
/// the scope prologue, the lent bind and the handler call together. That is the shape most likely to break
/// silently, since each half is fine on its own.
@Scoped(seed: HTTPRequest.self)
@Controller("/scoped-pages")
package struct ScopedPageController: Sendable {
    @Inject var stamp: NoteStamp  // borrowed app singleton, as the JSON scoped controllers do

    @Post("/digest")
    @HTMLResponse
    @ErrorResponse(DigestError.self, .contentTooLarge)
    package func digestPage(@DigestBody digest: BodyDigest) -> some HTML {
        TodoListPage(heading: stamp.stamp("scoped"), rows: ["bytes: \(digest.byteCount)"])
    }
}
