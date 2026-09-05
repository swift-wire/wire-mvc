# WireMVC testing harness — design note (M6a)

> **Status:** design record for the WireMVC HTTP test harness. It sits **on top of** swift-wire's
> scope-agnostic testing primitives ([TestingModel.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/TestingModel.md) — `@BindType` / `@Scopable`
> / `TestingKey` / the seed-threaded cascade).
>
> **All of it is built.** `withTestServer`, the `@Suite(.wiremvc(…))` trait, the `TestBindStore` +
> `CorrelationID` channel and `TestClient` all shipped in M6a. **One name changed in the building:**
> the doubles-supplying entry point is `withClient`, not the `withBindValues` this note proposes.
> Read as a design record rather than as a plan.

## The problem

Testing a `@WireMVCBootstrap` app: build the wired app without serving, drive it over real HTTP, tear it down — with two more axes on top: **server lifecycle** (per-test vs per-suite) and **supplying test doubles** to the graph's scope-entries over the HTTP boundary.

## Already built (context)

- **The generated build-and-serve** — `@WireMVCBootstrap` generates, in any consumer that depends on `WireMVCTesting`, a build that inlines the wired app, serves on an ephemeral port in a task group, hands over a typed `TestClient`, and cancels on exit. The opaque `~Copyable` handler is passed to a generic `WireMVCTesting` helper. Deliverable 1 surfaced this as a per-test `withTestServer { client in }`; the decision below is to make the **suite trait** the one public server API and reuse this build-and-serve as its mechanism (see *One server API*).
- **Test target as its own Wire consumer** (spike-27) — the test target carries its own build plugin and regenerates the graph from the app's sources plus its `TestingKey`, so substitutions and scope-lifts land in the test graph only.

## The layering

The **swift-wire primitives** ([TestingModel.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/TestingModel.md)) define *what* the test graph looks like — `@BindType` substitutes a slot's type, `@Scopable` lifts an app-scoped hop into the seeded scope, `TestingKey` names the config, and a `@BindType` binding's instance rides the scope's **seed**. All scope-agnostic.

This harness is *how* a WireMVC app under real HTTP feeds those primitives: it runs the server once per suite, and per request carries the test's double instances across the HTTP boundary and hands them in as the scope's test-double seed.

## Thread 1 — the suite-level server

Per-test start/stop is the outlier; suite/session-scoped is the norm (ASP.NET `IClassFixture<WebApplicationFactory>`, Spring's cached `ApplicationContext`, pytest `scope="session"`, and our own swift-local-containers `@Containers` + `containerTrait`).

A `WireMVCTesting` **suite trait**, mirroring `containerTrait` — a swift-testing `SuiteTrait` that builds + serves the wired app **once** at suite entry (the graph selected by a `TestingKey`), exposes a shared client, and cancels at suite exit. The server builds the test graph once; per-test doubles vary through the channel below.

**One server API.** The suite trait is the *only* public way to stand up a test server — `@Suite(.wiremvc(key))`, and nothing else to choose. The generated build-and-serve from deliverable 1 becomes its internal mechanism rather than a co-equal `withTestServer` a user also picks between (two public server APIs read as confusing). If a genuinely isolated per-test server is ever needed, it's added deliberately then.

**Caveat (inherited from shared containers):** swift-testing runs tests in parallel, so a shared server needs the *backend* data isolated per test, or the suite goes `.serialized`.

## Thread 2 — the double-supply channel

The `TestingKey`'s `@BindType`s fix the double *types* at build time; the harness supplies the *instances* per test, over one channel: a thread-safe in-process **store** keyed by a **correlation id** carried on an agreed request header.

**Why a store + header:** the test drives the server over **real HTTP** (the `.live` model — services need the real serve path; an in-memory handler-invocation model would let the test inject per-scope state directly, but loses services). Over real HTTP the only per-request channel is the request itself. The store is **in-process shared** (test and server are one process), so the header carries only the correlation id, never the doubles.

```swift
@Suite(.wiremvc(MyTests.testSetup))                   // suite server, test graph built once
struct TodoTests {
    @Test func createsTodo() async throws {
        let repo = MockBackendRepository()                          // generated; test holds it
        try await withBindValues(someBackendRepository: repo) {     // mint id · store the double · set task-local
            _ = try await TestClient.current.post("/todos", json: NewTodo("milk"))
            #expect(repo.saved == ["milk"])                         // inspect afterward
        }                                                           // defer: remove the id's doubles
    }
}
```

- **`withBindValues(...) { }`** mints a correlation id, registers the doubles in the store under it, sets a task-local carrying the id, runs the body, and removes them on exit (`defer` — survives throws/cancellation; a crashed *process* just drops the whole store). Its parameters are named + typed from the `TestingKey`'s `@BindType` slots (`some BackendRepository` → `someBackendRepository`, typed `MockBackendRepository`).
- **`TestClient.current`** reads the task-local id and stamps the agreed header (e.g. `X-WireMVC-Test-Binds`) on every request inside the closure.
- **The request handler**, per request, reads the header, pulls that request's doubles from the store, and enters the scope with `(HTTPRequest, doubles)` — feeding swift-wire's seed-threaded double channel. For a `@Scopable`d singleton on the cascade, the scope-entry reconstructs it per request so the double reaches it (including its `init`).
- **Parallel isolation is free:** distinct closures → distinct ids → distinct store slots → each test's requests route to its own doubles.

## How the pieces compose

| Tool | Lifecycle | Double | Handle? | Scope |
|---|---|---|---|---|
| suite trait `@Suite(.wiremvc(key))` | per-suite server | — | — | — |
| `@Replaces` | compile-time, whole test target | fake *type* Wire builds | no | its own slot |
| `@BindType` + `withBindValues` | test graph + per-test instance | concrete type + held instance | yes (inspect) | any, via the doubles-seed |

Default path: the suite trait + `withBindValues` per test; `@Replaces` for a hand-written fake with no handle needed.

## Decisions (harness)

- **Header** — `X-WireMVC-Test-Binds`, never emitted in production.
- **Suite trait spelling** — `@Suite(.wiremvc(key))`.
- **One server API** — the suite trait only; the generated build-and-serve is its mechanism, not a co-equal public `withTestServer`.
- **Doubles are per-testing-id only** — no suite-wide default layer; every double comes through a per-test `withBindValues`. An integration test that mocks nothing just runs against the real test graph.
- **Missing double at request time → explicit 500.** A `@BindType`d slot reached with no double in the store for the request's id is an explicit 500 with a clear message (the HTTP surfacing of swift-wire's "missing instance → error" — [TestingModel.md](https://github.com/swift-wire/swift-wire/blob/main/Documentation/Notes/TestingModel.md)).

## Prior art

- **Suite server:** ASP.NET `IClassFixture<WebApplicationFactory>`, Spring `ApplicationContext` caching, pytest session fixtures, swift-local-containers `containerTrait`.
- **Correlation-id request store:** standard distributed-tracing / request-context propagation — reused here to carry doubles across the HTTP boundary.

---

<sub>Milestone shorthand used in this note (M1, M5.4, M7b…) is defined in ROADMAP.md; outstanding gaps are indexed in KnownGaps.md.</sub>
