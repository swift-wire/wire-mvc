// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

public import HTTPTypes
import Synchronization

// The request-dispatch side of the keyed harness (H2.2b). The generated keyed `.wiremvc(_:)` factory builds
// each subject's variant contributor proxy against the variant graph and registers its routes on the router
// directly, so the variant witness *is* the registered instance — there is no production branch to take and
// nothing held in a task-local. Each scoped route's generated dispatch reads the request's ``CorrelationID``
// back off the `X-WireMVC-Test-Binds` header, pulls that controller's doubles from its ``TestBindStore``, and
// enters request scope with them, so a `@BindType`d slot resolves to the supplied mock. A request arriving
// without the header — a keyless suite, or a keyed route driven through `withClient` — finds no doubles and
// is answered with the harness's explicit 500.
//
// The doubles travel by header + store rather than by task-local because a `withClient(supplying:)` closure runs
// client-side, in a task subtree disjoint from the server's: the id on the request is the only thread
// connecting the two.
//
// **Why the dispatch also checks that a harness is live.** The variant witness carrying this dispatch is
// emitted only for a test consumer (`--test-entry`) and registered only by the keyed factory, so the code
// below does not exist in a production binary at all. That is the primary guarantee and it is structural.
// ``harnessIsActive`` is the backstop *behind* it: if that emission gating ever regresses — a new adapter, a
// hand-written harness, a refactor of the plugin's test-target detection — the failure mode without it is a
// production request substituting a dependency because it carried a header, which is both remotely triggered
// and silent. With it, doubles resolve only while a ``WireMVCTesting/runSuite(_:on:handler:services:_:)`` is
// standing an app up in this process; anywhere else the dispatch fails closed to its explicit 500. One
// uncontended lock acquisition per request, on a path that only exists in test builds, and it converts the
// worst failure in the harness from silent to loud.

/// Read a request's ``CorrelationID`` from its `X-WireMVC-Test-Binds` header, or `nil` if the header is
/// absent or malformed — the dispatch side's entry point, keeping the header name and `HTTPTypes` lookup in
/// one place so the generated route code stays a single call. `nil` for every production request (the header
/// is only ever stamped by a ``TestClient`` carrying a binding).
///
/// A pure header read: it does *not* consult ``WireMVCTesting/harnessIsActive``. The generated dispatch
/// guards on both, so the two facts — "this request claims a correlation" and "a suite is serving right
/// now" — stay separately observable rather than collapsing into one nil.
public func wireMVCTestCorrelationID(in request: HTTPRequest) -> CorrelationID? {
    guard let name = HTTPField.Name(wireMVCTestBindsHeader),
        let value = request.headerFields[name]
    else { return nil }
    return correlationID(fromHeaderValue: value)
}

/// A balanced "is a suite serving right now" mark — held while a body runs, cleared on every exit.
///
/// A count rather than a flag because Swift Testing runs suites in parallel: two suites can overlap, and the
/// last one out must not clear the state the other is still serving under.
///
/// A type rather than loose statics so the mechanism is testable without the process-global instance — a
/// test target that itself stands suites up cannot assert absolute state on the global, since a concurrently
/// running suite holds the mark too.
final class HarnessActivity: Sendable {
    private let count = Mutex<Int>(0)

    /// Whether any body is currently held.
    var isActive: Bool { count.withLock { $0 > 0 } }

    /// Run `body` with the mark held. Balanced in a `defer`, so a throwing or cancelled body still clears
    /// its own hold and cannot leave the mark stuck on.
    func withActive<R>(_ body: () async throws -> R) async throws -> R {
        count.withLock { $0 += 1 }
        defer { count.withLock { $0 -= 1 } }
        return try await body()
    }
}

extension WireMVCTesting {
    /// The process-wide mark, held for the duration of every ``runSuite(_:on:handler:services:_:)``.
    ///
    /// Deliberately *process*-global rather than task-local. A task-local would be narrower, but it would
    /// have to survive the hop from `runSuite` into the server's request handlers — which is the server's
    /// business, not ours, and an executor that dispatched onto a detached task would silently drop it,
    /// turning every keyed request into a 500. The property being defended does not need that precision: a
    /// production process never calls `runSuite`, so it reads `false` there, and inside a test process an
    /// over-broad `true` costs nothing (doubles still require a correlation id minted by
    /// `withClient(supplying:)` and carried on the client that issued the request).
    static let harnessActivity = HarnessActivity()

    /// Whether a suite is serving right now — the condition the generated keyed dispatch requires before it
    /// will resolve a request's doubles. `false` in any process that is not running a
    /// ``runSuite(_:on:handler:services:servicePolicy:runTests:)``, which includes every production process.
    public static var harnessIsActive: Bool { harnessActivity.isActive }

    /// Run `body` with this process marked as serving a suite.
    static func withActiveHarness<R>(_ body: () async throws -> R) async throws -> R {
        try await harnessActivity.withActive(body)
    }
}
