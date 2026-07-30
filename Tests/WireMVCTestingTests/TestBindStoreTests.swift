import Foundation
import Synchronization
import Testing

@testable import WireMVCTesting

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// H1 unit coverage for the doubles-supply runtime. H1 has no real `TestingKey`, so a dummy stands in for
// the generated `_<Key>Doubles`.
private struct Doubles: Sendable, Equatable {
    let value: Int
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

    @Test func withBindValuesBindsTaskLocalAndClearsAfter() async throws {
        #expect(WireMVCTesting.currentCorrelationID == nil)

        let store = TestBindStore<Doubles>()
        let observed: CorrelationID? = try await WireMVCTesting.withBindValues(Doubles(value: 3), in: store) {
            let id = try #require(WireMVCTesting.currentCorrelationID)
            // The double is in the store under the bound id for the duration of the closure.
            #expect(store.value(for: id) == Doubles(value: 3))
            return id
        }

        // Task-local cleared and store slot dropped on exit.
        #expect(WireMVCTesting.currentCorrelationID == nil)
        #expect(store.value(for: try #require(observed)) == nil)
    }

    struct MarkerError: Error {}

    @Test func withBindValuesClearsAndRemovesOnThrow() async {
        let store = TestBindStore<Doubles>()
        let captured = Mutex<CorrelationID?>(nil)

        await #expect(throws: MarkerError.self) {
            try await WireMVCTesting.withBindValues(Doubles(value: 9), in: store) {
                captured.withLock { $0 = WireMVCTesting.currentCorrelationID }
                throw MarkerError()
            }
        }

        // `defer` ran despite the throw: task-local restored, store slot dropped.
        #expect(WireMVCTesting.currentCorrelationID == nil)
        let id = captured.withLock { $0 }
        #expect(id != nil)
        #expect(store.value(for: id!) == nil)
    }

    @Test func concurrentClosuresGetDistinctIDsAndIsolatedSlots() async throws {
        let store = TestBindStore<Doubles>()

        async let first = WireMVCTesting.withBindValues(Doubles(value: 100), in: store) {
            () -> (CorrelationID, Doubles?) in
            let id = try #require(WireMVCTesting.currentCorrelationID)
            try await Task.sleep(for: .milliseconds(20))
            return (id, store.value(for: id))
        }
        async let second = WireMVCTesting.withBindValues(Doubles(value: 200), in: store) {
            () -> (CorrelationID, Doubles?) in
            let id = try #require(WireMVCTesting.currentCorrelationID)
            try await Task.sleep(for: .milliseconds(20))
            return (id, store.value(for: id))
        }

        let (idA, valueA) = try await first
        let (idB, valueB) = try await second

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
