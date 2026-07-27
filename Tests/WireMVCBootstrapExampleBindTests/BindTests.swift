import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// H2.2b gate — the keyed test harness end to end over real HTTP. `@Suite(.wiremvc(NoteTestBinds.mockBackend))`
// stands up the app on an ephemeral loopback port and parks the variant contributor proxies for the key; each
// test supplies its per-request mocks with the generated `withBindValues(noteBackend:prefsBackendKeyed…:)` —
// the key carries a by-type `@BindType(NoteBackend.self, …)` slot AND a keyed `@BindType(PrefsKeys.primary, …)`
// slot, so its doubles struct (and `withBindValues`) has a field for each. `GET /notes/{id}` (by-type) and
// `GET /prefs/{id}` (keyed) each observe their supplied mock. A request that reaches a keyed route without
// supplied doubles is an explicit 500.
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
        try await withBindValues(noteBackend: mock, prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()) {
            let response = try await TestClient.current.get("/notes/x")
            #expect(response.status == 200)
            let note = try response.json(Note.self)
            #expect(note.value == "stamped:mock:x")
        }
        #expect(mock.recordedNotes == ["x"])
    }

    /// The **app-scoped** (`@Singleton`) `SummaryController`, marked `@TestScopable` — the seedless case. It's
    /// built once against the real backend in production, but under the keyed suite the variant rebuilds it
    /// per request from the doubles alone (`_wireEnterScope(doubles)`, no seed), so `GET /summary/{id}` serves
    /// the supplied mock and the held instance records the call.
    @Test func appScopedTestScopableRouteServesMockSeedlessly() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock, prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()) {
            let response = try await TestClient.current.get("/summary/x")
            #expect(response.status == 200)
            #expect(try response.json(Note.self).value == "mock:summary:x")
        }
        #expect(mock.recordedNotes == ["summary:x"])
    }

    /// The KEYED `@BindType(PrefsKeys.primary, …)` slot form: `PrefsController` injects the keyed binding
    /// (`@Inject(PrefsKeys.primary) var prefs`). `withBindValues` supplies the keyed doubles field WireGen
    /// names — `prefsBackendKeyedPrefsKeysPrimary` — and `GET /prefs/x` returns the mock's `mock-pref:x`, the
    /// exact instance recording the call. (Both slots share the one key, so a throwaway note mock rides along;
    /// isolating keyed vs by-type into separate suites needs multi-key.)
    @Test func keyedBindTypeSlotThreadsMockOverHTTP() async throws {
        let mock = MockPrefsBackend()
        try await withBindValues(noteBackend: MockNoteBackend(), prefsBackendKeyedPrefsKeysPrimary: mock) {
            let response = try await TestClient.current.get("/prefs/x")
            #expect(response.status == 200)
            #expect(try response.json(Note.self).value == "mock-pref:x")
        }
        #expect(mock.recordedPrefs == ["x"])
    }

    /// The `@Scopable` cascade: `AccountController` reaches the mock ONLY through the `@Scopable`'d app
    /// `@Singleton` `AccountRegistry`, whose `init` reads `any NoteBackend`. Under the keyed suite the registry
    /// is lifted into the request scope and rebuilt per entry, so its init reads the supplied mock — the
    /// Phase-2 distinguishing property, observed over HTTP: `GET /account/x` returns the mock's init-read value
    /// (`mock:init`), and the exact supplied instance recorded that init-time `note("init")` call.
    @Test func cascadeMockThreadsThroughScopableSingletonInit() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock, prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()) {
            let response = try await TestClient.current.get("/account/x")
            #expect(response.status == 200)
            #expect(try response.json(Note.self).value == "mock:init")
        }
        // The lifted singleton's init read the exact supplied instance (reference identity via its recording).
        #expect(mock.recordedNotes == ["init"])
    }

    /// Level-2 transitive (the "key every controller" payoff): `CartController` injects only the
    /// request-scoped `CartService`, which injects the `@Scopable`'d `AccountRegistry`. The mock threads the
    /// whole chain — `CartService → AccountRegistry(lifted, init reads the mock)` — with NO `@VariantRoute`
    /// and no extra mark on `CartService`, purely because every seed-scoped controller is keyed. Over HTTP
    /// `GET /cart/x` returns the mock's init-read value; the exact instance recorded the init call.
    @Test func level2TransitiveRouteThreadsMockWithNoMark() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock, prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()) {
            let response = try await TestClient.current.get("/cart/x")
            #expect(response.status == 200)
            #expect(try response.json(Note.self).value == "mock:init")
        }
        #expect(mock.recordedNotes == ["init"])
    }

    /// A factory-carrying keyed route: `LoggedController` carries `@Middleware(AccessLogKeys.factory)`, so its
    /// variant proxy holds a lifted `_wireFactory_<key>`. Under the keyed suite it enters cleanly and serves
    /// over HTTP (the swift-wire factory-facade fix) — `GET /logged/` returns its constant, mock ignored.
    @Test func factoryCarryingRouteEntersAndServes() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock, prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()) {
            let response = try await TestClient.current.get("/logged/")
            #expect(response.status == 200)
            #expect(try response.json(Note.self).value == "logged")
        }
        #expect(mock.recordedNotes == [])
    }

    /// A mock-IGNORING keyed route: `/ping` injects nothing mocked, but under `.wiremvc(key)` it is keyed and
    /// its variant proxy takes the key's Doubles, which it ignores. With `withBindValues` it parks, enters,
    /// and serves its constant.
    @Test func mockIgnoringRouteServesUnderWithBindValues() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock, prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()) {
            let response = try await TestClient.current.get("/ping/")
            #expect(response.status == 200)
            #expect(try response.json(Note.self).value == "pong")
        }
        #expect(mock.recordedNotes == [])
    }

    /// The uniform "keyed suite ⇒ supply doubles" rule applies even to a mock-ignoring route — a request to
    /// `/ping` WITHOUT `withBindValues` is an explicit 500.
    @Test func mockIgnoringRouteWithoutDoublesIs500() async throws {
        let response = try await TestClient.current.get("/ping/")
        #expect(response.status == 500)
    }

    /// The keyed side of the shared-route coexistence check (see `KeylessCoexistTests`): under the keyed
    /// suite, `withBindValues` + `GET /notes/z` resolves the mock — while the parallel keyless suite serves
    /// the real backend on the very same route. The two don't cross because the variant proxy rides only the
    /// keyed suite's serve task tree.
    @Test func keyedSuiteServesMockOnSharedRoute() async throws {
        let mock = MockNoteBackend()
        try await withBindValues(noteBackend: mock, prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()) {
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
                            try await withBindValues(
                                noteBackend: mock,
                                prefsBackendKeyedPrefsKeysPrimary: MockPrefsBackend()
                            ) {
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
