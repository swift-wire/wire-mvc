import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// H2.2b gate — the keyed test harness end to end over real HTTP. `@Suite(.wiremvc(NoteTestBinds.mockBackend, .swiftHttpServer))`
// stands the app up on a harness-owned server bound to an ephemeral loopback port — the app's own
// `createServer()` is not involved — and parks the variant contributor proxies for the key; each
// test supplies its per-request mocks with `withClient(supplying: <Controller>Doubles(...))` — one overload per
// routed controller, each taking only the slots that controller reaches. The key carries a by-type
// `@BindType(NoteBackend.self, …)` slot AND a keyed `@BindType(PrefsKeys.primary, …)` slot, but no test names
// both: `/notes/{id}` supplies the by-type mock alone, `/prefs/{id}` the keyed one alone, and `/ping` supplies
// nothing at all. A request that reaches a keyed route without supplied doubles is still an explicit 500.
//
// The suite is **parallel** (no `.serialized`): the harness's promise is that per-request doubles isolate
// concurrent requests by correlation id, so the tests must run — and pass — under real concurrency.
// `differentlyMockedRequestsInterleaveWithoutCrossing` proves it directly, forcing two differently-mocked
// requests to be simultaneously in-flight.
@Suite(.wiremvc(NoteTestBinds.mockBackend, .swiftHttpServer))
struct BindTests {
    /// A supplied mock flows through the variant proxy's scope entry into the request-scoped controller —
    /// the response is `stamped:mock:x` (the app `@Singleton` `NoteStamp` still stamps, proving the borrow),
    /// and the exact instance the test holds recorded the call (reference identity via its recorded state).
    @Test func suppliedMockIsObservedOverHTTP() async throws {
        let mock = MockNoteBackend()
        try await withClient(supplying: NotesControllerDoubles(noteBackend: mock)) { notes in
            let note = try await notes.note(id: "x")
            #expect(note.value == "stamped:mock:x")
        }
        #expect(mock.recordedNotes == ["x"])
    }

    /// The **app-scoped** (`@Singleton`) `SummaryController`, marked `@TestScopable` — the seedless case, plus a
    /// **mock-consuming middleware factory** (Phase B). It's built once against the real backend in production,
    /// but under the keyed suite the variant rebuilds it per request from the doubles alone
    /// (`_wireEnterScope(doubles)`, no seed), so `GET /summary/{id}` serves the supplied mock. Its
    /// `@Middleware(SummaryAuditKeys.factory)` also `@Inject`s the backend — it can't hold the mock (built once
    /// at facade time), so swift-wire re-emits it as a variant factory whose `create(doubles:)` sources the
    /// mock per request, and the variant witness's fold threads the per-request doubles to that `create`. Both
    /// the middleware and the handler touch the **same** supplied instance: it records the middleware's `audit`
    /// call (before the chain forwards) and then the handler's `summary:x` call.
    @Test func appScopedTestScopableRouteServesMockSeedlessly() async throws {
        let mock = MockNoteBackend()
        try await withClient(supplying: SummaryControllerDoubles(noteBackend: mock)) { summary in
            let note = try await summary.summary(id: "x")
            #expect(note.value == "mock:summary:x")
        }
        // The exact supplied instance recorded the mock-consuming middleware's `audit` call *and* the handler's
        // `summary:x` call, in order — the one mock threaded both the seedless reconstruction and the lifted
        // variant factory's per-request `create(doubles:)`.
        #expect(mock.recordedNotes == ["audit", "summary:x"])
    }

