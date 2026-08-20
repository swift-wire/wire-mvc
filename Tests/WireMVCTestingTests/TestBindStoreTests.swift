import Foundation
import HTTPAPIs
import HTTPTypes
import Synchronization
import Testing
import WireMVC

@testable import WireMVCTesting

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// H1 unit coverage for the doubles-supply runtime. H1 has no real `TestingKey`, so a dummy stands in for
// the generated `_<Key>Doubles`.
private struct Doubles: Sendable, Equatable {
    let value: Int
}

/// A minimal handler for the suites these tests stand up — `withClient(supplying:)` hands out a client, so
/// it needs a running suite to take one from.
private struct OKHandler: HTTPServerRequestHandler {
    typealias RequestContext = WireMVCContext<InProcessRequestContext>
    typealias Reader = InProcessReader
    typealias ResponseSender = InProcessResponseSender

    func handle(
        request: HTTPRequest,
        requestContext: consuming WireMVCContext<InProcessRequestContext>,
        reader: consuming sending InProcessReader,
        responseSender: consuming sending InProcessResponseSender
    ) async throws {
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok))
    }
}

@Suite struct TestBindStoreTests {
    @Test func putValueRemoveRoundTrip() {
        let store = TestBindStore<Doubles>()
        let id = CorrelationID.mint()

        #expect(store.value(for: id) == nil)

        store.put(Doubles(value: 7), for: id)
        #expect(store.value(for: id) == Doubles(value: 7))
        // Non-removing read — the slot survives repeated reads.
        #expect(store.value(for: id) == Doubles(value: 7))

        store.remove(id)
        #expect(store.value(for: id) == nil)
    }

    /// `withClient(supplying:)` hands the body a client **pinned to the minted id**, with the doubles registered
    /// under that id for the closure's duration, and drops the slot on exit. The id rides the client rather
    /// than a task-local, so what the body holds is what its requests will carry.
    @Test func suppliedDoublesBindTheClientAndClearAfter() async throws {
        let store = TestBindStore<Doubles>()
        let mode = WireMVCTestMode.inProcess
        let observed = Mutex<CorrelationID?>(nil)
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: OKHandler(),
            services: []
        ) {
            let id = try await WireMVCTesting.withClient(supplying: Doubles(value: 3), in: store) { client in
                let id = try #require(client.boundCorrelationID)
                // The double is in the store under the client's id for the duration of the closure.
                #expect(store.value(for: id) == Doubles(value: 3))
                return id
            }
            observed.withLock { $0 = id }
            // A client obtained without a binding carries no id, so it supplies no doubles.
            #expect(TestClient.forSuite.boundCorrelationID == nil)
        }
        #expect(store.value(for: try #require(observed.withLock { $0 })) == nil)
    }

    struct MarkerError: Error {}

    @Test func suppliedDoublesRemoveTheSlotOnThrow() async throws {
        let store = TestBindStore<Doubles>()
        let captured = Mutex<CorrelationID?>(nil)
        let mode = WireMVCTestMode.inProcess

        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: OKHandler(),
            services: []
        ) {
            await #expect(throws: MarkerError.self) {
                try await WireMVCTesting.withClient(supplying: Doubles(value: 9), in: store) { client in
                    captured.withLock { $0 = client.boundCorrelationID }
                    throw MarkerError()
                }
            }
        }

        // `defer` ran despite the throw: the store slot was dropped.
        let id = captured.withLock { $0 }
        #expect(id != nil)
        #expect(store.value(for: id!) == nil)
    }

    @Test func concurrentClosuresGetDistinctIDsAndIsolatedSlots() async throws {
        let store = TestBindStore<Doubles>()
        let mode = WireMVCTestMode.inProcess
        let results = Mutex<[(CorrelationID, Doubles?)]>([])

        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: OKHandler(),
            services: []
        ) {
            async let first = WireMVCTesting.withClient(supplying: Doubles(value: 100), in: store) {
                (client: TestClient) -> (CorrelationID, Doubles?) in
                let id = try #require(client.boundCorrelationID)
                try await Task.sleep(for: .milliseconds(20))
                return (id, store.value(for: id))
            }
            async let second = WireMVCTesting.withClient(supplying: Doubles(value: 200), in: store) {
                (client: TestClient) -> (CorrelationID, Doubles?) in
                let id = try #require(client.boundCorrelationID)
                try await Task.sleep(for: .milliseconds(20))
                return (id, store.value(for: id))
            }
            let a = try await first
            let b = try await second
            results.withLock { $0 = [a, b] }
        }
        let ((idA, valueA), (idB, valueB)) = (results.withLock { $0 }[0], results.withLock { $0 }[1])

        // Distinct ids and each closure reads back only its own double.
        #expect(idA != idB)
        #expect(valueA == Doubles(value: 100))
        #expect(valueB == Doubles(value: 200))

        // Both slots removed on exit.
        #expect(store.value(for: idA) == nil)
        #expect(store.value(for: idB) == nil)
    }

    @Test func correlationIDHeaderRoundTrip() {
        let id = CorrelationID.mint()
        let headerValue = id.rawValue.uuidString

        #expect(correlationID(fromHeaderValue: headerValue) == id)
        #expect(correlationID(fromHeaderValue: "not-a-uuid") == nil)
    }
}

