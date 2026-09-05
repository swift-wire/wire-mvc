// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

// A single-use two-party rendezvous: the first `arrive()` suspends until the second arrives, then both
// proceed. Dropped into two differently-mocked in-flight requests (via `MockNoteBackend.onNote`), it forces
// them to be provably in their handlers *simultaneously* before either returns — so the interleaving-isolation
// test observes real concurrency, not sequential luck. The suite's timeout guard unwinds a party that never
// gets its partner, so a server that can't serve the two concurrently fails fast rather than hanging.
actor TwoPartyBarrier {
    private var waiter: CheckedContinuation<Void, Never>?

    /// Rendezvous: the first caller suspends; the second resumes the first and returns — both then proceed.
    func arrive() async {
        if let waiter {
            self.waiter = nil
            waiter.resume()
            return
        }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
