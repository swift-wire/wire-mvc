// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

// The regression the original gate lacked: a keyless `@Suite(.wiremvc(.swiftHttpServer))` and the keyed
// `@Suite(.wiremvc(NoteTestBinds.mockBackend))` (BindTests) live in the SAME target, run in **parallel**
// (neither serialized), and hit the SAME route `/notes/{id}`. Each suite stands up its own server; the keyed
// factory binds the variant proxy to a `@TaskLocal` *around its own serve*, so a keyless serving never sees
// it — its `/notes/z` resolves the real backend, while the keyed suite's `/notes/z` (with `withClient(supplying:)`)
// resolves the mock, concurrently, without crossing.
//
// With the earlier process-global box this keyless request would have 500'd — the keyed suite's parked proxy
// leaked into every serving in the process, so a headerless keyless request tripped the missing-doubles 500.
// The task-local binds per-serve, so it doesn't. This test would fail (500) under the old box.
@Suite(.wiremvc(.swiftHttpServer))
struct KeylessCoexistTests {
    /// The keyless suite serves the real backend on `/notes/z` — no keyed suite's proxy leaks in. A 500 here
    /// would mean the variant-proxy signal crossed serving boundaries.
    @Test func keylessSuiteServesRealBackendOnSharedRoute() async throws {
        try await withClient(for: NotesControllerClient.self) { notes in
            let note = try await notes.note(id: "z")
            #expect(note.value == "stamped:real:z")
        }
    }
}
