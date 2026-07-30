# Controller-scoped testing — a design note

> **Status:** idea, for revisiting after Phase 5 of `../TestingArchitecture.md`. Nothing here is built.
> Related: swift-wire's `PendingIssues/11` (one `TestingKey` per target), which this would partly obviate.

Most WireMVC testing happens at the **controller** level: a suite exercises one controller's routes with its
dependencies mocked. But neither half of the harness is scoped to a controller — the doubles you supply are
scoped to the *key*, and the client you drive is scoped to *nothing*. This note proposes making the
controller the unit of both.

## The two problems

**Doubles are over-specified.** `withBindValues` takes every `@BindType` slot the `TestingKey` declares,
all required, on every request — even for a route that consumes none of them. In `WireMVCBootstrapExample`,
`/ping` injects nothing mocked, yet a request to it must still be wrapped in
`withBindValues(noteBackend:prefsBackendKeyedPrefsKeysPrimary:)`; `mockIgnoringRouteWithoutDoublesIs500`
asserts that as the decided behaviour. The granularity is wrong: what a request needs is what *its route's
scope* consumes, not what the key happens to declare.

**The client is stringly-typed.** `TestClient.current.get("/notes/x")` re-states a path the codegen already
knows, decodes a response type the codegen already knows, and can't be checked against either. Renaming a
route, changing a `@Path` parameter's type, or altering a `@JSONResponse` body silently breaks tests at
runtime instead of at compile time — in a framework whose whole premise is that route shape is derived, not
hand-maintained.

## The shape

One generated entry point per controller, supplying exactly that controller's doubles and yielding a client
for exactly its routes:

```swift
try await withBindValues(NotesControllerDoubles(noteBackend: mock)) { notes in
    let note = try await notes.fetchNote(id: "x")     // GET /notes/{id} -> Note
    #expect(note.value == "stamped:mock:x")
}
```

- The **doubles type** carries exactly the mocks `NotesController`'s request scope consumes, and its
  memberwise init makes them all required — so forgetting one is a compile error, and unrelated mocks are
  never mentioned.
- The **client** exposes one method per route on that controller, named from the handler, with `@Path` /
  `@Query` / `@Header` / `@JSONBody` as parameters and the `@JSONResponse` type as the return.

(A flatter spelling, `withNotesControllerBindValues(noteBackend: mock)`, reads better but costs more to
build — see "Could the consumed set be a naming convention instead?" below.)

The symmetry is the point: *the doubles you must supply and the routes you can call both come from the same
controller.* It also composes well with `.inProcess` — a typed client over an in-memory transport is about as
tight as a controller test gets.

## Where the pieces come from

**The typed client is fully derivable in wire-mvc today.** `WireMVCCodegen` already reads everything a route
signature needs, because it has to in order to emit the witness: the verb and path template (`@Get("/{id}")`
under the `@Controller("/notes")` prefix), each `@Path`/`@Query`/`@Header` binding with its Swift type, the
`@JSONBody` parameter type, the handler's return type, and the `@JSONResponse`/`@ResponseStatus` mode. It
also knows the `@ErrorResponse` tiers, so it knows which statuses a route is *declared* to fail with — enough
to give a typed method a generated error type rather than a bare status code. No swift-wire involvement.

**The consumed-doubles set is not derivable in wire-mvc** — though, as the next section argues, it may not
need to be. It is transitive: `CartController` reaches
`NoteBackend` only through `CartService → AccountRegistry`, whose `init` reads it
(`level2TransitiveRouteThreadsMockWithNoMark` covers exactly this). wire-mvc parses controllers, not the
graph, so it cannot compute that closure. swift-wire can, and already does — it computes doubles fields
per scope and then *merges* them into one variant-wide set (`mergedDoublesFields` in
`WireGen/TestingVariants.swift`). The seedless reconstructions already carry theirs individually
(`reconstruction.doublesFields`); the seed-scoped path would need its accumulation kept un-merged. Bounded,
but it starts in swift-wire.

## Could the consumed set be a naming convention instead?

Largely yes — more than the first draft of this note allowed. The distinction that matters is not *what
wire-mvc knows* but *who emits the typed surface*.

**wire-mvc does not compute graph facts today either.** It reads the `@BindType` attributes on the
`TestingKey` and replicates WireGen's `identifierName(forType:key:)` to derive each doubles field's name,
then assumes swift-wire's `_<Key>Doubles` has exactly those fields. Nothing verifies that at the wire-mvc
end; what makes it sound is that a `@BindType` matching no binding is a **build error on swift-wire's side**
(`unmatchedBindTypeDiagnostic`), so the two sets agree or the build fails. Per-controller doubles would be
the same bargain, just with a different set — so "wire-mvc would have to trust swift-wire" is not the
objection. It already does.

