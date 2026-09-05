# Testing an app

Serving the real application in a suite, and substituting the parts a test should not reach.

## Overview

A WireMVC test does not construct controllers by hand. It stands the application up — the same
composition root, the same graph, the same routes, the same middleware — and talks to it over a
client. What a hand-constructed controller test silently skips (a parameter that fails to decode,
a middleware that rejects, the fallback that answers) is all in the path.

```swift
@Suite(.wiremvc(.swiftHttpServer))
struct HelloTests {
    @Test func servesTheRoute() async throws {
        try await withClient(for: HelloControllerClient.self) { hello in
            let greeting = try await hello.hello(name: "Alice")
            #expect(greeting.message == "Hello, Alice!")
        }
    }
}
```

The trait stands the app's test server up for the suite and tears it down afterwards. The
argument is the mode: `.inProcess` for an in-process transport, `.swiftHttpServer` for a live
server on an ephemeral loopback port — harness-owned, so the app's own `createServer()` is not
involved — or `.server(_:)` for one you configure. The live mode needs the `NIOHTTPServer` trait;
see <doc:PackageTraits>.

## Two clients

`withClient(for: <Controller>Client.self)` hands you a **typed** client generated for that
controller: one method per route, with the route's own parameters and return type. A route that
throws surfaces as a `WireMVCRouteError` carrying the status the error tiers produced, so
asserting on error mapping is ordinary.

```swift
let error = try await #require(throws: WireMVCRouteError.self) { try await hello.tenant() }
#expect(error.status == .badRequest)
```

`withClient` with no argument hands you the untyped one — `client.get("/no/such/route")`,
returning a response with `status` and `bodyText`. Use it for what has no typed route to name: an
unmatched path hitting the fallback, a wrong method, a hand-built request.

## Substituting a dependency

Standing the real graph up is the point, but a test usually should not reach the real backend.
swift-wire's test-graph variants express that, and WireMVC threads them through the request. It
takes four pieces, and they are worth seeing together.

**The slot.** An ordinary binding the application uses — here a request-scoped backend the
controller injects:

```swift
public protocol NoteBackend: Sendable {
    func note(_ id: String) async -> String
}
```

**The mock.** A plain type conforming to it, holding whatever the test wants to inspect
afterwards. Nothing about it is WireMVC-specific, and it needs no annotation — the variant
*references* the type rather than marking it, so a generated mock fits here unchanged:

```swift
package final class MockNoteBackend: NoteBackend {
    private let calls = Mutex<[String]>([])

    package func note(_ id: String) async -> String {
        calls.withLock { $0.append(id) }
        return "mock:\(id)"
    }

    package var recordedNotes: [String] { calls.withLock { $0 } }
}
```

**The variant.** A `TestingKey` carrying one `@BindType` per substituted slot. The first argument
names the slot — a type, or a `BindingKey` for a keyed one — and the second the concrete mock
type it binds to in this graph:

```swift
import WireTesting

enum NoteTestBinds {
    @BindType(NoteBackend.self, MockNoteBackend.self)
    @BindType(PrefsKeys.primary, MockPrefsBackend.self)   // the keyed-slot form
    static let mockBackend = TestingKey()
}
```

**The test.** The suite names the key, and each test supplies the instance:

```swift
@Suite(.wiremvc(NoteTestBinds.mockBackend, .swiftHttpServer))
struct BindTests {
    @Test func suppliedMockIsObservedOverHTTP() async throws {
        let mock = MockNoteBackend()

        try await withClient(supplying: NotesControllerDoubles(noteBackend: mock)) { notes in
            let note = try await notes.note(id: "x")
            #expect(note.value == "stamped:mock:x")
        }

        #expect(mock.recordedNotes == ["x"])
    }
}
```

Two assertions, and they check different things. The response proves the mock served the route —
and `stamped:` in front of it proves the app's real singleton still ran, so the substitution
replaced one binding rather than the graph around it. The recorded call proves the **exact
instance the test holds** is the one that served, which is what makes `verify`-style assertions
possible at all.

## Doubles are per controller

`withClient(supplying:)` takes a generated `<Controller>Doubles` value, and there is one type per
routed controller carrying only the slots **that** controller reaches. So a key can declare more
substitutions than any single test uses: a test hitting `/notes/{id}` supplies the note backend
alone, one hitting `/prefs/{id}` supplies the keyed prefs mock alone, and one hitting `/ping`
supplies nothing.

A route that reaches a substituted slot with no double supplied is an explicit `500`, not a
silent fall back to the production binding. Filling the hole is the test's job, and a test that
forgets should fail rather than quietly exercise the real backend.

## When a singleton is in the way

A `@Singleton` captures its dependencies once, at bootstrap, so a per-request double cannot reach
one — it was built before the request existed. Marking the type `@TestScopable` acknowledges that
the variant may rebuild it per request:

```swift
@TestScopable
@Singleton
final class AccountRegistry {
    @Inject init(backend: any NoteBackend) { … }   // reads its dependency at init
}
```

It goes on the declaration rather than on the key, because whether a singleton is safe to rebuild
is a property of the type — a cache or a pool may not be. The mark is required only for consumers
on the path from a substituted slot to a scope root; the build plugin computes that path and
names each unmarked hop, so this is guided rather than guessed. A request-scoped binding needs
nothing, being rebuilt per request already.

The same machinery covers a middleware that injects a substituted slot: it cannot hold the mock
either, so it is re-emitted as a variant factory sourcing the double per request. A test can
therefore assert that the middleware and the handler touched the *same* instance, in order.

## Suites stay parallel

Doubles ride the request, correlated by an id the harness puts on it, so concurrent requests
carrying different mocks do not cross. That is a promise worth testing rather than assuming —
wire-mvc's own suite runs unserialised and includes a test that forces two differently-mocked
requests to be in flight simultaneously.
