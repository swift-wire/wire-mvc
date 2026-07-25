import Synchronization
package import Wire
package import WireMVCBootstrapExample

// The test-graph variant for this suite: `@BindType(NoteBackend.self, MockNoteBackend.self)` binds the app's
// request-scoped `NoteBackend` slot to a per-scope-entry mock the test supplies. One `TestingKey` = one
// variant; WireGen emits the variant's `_NoteTestBinds_mockBackendDoubles` struct + the doubles-threaded
// contributor-proxy facade over `NotesController`, and the generated keyed `.wiremvc(_:)` factory threads a
// supplied mock into request scope. `NoteBackend` is request-scoped, so no `@Scopable` cascade is needed.

/// A test-held mock recording every call, so the assertion can prove the *exact* supplied instance flowed
/// through the reconstructed request scope (reference identity via the recorded calls it mutates).
package final class MockNoteBackend: NoteBackend {
    private let calls = Mutex<[String]>([])

    package init() {}

    package func note(_ id: String) -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    package var recordedNotes: [String] { calls.withLock { $0 } }
}

enum NoteTestBinds {
    @BindType(NoteBackend.self, MockNoteBackend.self)
    static let mockBackend = TestingKey()
}