**The real asymmetry is what wire-mvc must derive in order to write a parameter list.** Today that list is a
pure function of syntax wire-mvc can see: the `@BindType` attributes sit on the key, in the parsed sources.
Per controller, no syntax anywhere states which slots a controller reaches — `CartController` declares
`CartService`, and the mocked slot appears two hops later in `AccountRegistry.init`. Deriving that needs the
*resolved* graph: `@Singleton(as:)` aliasing, keyed bindings, `@Provides` functions, factories, the
`@Scopable` lift, existential promotion. Replicating a naming rule is one function; replicating reachability
over the resolved graph is replicating the DI engine.

**But wire-mvc only needs the list if wire-mvc emits the typed entry point.** If swift-wire emits a
per-subject doubles struct — `NotesControllerDoubles` with a memberwise init over exactly the fields that
subject's scope consumes — then the memberwise init *is* the typed, complete, compile-checked parameter
list, and wire-mvc needs to know only the type's **name**. Which is precisely the kind of blind agreement
that already works. The call site becomes:

```swift
try await withBindValues(NotesControllerDoubles(noteBackend: mock)) { notes in … }
```

with wire-mvc emitting a generic pass-through (it already has one — `WireMVCTesting.withBindValues(_:in:_:)`
is generic over the doubles type) and a per-subject `TestBindStore<NotesControllerDoubles>` named by
convention. The dispatch knows which subject it is, because it is emitted on that subject's variant witness.

So the choice is about ergonomics, not capability:

| | Call site | What wire-mvc must derive |
|---|---|---|
| swift-wire emits the struct | `withBindValues(NotesControllerDoubles(noteBackend: mock))` | the type name only — convention |
| wire-mvc emits the wrapper | `withNotesControllerBindValues(noteBackend: mock)` | the full field list — needs the graph |

The first is the cheaper build and keeps the tools' split clean: swift-wire owns anything graph-derived,
wire-mvc owns anything route-derived. It is also the one that composes with the typed client, since the
client is route-derived and wire-mvc can emit it either way. Worth trying first, and only reaching for the
nicer spelling if the generated type name proves annoying in practice.

Either way swift-wire has to keep its per-subject sets rather than merging them (`mergedDoublesFields` in
`WireGen/TestingVariants.swift`); the seedless reconstructions already carry theirs individually
(`reconstruction.doublesFields`), the seed-scoped path does not.

**The third option stands apart:** don't scope the doubles at all — one union struct with optional fields,
validated per route at runtime. Simplest to build, but it trades away the compile-time guarantee this idea
exists to keep. Recorded as option 1 in swift-wire's `PendingIssues/11`.

## Open questions

- **Non-2xx responses.** A method returning `Note` has to decide what a 400 or a middleware short-circuit
  means. Tests assert on those constantly (`globalErrorTierMapsToBadRequest`, `notFoundFallbackServes`,
  `missingDoublesIsExplicit500`). Probably: throw a generated per-route error carrying status + body, with
  the `@ErrorResponse` tiers naming the expected cases — and keep the raw client reachable for everything
  else.
- **Routes with no typed shape.** `@RawRoute` (streaming, SSE, the `@NotFound` fallback) has no derivable
  signature. Those stay on the raw client.
- **Cross-controller flows.** The Docker CRUD suite creates through one controller and reads through
  another. A per-controller client can't express that alone, so `TestClient.current` must remain
  first-class rather than becoming a fallback nobody maintains.
- **Middleware-consumed doubles.** A route-scoped `@Middleware` factory can itself inject a mocked slot
  (Phase B threads `create(doubles:)`). The per-controller set must include those, not just what the handler
  reaches — worth confirming against `appScopedTestScopableRouteServesMockSeedlessly`, where the middleware
  and the handler touch the same supplied instance.
- **Keyless suites.** Bind values only exist under a keyed suite; a typed client arguably shouldn't. Or it
  could be offered keylessly too, as pure route-shape sugar over the real graph.

## Why this weakens the case for multi-key

A common reason to want two `TestingKey`s in one target is "these two suites need different mock sets".
Per-controller bind values give that without a second variant graph — each suite supplies only what its
controller consumes. What genuinely remains for multi-key is different *graph substitutions*: the same slot
bound to two different concrete mock types where the consumer is generic over it (the opaque-injection lift).
That is narrow enough that a second test target is a fair answer, which is why `PendingIssues/11` is deferred
rather than scheduled.
