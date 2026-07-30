# Controller-scoped testing — a design note

> **Status:** the **typed client half is built** (2026-07-30) — see "What was built" below. The
> per-controller *bind values* half is not. Originally an idea note, written for revisiting after Phase 5 of
> `../TestingArchitecture.md`. Related: swift-wire's `PendingIssues/11` (one `TestingKey` per target), which
> this would partly obviate.
>
> **Corrected 2026-07-31.** The first draft misread how swift-wire carries its doubles sets, and the three
> claims that followed from it are fixed below: the accumulation it asked to keep un-merged was already
> un-merged, per-*scope* is not per-*controller* (a seed scope is shared by every controller on that seed),
> and the middleware question is now answered rather than open — swift-wire folds a mock-consuming middleware
> factory's fields into the subject's set on both paths (swift-wire #239 did the seed-scoped half).

Most WireMVC testing happens at the **controller** level: a suite exercises one controller's routes with its
dependencies mocked. But neither half of the harness is scoped to a controller — the doubles you supply are
scoped to the *key*, and the client you drive is scoped to *nothing*. This note proposes making the
controller the unit of both.

## What was built

The typed client, which needed nothing from swift-wire:

- `WireMVCTesting/TypedRouteClient.swift` — `WireMVCRouteError` (status, body, and the route that produced
  it) and `TestClient.routeResponse(...)`, which owns path templating, the query string, and the non-2xx
  rule. Percent-encoding uses RFC 3986's unreserved set, not Foundation's `.urlQueryAllowed`: that is a
  whole-query set which leaves `/`, `&`, `=` and `+` legal, so a path parameter containing one would have
  reshaped the URL.
- `WireMVCCodegen/ControllerClientGeneration.swift` — emits `struct <Name>Client` plus a module-scope
  `var <name>` per controller, for a test consumer only. A controller with no verb-annotated route emits no
  client.
- **`@RawRoute` gets a shim, not nothing.** Its parameters are all *roles* and it writes its own response, so
  neither side is typeable — but the request line still is. The shim takes one `String` per `{placeholder}`
  in the path template (a raw route declares no bindings, so the template is the only source), plus a
  pass-through `headers:`, and returns the untyped `TestResponse`. It applies no status rule: a raw route may
  answer a non-2xx or stream a `206` by design. So a raw route stops being a stringly-typed path in the test
  even though its payload stays untyped. Only `@NotFound` gets nothing — an unmatched path is not
  addressable as a route.
- `WireMVCCodegen/RouteShape.swift` — the verb/path/attribute rules the witness and the client both read, so
  they cannot drift on route shape.

**The decision that shaped it:** a typed method returns the decoded response and *throws* `WireMVCRouteError`
on a non-2xx. Error assertions are first-class — in the examples' mocked suite, one of the two tests asserts
a 401 — so the alternative (a typed envelope) would have made every happy-path test unwrap an optional to
serve the failure case. Instead the happy path carries no status assertion and no decode, and a failure reads
`#require(throws: WireMVCRouteError.self)` then asserts `error.status`.

What has **no** generated surface at all: the `@NotFound` fallback and the Bootstrap's introspection mount —
neither is addressable as a controller route. `TestClient`'s untyped verbs remain first-class for those, and
for any request a test wants to malform deliberately.

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
graph, so it cannot compute that closure. swift-wire can, and already does.

**What swift-wire already carries, precisely.** The first draft said the seed-scoped accumulation would need
to be "kept un-merged". It already is: `accumulateVariantScopes` computes `scopeDoublesFields` per seed
partition and stores it on the scope (`WireGen/TestingVariants.swift`, the `scopeDoublesFields` local and the
`doublesFields:` it passes to `orchestrateVariantScope`). `mergedDoublesFields` is built *alongside* it, purely
to render the one variant-wide `_<Key>Doubles`. Nothing needs un-merging.

**But per-scope is the wrong granularity**, which is the real gap. A seed scope is partitioned by *seed type*,
not by subject: every `@Scoped(seed: HTTPRequest.self)` controller in a module shares one scope, and so shares
one `doublesFields`. Handing `NotesControllerDoubles` that set would still over-specify — just one level down
from the key-wide set this note exists to replace.

**The primitive that closes the gap already ships too.** `reachableBindings(from:in:)` in
`WireGenCore/ScopeEntryEmission.swift` is a BFS from the routed subject over the scope's resolved edges, added
in M5.4.6 to prune construction and teardown to the controller actually being served. Per-controller doubles is
that reachable set intersected with the scope's doubles-sourced bindings. The mapping holds up: a substituted
binding keeps its identity (`applyBindTypeSubstitutions` rewrites the source, not the identity) and
`doublesFieldName(for:)` recovers its field, so identity → field needs no change to `DoublesField`.

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
subject reaches (not its whole scope's) — then the memberwise init *is* the typed, complete, compile-checked parameter
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

Either way swift-wire has to expose a per-subject set. What that costs differs by path, and neither is the
"stop merging" the first draft assumed:

| Subject | Per-subject set | Work |
|---|---|---|
| Seedless (`@Singleton` + `@TestScopable`) | `reconstruction.doublesFields` | none — already per-subject, middleware included |
| Seed-scoped (`@Scoped(seed:)`) | `scope.doublesFields` ∩ `reachableBindings(from: subject)`, plus that proxy's factory-transform fields | the intersection, over machinery that already ships |

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
- ~~**Middleware-consumed doubles.**~~ **Answered.** A route-scoped `@Middleware` factory that injects a
  mocked slot is folded into the *subject's* set by swift-wire on both paths, so a BFS from the controller
  root is not the whole story — but the missing piece is already attributed per subject, not something
  wire-mvc has to reconstruct. Seedless: `SeedlessReconstruction.doublesFields` is
  `built.doublesFields + factoryTransforms.flatMap { $0.doublesFields }`, so the factory's fields ride along
  (`appScopedTestScopableRouteServesMockSeedlessly` is that case). Seed-scoped: the same transform now runs
  for contributor proxies, keyed by proxy type name (swift-wire #239 — its
  `seedScopedFactoryTransforms`), covered by `seedScopedRouteWithMockConsumingMiddlewareServesMock`. So a
  per-controller set is the reachable-from-subject intersection **union** that proxy's factory-transform
  fields. Note those fields currently land only in the variant-wide struct; per-controller doubles is what
  would consume them per subject.
- **Keyless suites.** Bind values only exist under a keyed suite; a typed client arguably shouldn't. Or it
  could be offered keylessly too, as pure route-shape sugar over the real graph.

## Where to start

The pieces this would touch, so a fresh reading doesn't have to rediscover them.

**swift-wire — the consumed-doubles set (the part wire-mvc can't derive):**
- `WireGenCore/ScopeEntryEmission.swift` — `reachableBindings(from:in:)`, the per-root BFS over the scope's
  edges. This is the primitive; a seed-scoped subject's set is its result intersected with the scope's
  doubles-sourced bindings. It is `private` today, so exposing it is part of the change.
- `WireGen/TestingVariants.swift` — the per-scope `scopeDoublesFields` is already stored on each scope;
  `mergedDoublesFields` is the separate variant-wide render. Neither needs un-merging.
- `WireGen/TestingVariantSeedlessRoots.swift` — `SeedlessReconstruction.doublesFields` is already the
  per-subject set for a seedless root, factory fields included.
- `WireGen/TestingVariantContributorProxies.swift` — `seedScopedFactoryTransforms` returns the mock-consuming
  factory transforms keyed by proxy type name; their `doublesFields` are the middleware half of a seed-scoped
  subject's set.
- `WireGenCore/TestingGraph.swift` — `renderDoublesStruct(typeName:fields:)` emits the struct (fields sorted
  by name, memberwise init); `DoublesField` is `(name, mockType)`. A per-subject struct is the same renderer
  over a narrower field list.

**wire-mvc — the typed client (fully derivable here):**
- `WireMVCCodegen/ControllerDeclaration.swift` + `RouteContributorGeneration.swift`'s `ControllerFinder` —
  the `@Controller` decl and its path prefix.
- `WireMVCCodegen/RouteCodegen.swift` — everything a typed signature needs, because the witness needs it:
  verb + path template, `@Path`/`@Query`/`@Header`/`@JSONBody` bindings with types, return type,
  `@JSONResponse`/`@ResponseStatus` mode, and the `@ErrorResponse` tiers (which give the declared failure
  statuses).
- `WireMVCCodegen/KeyedHarnessGeneration.swift` — `renderKeyedHarnessStatics` emits today's per-key
  `TestBindStore` + `withBindValues`; this is what a per-controller entry point replaces.
- `WireMVCCodegen/RouteCodegen.swift`'s `scopeEntryPreamble` — where a request's doubles are correlated off
  the `X-WireMVC-Test-Binds` header and where the missing-doubles 500 is written. A per-route check lands
  here.
- `WireMVCTesting/TestBindStore.swift` — `WireMVCTesting.withBindValues(_:in:_:)` is already generic over the
  doubles type, so it needs no change if swift-wire emits the struct.

**Sequencing note.** The typed client needed nothing from swift-wire, so it landed first and independently of
the doubles question (#55–#57) — it was also the half that pays off in every suite, keyed or not. What remains
is the doubles half, and it starts in swift-wire: exposing a per-subject set (the table above), then a
per-subject `renderDoublesStruct` over it. wire-mvc's side is then only the type name, by convention.

## Why this weakens the case for multi-key

A common reason to want two `TestingKey`s in one target is "these two suites need different mock sets".
Per-controller bind values give that without a second variant graph — each suite supplies only what its
controller consumes. What genuinely remains for multi-key is different *graph substitutions*: the same slot
bound to two different concrete mock types where the consumer is generic over it (the opaque-injection lift).
That is narrow enough that a second test target is a fair answer, which is why `PendingIssues/11` is deferred
rather than scheduled.
