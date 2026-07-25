import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// H2.2b gate — the keyed test harness end to end over real HTTP. `@Suite(.wiremvc(NoteTestBinds.mockBackend))`
// stands up the app on an ephemeral loopback port and parks the variant contributor proxy for the key; each
// test supplies a per-request mock with `withBindValues(noteBackend:)`, and `GET /notes/{id}` — a
// request-scoped controller injecting the `@BindType`d `NoteBackend` AND borrowing the app `@Singleton`
// `NoteStamp` (the borrow fix) — observes the mock's answer instead of the real backend. A request that
// reaches the route without supplied doubles is an explicit 500.
//
// The suite is **parallel** (no `.serialized`): the harness's promise is that per-request doubles isolate
// concurrent requests by correlation id, so the tests must run — and pass — under real concurrency.
// `differentlyMockedRequestsInterleaveWithoutCrossing` proves it directly, forcing two differently-mocked
// requests to be simultaneously in-flight.
@Suite(.wiremvc(NoteTestBinds.mockBackend))
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

    /// The keyed side of the shared-route coexistence check (see `KeylessCoexistTests`): under the keyed
    /// suite, `withBindValues` + `GET /notes/z` resolves the mock — while the parallel keyless suite serves
    /// the real backend on the very same route. The two don't cross because the variant proxy rides only the
    /// keyed suite's serve task tree.
    @Test func keyedSuiteServesMockOnSharedRoute() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock) {
            let response = try await TestClient.current.get("/notes/z")
            #expect(response.status == 200)
            #expect(try response.json(Note.self).value == "stamped:mock:z")
        }
        #expect(mock.recordedNotes == ["z"])
    }

    /// A request reaching a keyed route without `withBindValues` — no supplied doubles — is an explicit 500
    /// under the keyed suite (the decided behaviour), not a silent fall-through to the real backend. Runs in
    /// the parallel suite alongside bound requests: an unbound, header-less request must still 500 while other
    /// tests hold live doubles in the store.
    @Test func missingDoublesIsExplicit500() async throws {
        let response = try await TestClient.current.get("/notes/y")
        #expect(response.status == 500)
    }

    /// The core isolation guarantee, under forced overlap: two differently-mocked requests are held
    /// *simultaneously* in their handlers on a two-party barrier, so neither can return before the other has
    /// entered. Each must still see its own supplied mock — its own response value AND its own mock recording
    /// only its own tag. A correlation-id leak would cross the doubles (a mock records both tags, or a request
    /// answers the other's value). A guard task times the rendezvous out with a clear failure rather than
    /// hanging, so a server that can't serve the two concurrently is a reported finding, not a stuck CI.
    @Test func differentlyMockedRequestsInterleaveWithoutCrossing() async throws {
        let barrier = TwoPartyBarrier()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withThrowingTaskGroup(of: Void.self) { requests in
                    for tag in ["alpha", "beta"] {
                        requests.addTask {
                            let mock = MockNoteBackend(onNote: { await barrier.arrive() })
                            try await withBindValues(noteBackend: mock) {
                                let response = try await TestClient.current.get("/notes/\(tag)")
                                #expect(response.status == 200)
                                #expect(try response.json(Note.self).value == "stamped:mock:\(tag)")
                            }
                            // Reference identity: this exact instance recorded only its own tag — no cross.
                            #expect(mock.recordedNotes == [tag])
                        }
                    }
                    try await requests.waitForAll()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                Issue.record(
                    "interleaving barrier timed out: the two differently-mocked requests were not in-flight concurrently"
                )
                throw BarrierTimedOut()
            }
            // Whichever finishes first: the two requests completing (Void) or the timeout (throws).
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
            while (try? await group.next()) != nil {}  // drain the cancelled guard, swallowing its cancellation
        }
    }
}

/// The interleaving guard's timeout — thrown to unwind the suite when the two requests never rendezvous.
private struct BarrierTimedOut: Error {}
