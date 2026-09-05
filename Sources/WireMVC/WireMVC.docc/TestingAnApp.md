# Testing an app

Serving the real application in a suite, and substituting the parts a test should not reach.

## Overview

A WireMVC test does not construct controllers by hand. It stands the application up — the same
composition root, the same graph, the same routes — and talks to it over a client. The suite
trait is the entry point:

```swift
@Suite(.wiremvc())
struct TodosTests {
    @Test func findsATodo() async throws {
        let response = try await client.get("/todos/1")
        #expect(response.status == .ok)
    }
}
```

The trait stands up the app's test server for the suite and tears it down after. What "server"
means depends on the mode: an in-process transport by default, or a live NIO server when the
`NIOHTTPServer` trait is enabled — see <doc:PackageTraits>.

## Substituting a dependency

Standing up the real graph is the point, but a test usually should not reach the real backend.
swift-wire's test-graph variants are how that is expressed, and WireMVC threads them through the
request:

```swift
import WireTesting

enum TodoTests {
    @BindType(TodoBackend.self, MockTodoBackend.self)
    static let mocked = TestingKey()
}

@Suite(.wiremvc(TodoTests.mocked))
struct MockedTodosTests { … }
```

The key selects a **variant app graph** — the same application with that slot bound to the mock
type. The instance is supplied per request rather than at bootstrap, so the test holds the double
it created and can assert against it afterwards.

An app-scoped consumer that has to be rebuilt per request to see the double carries
`@TestScopable` on its own declaration. The build plugin computes the path and names each hop
that needs marking, so this is guided rather than guessed. swift-wire's testing article covers
the cascade and why it is inherent.

## Correlating a double with a request

Because doubles ride the request, something has to say *which* request. WireMVC correlates them
with an id carried on the request, and the harness maintains the store keyed by it — which is
what lets a suite run its tests concurrently against one server without their doubles colliding.

## The client

`TestClient` issues requests and returns a `TestResponse` with the status, header fields and
body. A typed route client is available for the cases where you would rather not restate the
path and the codec at each call site.

## What this gets you

A mocked suite runs with no real backend, against the routes the application actually serves,
through the middleware it actually folds, with the error mappings it actually declares. The
things a hand-constructed controller test silently skips — a binding that fails to decode, a
middleware that rejects, a fallback that answers — are all in the path.