    /// The **seed-scoped** counterpart to the test above. `AuditedController` is `@Scoped(seed: HTTPRequest.self)`
    /// and its `@Middleware(ScopedAuditKeys.factory)` injects the mocked `NoteBackend`, so the factory can't hold
    /// it any more than `SummaryAudit` could — the seed-scoped path threads doubles into the lifted factory the
    /// same way the seedless one does. The one supplied instance records the middleware's `scoped-audit` call and
    /// then the handler's `audited:x`.
    @Test func seedScopedRouteWithMockConsumingMiddlewareServesMock() async throws {
        let mock = MockNoteBackend()
        try await withClient(supplying: AuditedControllerDoubles(noteBackend: mock)) { audited in
            let note = try await audited.audited(id: "x")
            #expect(note.value == "mock:audited:x")
        }
        #expect(mock.recordedNotes == ["scoped-audit", "audited:x"])
    }

    /// The KEYED `@BindType(PrefsKeys.primary, …)` slot form: `PrefsController` injects the keyed binding
    /// (`@Inject(PrefsKeys.primary) var prefs`). `withBindValues` supplies the keyed doubles field WireGen
    /// names — `prefsBackendKeyedPrefsKeysPrimary` — and `GET /prefs/x` returns the mock's `mock-pref:x`, the
    /// exact instance recording the call. (Both slots share the one key, so a throwaway note mock rides along;
    /// isolating keyed vs by-type into separate suites needs multi-key.)
    @Test func keyedBindTypeSlotThreadsMockOverHTTP() async throws {
        let mock = MockPrefsBackend()
        try await withClient(supplying: PrefsControllerDoubles(prefsBackendKeyedPrefsKeysPrimary: mock)) { prefs in
            let note = try await prefs.read(id: "x")
            #expect(note.value == "mock-pref:x")
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
        try await withClient(supplying: AccountControllerDoubles(noteBackend: mock)) { account in
            let note = try await account.account(id: "x")
            #expect(note.value == "mock:init")
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
        try await withClient(supplying: CartControllerDoubles(noteBackend: mock)) { cart in
            let note = try await cart.cart(id: "x")
            #expect(note.value == "mock:init")
        }
        #expect(mock.recordedNotes == ["init"])
    }

    /// A factory-carrying keyed route: `LoggedController` carries `@Middleware(AccessLogKeys.factory)`, so its
    /// variant proxy holds a lifted `_wireFactory_<key>`. Under the keyed suite it enters cleanly and serves
    /// over HTTP (the swift-wire factory-facade fix) — `GET /logged/` returns its constant. Its factory
    /// injects nothing mocked, so its doubles struct is empty: the test supplies `LoggedControllerDoubles()`
    /// and never constructs a mock.
    @Test func factoryCarryingRouteEntersAndServes() async throws {
        try await withClient(supplying: LoggedControllerDoubles()) { logged in
            let note = try await logged.logged()
            #expect(note.value == "logged")
        }
    }

    /// A mock-IGNORING keyed route: `/ping` injects nothing mocked, so its doubles struct has no fields at
    /// all. The uniform "keyed suite ⇒ supply doubles" rule still holds — the store must carry an entry for
    /// the request to correlate — but what it supplies is now `PingControllerDoubles()`, naming no mock. This
    /// is the over-specification per-controller doubles exists to remove.
    @Test func mockIgnoringRouteServesUnderWithBindValues() async throws {
        try await withClient(supplying: PingControllerDoubles()) { ping in
            let note = try await ping.ping()
            #expect(note.value == "pong")
        }
    }

    /// The uniform rule survives per-controller doubles: a request to `/ping` WITHOUT `withBindValues` is an
    /// explicit 500, even though the doubles it would supply are empty. The 500 names the controller whose
    /// doubles are missing, so the message says which `withBindValues` to add.
    @Test func mockIgnoringRouteWithoutDoublesIs500() async throws {
        try await withClient(for: PingControllerClient.self) { ping in
            let error = try await #require(throws: WireMVCRouteError.self) { try await ping.ping() }
            #expect(error.status == .internalServerError)
        }
    }

    /// The keyed side of the shared-route coexistence check (see `KeylessCoexistTests`): under the keyed
    /// suite, `withBindValues` + `GET /notes/z` resolves the mock — while the parallel keyless suite serves
    /// the real backend on the very same route. The two don't cross because the variant proxy rides only the
    /// keyed suite's serve task tree.
    @Test func keyedSuiteServesMockOnSharedRoute() async throws {
        let mock = MockNoteBackend()
        try await withClient(supplying: NotesControllerDoubles(noteBackend: mock)) { notes in
            let note = try await notes.note(id: "z")
            #expect(note.value == "stamped:mock:z")
        }
        #expect(mock.recordedNotes == ["z"])
    }

    /// A request reaching a keyed route without `withBindValues` — no supplied doubles — is an explicit 500
    /// under the keyed suite (the decided behaviour), not a silent fall-through to the real backend. Runs in
    /// the parallel suite alongside bound requests: an unbound, header-less request must still 500 while other
    /// tests hold live doubles in the store.
    @Test func missingDoublesIsExplicit500() async throws {
        try await withClient(for: NotesControllerClient.self) { notes in
            let error = try await #require(throws: WireMVCRouteError.self) { try await notes.note(id: "y") }
            #expect(error.status == .internalServerError)
        }
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
                            try await withClient(supplying: NotesControllerDoubles(noteBackend: mock)) { notes in
                                let note = try await notes.note(id: tag)
                                #expect(note.value == "stamped:mock:\(tag)")
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

    /// A **cross-controller flow**: doubles are per controller, so a test driving two controllers nests one
    /// block per controller — and both clients must keep working inside the innermost block. That holds only
    /// because a nested `withBindValues` reuses the ambient correlation id instead of minting a fresh one; a
    /// fresh id would rebind the task-local and leave the OUTER controller's store — keyed by the outer id —
    /// answering nothing, so `notes.note` here would 500 while telling the test to wrap a call it had already
    /// wrapped. Each controller sees only its own mock.
    @Test func crossControllerFlowDrivesBothClients() async throws {
        let noteMock = MockNoteBackend()
        let prefsMock = MockPrefsBackend()
        try await withClient(supplying: NotesControllerDoubles(noteBackend: noteMock)) { notes in
            try await withClient(supplying: PrefsControllerDoubles(prefsBackendKeyedPrefsKeysPrimary: prefsMock)) { prefs in
                let pref = try await prefs.read(id: "p")
                #expect(pref.value == "mock-pref:p")
                // The OUTER controller's client, driven from inside the inner block.
                let note = try await notes.note(id: "n")
                #expect(note.value == "stamped:mock:n")
            }
            // Still usable after the inner block exits — its restore didn't drop this block's slot.
            let after = try await notes.note(id: "after")
            #expect(after.value == "stamped:mock:after")
        }
        #expect(noteMock.recordedNotes == ["n", "after"])
        #expect(prefsMock.recordedPrefs == ["p"])
    }
    /// Two bindings of the **same** controller, nested. Each client is a handle on its own binding — the id
    /// rides the client, not an ambient task-local — so `notes1` still resolves to the outer mock from inside
    /// the inner block. Under an ambient id both would have resolved to the innermost binding, making the two
    /// parameters indistinguishable and `notes1` a lie.
    @Test func nestedBindingsOfOneControllerStayDistinct() async throws {
        let outerMock = MockNoteBackend()
        let innerMock = MockNoteBackend()
        try await withClient(supplying: NotesControllerDoubles(noteBackend: outerMock)) { notes1 in
            try await withClient(supplying: NotesControllerDoubles(noteBackend: innerMock)) { notes2 in
                let viaOuter = try await notes1.note(id: "outer")
                #expect(viaOuter.value == "stamped:mock:outer")
                let viaInner = try await notes2.note(id: "inner")
                #expect(viaInner.value == "stamped:mock:inner")
            }
        }
        #expect(outerMock.recordedNotes == ["outer"])
        #expect(innerMock.recordedNotes == ["inner"])
    }

}

/// The interleaving guard's timeout — thrown to unwind the suite when the two requests never rendezvous.
private struct BarrierTimedOut: Error {
}
