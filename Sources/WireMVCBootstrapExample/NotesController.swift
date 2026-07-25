import HTTPTypes
package import Wire
import WireMVC

// A request-scoped controller exercising the H2.2a borrow fix: `@Scoped(seed: HTTPRequest.self)` makes it a
// bridge proxy (constructed fresh per request), injecting a request-scoped `any NoteBackend` AND borrowing a
// plain app `@Singleton` (`NoteStamp`). The borrow is the shape H2.2a's borrow fix unblocked — the scope-entry
// thunk binds the app singleton as a local *outside* the `@Sendable` thunk, then reconstructs the request
// scope around it. `NoteBackend` is the `@BindType`-able slot: a same-package test target's `TestingKey` binds
// it to a mock sourced per scope-entry, so `GET /notes/{id}` returns the mock's answer instead of the real one.

/// The request-scoped backend the controller injects — the slot a `TestingKey`'s `@BindType` substitutes.
/// A protocol (existential) so a mock matches the producer/consumer directly. `package` so a test target can
/// re-compose it and name it in a `@BindType`. `note` is `async` so a test mock can suspend inside the
/// lookup (e.g. on a barrier), letting a test prove two differently-mocked requests interleave in-flight.
package protocol NoteBackend: Sendable {
    func note(_ id: String) async -> String
}

/// The production backend, produced per request scope. `package` for re-composition.
package final class RealNoteBackend: NoteBackend {
    package init() {}
    package func note(_ id: String) async -> String { "real:\(id)" }
}

/// The request-scoped producer of `NoteBackend`, seeded by the `HTTPRequest` like the controller — so the
/// mocked slot is reached inside the request scope with no `@Scopable` cascade.
@Scoped(seed: HTTPRequest.self)
package enum NoteBackendProvider {
    @Provides package static func backend() -> any NoteBackend { RealNoteBackend() }
}

/// A plain app `@Singleton` the request-scoped controller borrows — the borrow the scope-entry thunk lifts
/// out as a local. Shared across every request; never reconstructed per scope.
@Singleton
package struct NoteStamp: Sendable {
    @Inject package init() {}
    package func stamp(_ value: String) -> String { "stamped:\(value)" }
}

/// The route's JSON response. `package` so a re-composing test target decodes it.
package struct Note: Codable, Sendable {
    package let value: String
    package init(value: String) { self.value = value }
}

@Scoped(seed: HTTPRequest.self)
@Controller("/notes")
package struct NotesController: Sendable {
    @Inject var backend: any NoteBackend  // request-scoped — the `@BindType`-able slot
    @Inject var stamp: NoteStamp  // borrowed app `@Singleton` — the borrow fix

    @Get("/{id}")
    @JSONResponse
    package func note(@Path id: String) async -> Note {
        Note(value: stamp.stamp(await backend.note(id)))
    }
}
