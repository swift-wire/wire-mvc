// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

public import Foundation
import Synchronization

// The doubles-supply channel for a `@WireMVCBootstrap` app under real HTTP. The test drives the server
// over the loopback boundary, so the only per-request channel is the request itself:
// `withClient(supplying:)` registers the test's concrete doubles in an in-process store under a freshly minted
// `CorrelationID`, and
// hands the body a `TestClient` pinned to that id, which stamps it on the `X-WireMVC-Test-Binds` header of
// every request that client drives. The request dispatch (generated, H2) reads the header back, pulls the
// doubles from the store, and threads them into the variant scope-entry. The store holds the CONCRETE
// `_<Key>Doubles` through its type parameter — no boxing, no downcast.

/// Correlates a `withClient(supplying:)` closure with the requests it drives: minted per closure, carried by the
/// client that closure hands out, stamped on the request header, and used to key the store slot holding that
/// closure's doubles.
public struct CorrelationID: Sendable, Hashable {
    /// The underlying identity, rendered onto the request header as its UUID string.
    public let rawValue: UUID

    /// Wrap an existing UUID — used by ``correlationID(fromHeaderValue:)`` when parsing the header back.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// A fresh, unique correlation id for one `withClient(supplying:)` closure.
    public static func mint() -> CorrelationID {
        CorrelationID(rawValue: UUID())
    }
}

/// The per-key doubles store: a `Mutex`-guarded map from a request's ``CorrelationID`` to the concrete
/// `Doubles` the test supplied for it. A framework generic instantiated per `TestingKey` as a generated
/// static (the generated `_<Key>Doubles` is `Sendable`), so the supplying call and the dispatch share
/// the exact stored type — the dispatch reads it back concretely and hands it straight to the scope-entry.
public final class TestBindStore<Doubles: Sendable>: Sendable {
    private let slots = Mutex<[CorrelationID: Doubles]>([:])

    /// A new, empty store — one per key, held as a generated static.
    public init() {}

    /// Register `doubles` under `id`, replacing any existing slot for it.
    public func put(_ doubles: Doubles, for id: CorrelationID) {
        slots.withLock { $0[id] = doubles }
    }

    /// The doubles registered for `id`, or `nil` if none — a non-removing read, so the dispatch can read
    /// once per request while the closure keeps the slot alive until it exits.
    public func value(for id: CorrelationID) -> Doubles? {
        slots.withLock { $0[id] }
    }

    /// Drop `id`'s slot — called from `withClient(supplying:)`'s `defer` on the way out.
    public func remove(_ id: CorrelationID) {
        slots.withLock { _ = $0.removeValue(forKey: id) }
    }
}

/// The request header carrying a request's ``CorrelationID`` from `TestClient` to the dispatch. Never
/// emitted in production — only a `TestClient` carrying a binding stamps it.
public let wireMVCTestBindsHeader = "X-WireMVC-Test-Binds"

/// Parse a ``CorrelationID`` from a raw `X-WireMVC-Test-Binds` header value, or `nil` if it isn't a valid
/// id — the dispatch side (H2) uses this to look the request's doubles up in the store.
public func correlationID(fromHeaderValue value: String) -> CorrelationID? {
    UUID(uuidString: value).map(CorrelationID.init(rawValue:))
}

extension WireMVCTesting {
    /// The framework core the generated per-controller `withClient(supplying:)` wrapper calls: mint a
    /// ``CorrelationID``, register `doubles` under it in that controller's `store`, and hand `body` a
    /// ``TestClient`` **pinned to that id**. The slot is dropped on exit (`defer` — survives
    /// throws/cancellation; a crashed process drops the whole store). The generated wrapper passes the
    /// concrete `_<Variant>_<Subject>Doubles` the test built, so the store's type parameter is that exact
    /// type — no boxing.
    ///
    /// **The id rides the client, not a task-local.** A client is the handle on one binding: requests it
    /// drives carry its id wherever they are called from, so nested blocks address their own doubles and two
    /// bindings of the same controller stay distinguishable. An ambient id would instead make every request
    /// inside a block resolve to the innermost binding, whichever client it was driven through.
    public static func withClient<Doubles: Sendable, R>(
        supplying doubles: Doubles,
        in store: TestBindStore<Doubles>,
        _ body: (TestClient) async throws -> R
    ) async throws -> R {
        let id = CorrelationID.mint()
        store.put(doubles, for: id)
        defer { store.remove(id) }
        // A fresh session per scope: see `TestClient.withFreshTransport()`. Tests in a suite run in
        // parallel, so a shared pool lets one test's reset connection surface as another's failure.
        let client = TestClient.forSuite.withFreshTransport().bound(to: id)
        defer { client.releaseTransport() }
        return try await body(client)
    }

    /// The no-doubles sibling: a ``TestClient`` carrying no correlation id, for requests that supply nothing —
    /// a keyless suite, a path no controller declares (the `@NotFound` fallback, the Bootstrap's introspection
    /// mount), or a keyed route driven deliberately unbound to assert its explicit 500. The generated
    /// `withClient(for:)` wrappers call this.
    public static func withClient<R>(_ body: (TestClient) async throws -> R) async throws -> R {
        let client = TestClient.forSuite.withFreshTransport()
        defer { client.releaseTransport() }
        return try await body(client)
    }
}