/// The backstop behind the keyed dispatch's emission gating: doubles resolve only while a suite is serving.
/// The generated preamble guards on ``WireMVCTesting/harnessIsActive``, so these pin the state machine it
/// reads — a process not running a suite must never report active, and overlapping suites must not clear
/// each other's mark.
///
/// Asserted on a *fresh* ``HarnessActivity`` rather than the process-global one: this target's other suites
/// call `runSuite`, which holds the global mark, and they run in parallel — so absolute assertions on
/// `WireMVCTesting.harnessIsActive` would be flaky by construction. The global is one instance of this
/// mechanism; `theGlobalMarkIsHeldInsideWithActiveHarness` covers the wiring.
@Suite struct HarnessActivityTests {
    @Test func inactiveUntilABodyIsHeld() {
        #expect(HarnessActivity().isActive == false)
    }

    @Test func activeOnlyForTheDurationOfTheBody() async throws {
        let activity = HarnessActivity()
        try await activity.withActive {
            #expect(activity.isActive)
        }
        #expect(activity.isActive == false)
    }

    /// Swift Testing runs suites in parallel, so two can overlap. The inner one exiting must not clear the
    /// outer one's mark — that would leave a still-serving suite unable to resolve its own doubles.
    @Test func overlappingHoldsEachKeepTheMark() async throws {
        let activity = HarnessActivity()
        try await activity.withActive {
            try await activity.withActive {
                #expect(activity.isActive)
            }
            #expect(activity.isActive)  // the inner exit must not clear the outer hold
        }
        #expect(activity.isActive == false)
    }

    /// A suite that throws still clears its hold — balanced in a `defer`, so a failing suite can't leave the
    /// process permanently marked active (which would keep the dispatch resolving doubles afterwards).
    @Test func aThrowingBodyStillClearsItsHold() async {
        struct Boom: Error {}
        let activity = HarnessActivity()
        await #expect(throws: Boom.self) {
            try await activity.withActive { throw Boom() }
        }
        #expect(activity.isActive == false)
    }

    /// The global is wired to the mechanism — race-free because it only ever asserts `true` *inside* a hold,
    /// which a concurrently-running suite cannot falsify.
    @Test func theGlobalMarkIsHeldInsideWithActiveHarness() async throws {
        try await WireMVCTesting.withActiveHarness {
            #expect(WireMVCTesting.harnessIsActive)
        }
    }
}

@Suite struct TestClientHeaderTests {
    /// The loopback transport's half of the stamping rule: the header is present exactly when the *client*
    /// carries an id, not when the call happens to sit inside a closure.
    /// The caller's headers are authoritative — `URLSession` must not manage cookies for us.
    ///
    /// With this on, the shared `HTTPCookieStorage` accumulates every `Set-Cookie` a route sends and then
    /// *replaces* an explicitly-set `Cookie` header with whatever it has stored. A suite that logs in twice
    /// then sends the second session's cookie on a request that explicitly carries the first, and the route
    /// answers as the wrong user — with no error, and only on the platform whose Foundation rewrites it.
    /// It made a cookie-based session example fail on Linux CI while passing on macOS.
    @Test func doesNotLetURLSessionManageCookies() {
        let client = TestClient(host: "127.0.0.1", port: 8080)
        let request = client.makeRequest(
            "GET",
            "/me",
            body: nil,
            headers: ["Cookie": "session=first"]
        )
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=first")

        // Setting only the per-request flag looked correct on macOS and changed nothing on Linux CI, so the
        // session's configuration is what this actually rests on. Asserted here for that reason — the
        // earlier version of this test checked the flag alone and passed while the bug was live.
        let configuration = TestClient.makeSession().configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
    }

    @Test func stampsHeaderWhenTheClientCarriesAnID() {
        let unbound = TestClient(host: "127.0.0.1", port: 8080)
        #expect(
            unbound.makeRequest("GET", "/todos", body: nil, headers: [:])
                .value(forHTTPHeaderField: wireMVCTestBindsHeader) == nil
        )

        let id = CorrelationID.mint()
        #expect(
            unbound.bound(to: id).makeRequest("GET", "/todos", body: nil, headers: [:])
                .value(forHTTPHeaderField: wireMVCTestBindsHeader) == id.rawValue.uuidString
        )

        // The original is untouched — binding produces a new client.
        #expect(
            unbound.makeRequest("GET", "/todos", body: nil, headers: [:])
                .value(forHTTPHeaderField: wireMVCTestBindsHeader) == nil
        )
    }
}
