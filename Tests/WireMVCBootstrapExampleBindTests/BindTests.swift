import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// H2.2b gate — the keyed test harness end to end over real HTTP. `@Suite(.wiremvc(NoteTestBinds.mockBackend))`
// stands up the app on an ephemeral loopback port and parks the variant contributor proxy for the key; each
// test supplies a per-request mock with `withBindValues(noteBackend:)`, and `GET /notes/{id}` — a
// request-scoped controller injecting the `@BindType`d `NoteBackend` AND borrowing the app `@Singleton`
// `NoteStamp` (the borrow fix) — observes the mock's answer instead of the real backend. A request that
// reaches the route without supplied doubles is an explicit 500. Serial suite: the tests assert on
// per-request mock state, and one deliberately drives an unbound request, so they must not interleave.
@Suite(.wiremvc(NoteTestBinds.mockBackend), .serialized)
struct BindTests {
    /// A supplied mock flows through the variant proxy's scope entry into the request-scoped controller —
    /// the response is `stamped:mock:x` (the app `@Singleton` `NoteStamp` still stamps, proving the borrow),
    /// and the exact instance the test holds recorded the call (reference identity via its recorded state).
    @Test func suppliedMockIsObservedOverHTTP() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock) {
            let response = try await TestClient.current.get("/notes/x")
            #expect(response.status == 200)
            let note = try response.json(Note.self)
            #expect(note.value == "stamped:mock:x")
        }
        #expect(mock.recordedNotes == ["x"])
    }

    /// A request reaching a keyed route without `withBindValues` — no supplied doubles — is an explicit 500
    /// under the keyed suite (the decided behaviour), not a silent fall-through to the real backend.
    @Test func missingDoublesIsExplicit500() async throws {
        let response = try await TestClient.current.get("/notes/y")
        #expect(response.status == 500)
    }

    /// Two concurrent `withBindValues` closures with distinct mocks don't cross: each request carries its own
    /// correlation id, so each resolves to its own supplied instance. Driven as child tasks so the closures
    /// are open simultaneously.
    @Test func parallelMocksDoNotCross() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for tag in ["alpha", "beta"] {
                group.addTask {
                    let mock = MockNoteBackend()
                    try await withBindValues(noteBackend: mock) {
                        let response = try await TestClient.current.get("/notes/\(tag)")
                        #expect(response.status == 200)
                        #expect(try response.json(Note.self).value == "stamped:mock:\(tag)")
                    }
                    #expect(mock.recordedNotes == [tag])
                }
            }
            try await group.waitForAll()
        }
    }
}
