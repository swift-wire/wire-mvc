import Synchronization
package import Wire
package import WireMVCBootstrapExample
package import WireTesting

// The test-graph variant for this suite: `@BindType(NoteBackend.self, MockNoteBackend.self)` binds the app's
// request-scoped `NoteBackend` slot to a per-scope-entry mock the test supplies. One `TestingKey` = one
// variant; WireGen emits the variant's `_NoteTestBinds_mockBackendDoubles` struct + the doubles-threaded
// contributor-proxy facade over `NotesController`, and the generated keyed `.wiremvc(_:)` factory threads a
// supplied mock into request scope. `NoteBackend` is request-scoped, so no `@Scopable` cascade is needed.

/// A test-held mock recording every call, so the assertion can prove the *exact* supplied instance flowed
/// through the reconstructed request scope (reference identity via the recorded calls it mutates). `onNote`
/// is an optional async hook run *inside* the lookup — a test uses it to park the request on a barrier, so
/// two differently-mocked requests can be proven in-flight simultaneously before either returns.
package final class MockNoteBackend: NoteBackend {
    private let calls = Mutex<[String]>([])
    private let onNote: (@Sendable () async -> Void)?

    package init(onNote: (@Sendable () async -> Void)? = nil) {
        self.onNote = onNote
    }

    package func note(_ id: String) async -> String {
        calls.withLock { $0.append(id) }
        await onNote?()
        return "mock:\(id)"
    }

    package var recordedNotes: [String] { calls.withLock { $0 } }
}

/// Mock for the KEYED slot, supplied via `@BindType(PrefsKeys.primary, MockPrefsBackend.self)`.
package final class MockPrefsBackend: PrefsBackend {
    private let calls = Mutex<[String]>([])
    package init() {}
    package func pref(_ id: String) async -> String {
        calls.withLock { $0.append(id) }
        return "mock-pref:\(id)"
    }
    package var recordedPrefs: [String] { calls.withLock { $0 } }
}

enum NoteTestBinds {
    // One `@BindType` slot (`NoteBackend`) reached two ways: directly by `NotesController`, and through the
    // `@TestScopable`'d `AccountRegistry` (an app `@Singleton` reading the backend at `init`) by
    // `AccountController`. `@TestScopable` (on `AccountRegistry`'s declaration) acknowledges lifting that
    // singleton into the request scope so its init sees the double.
    @BindType(NoteBackend.self, MockNoteBackend.self)
    @BindType(PrefsKeys.primary, MockPrefsBackend.self)  // STEP 0: the keyed slot form
    static let mockBackend = TestingKey()
}
