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
takes four pieces, and they are worth seeing together. This example uses
[smockable](https://github.com/tachyonics/smockable) for the mock itself, which is where the
design of `@BindType` pays off — see below.

**The slot.** An ordinary binding the application already uses:

```swift
public protocol TodoRepository: Sendable {
    func all() async throws -> [Todo]
    func find(id: String) async throws -> Todo?
}
```

**The mock.** `@Smock` generates one from a protocol declaration — but it cannot annotate a
protocol declared in another module, which yours will be. The workaround is a *mirror* protocol
that inherits the real one and re-declares its requirements, so the generated mock conforms to
both: it satisfies the graph's slot, and it exposes smockable's expectation and verification
surface.

```swift
import Smockable

@Smock(accessLevel: .internal)
protocol MockableTodoRepository: TodoRepository {
    func all() async throws -> [Todo]
    func find(id: String) async throws -> Todo?
}

typealias TodoRepositoryMock = MockMockableTodoRepository
```

The typealias is not cosmetic: it gives `@BindType` a non-macro declaration to name.

**The variant.** A `TestingKey` carrying one `@BindType` per substituted slot — the first
argument names the slot (a type, or a `BindingKey` for a keyed one), the second the concrete mock
type bound in this graph:

```swift
import WireTesting

enum MockedBinds {
    @BindType(TodoRepository.self, TodoRepositoryMock.self)
    static let mocks = TestingKey()
}
```

**The test.** The suite names the key; each test builds its expectations, supplies the instance,
and verifies afterwards:

```swift
@Suite(.wiremvc(MockedBinds.mocks, .inProcess))
struct MockedRoutingTests {
    @Test func servesFromTheMock() async throws {
        var expectations = MockMockableTodoRepository.Expectations()
        when(expectations.all(), return: [Todo(id: "1", title: "Write docs")])
        let repository = MockMockableTodoRepository(expectations: expectations)

        try await withClient(supplying: TodosControllerDoubles(todoRepository: repository)) { todos in
            let listed = try await todos.all()
            #expect(listed.map(\.title) == ["Write docs"])
        }

        verify(repository, times: 1).all()
    }
}
```

The two halves check different things. The response proves the mock served the route, through the
real router, the real middleware and the real error tiers. The `verify` proves the **exact
instance the test holds** is the one the controller called — and `verify(repository, .never)`,
or a `.any` argument matcher, expresses the negative and the loose cases the same way.

### Why a generated mock fits at all

`@BindType` **references** the mock type rather than annotating it. That is what makes a
generated mock usable: you cannot put an attribute on a type a macro produced, and requiring one
would have forced a hand-written wrapper around every generated mock. Referencing costs nothing
and admits both.

The two constraints worth knowing before the compiler tells you:

- **The `@Smock` protocols need their own file**, apart from the `@BindType`s naming the
  generated mocks. A macro's arguments cannot see peer types another macro generates in the same
  file, so `@BindType(TodoRepository.self, TodoRepositoryMock.self)` resolves only across files.
- **The mirror protocol must re-declare the inherited requirements.** `@Smock` reads the
  declaration it is attached to, so an empty refinement generates an empty mock.

A hand-written fake works here too, and needs none of that — it is an ordinary type conforming to
the slot. Use one when there is nothing to verify and the fake is a few lines; reach for the
generated mock when the test's assertion is about *which calls happened*.

## Doubles are per controller

`withClient(supplying:)` takes a generated `<Controller>Doubles` value, and there is one type per
routed controller carrying only the slots **that** controller reaches. So a key can declare more
substitutions than any single test uses. Given a key binding both a repository and a session
manager, a request-scoped `/me` controller reaching both takes
`MeControllerDoubles(sessionManager:todoRepository:)`, while a `/todos` controller reaching only
the repository takes `TodosControllerDoubles(todoRepository:)` — and a route reaching neither
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
struct TodosController<Repository: TodoRepository> {
    @Inject let repository: Repository
}
```

It goes on the declaration rather than on the key, because whether a singleton is safe to rebuild
is a property of the type — a cache or a pool may not be. A generic controller marks cleanly this
way, where naming it from the key could not spell the specialisation. The mark is required only for consumers
on the path from a substituted slot to a scope root; the build plugin computes that path and
names each unmarked hop, so this is guided rather than guessed. A request-scoped binding needs
nothing, being rebuilt per request already.

The same machinery covers a middleware that injects a substituted slot. A controller-scope
`@Middleware` that `@Inject`s the same repository cannot hold the mock either — it is built once
at facade time — so it is re-emitted as a variant factory whose per-request `create` sources the
double. A test can therefore verify that the middleware and the handler called the *same*
instance, in the order they ran.

## Suites stay parallel

Doubles ride the request, correlated by an id the harness puts on it, so concurrent requests
carrying different mocks do not cross. That is a promise worth testing rather than assuming —
wire-mvc's own suite runs unserialised and includes a test that forces two differently-mocked
requests to be in flight simultaneously.
