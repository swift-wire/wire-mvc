# WireMVC middleware & the raw handler — M5.2 / M5.3 design record

> **Status:** the settled design for M5.2 (the raw escape-hatch handler) and M5.3
> (middleware). Extends [WireMVCDesign.md](WireMVCDesign.md) (the M5.0 record) and refines the
> M5.2/M5.3 sections of M5_PLAN.md. Proven substrate:
> `spike-12` (proposal-native
> routing), `spike-13`
> (the `ServerTransport` bridge), `spike-14`
> (streaming), and `spike-15`
> (the fold + capability forwarding). The middleware fold is **witness-local concrete** codegen over
> the proposal's `Middleware`/`MiddlewareBuilder`, resting on generic `@Provides` factories; spike-15
> corrected an earlier draft that expected a `BuilderKey` *opaque* fold (not expressible — see
> *What this rests on*).

## The model in one paragraph

Every handler — typed or raw — is the **terminal of a middleware chain that projects attributes
off the chain's final box**. Middleware transform the box (`Input → NextInput`); the terminal
reads what it needs out of the final box. `@Path`/`@Query`/`@JSONBody`/`@Header` are *annotated
sub-part* projections; `@JSONResponse`/`@ResponseStatus` write the response via the box's sender;
a raw handler is the *type-identified whole-slot* projection of the reader/sender plus any
capability the chain added. So typed and raw are one mechanism differing only in **which**
attributes they bind, and "type-transforming middleware ⇒ compile error" falls out of the
terminal passing the projected values into the handler's typed parameters — nothing asserts it,
the compiler enforces it.

## Short-circuit & the box shape (Model B) — a *consequence* of the middleware shape

The single most load-bearing fact about the whole middleware model is that it is **entailed by the
proposal's `Middleware.intercept<Return>(input:, next:) -> Return` signature**, not chosen against
HTTP-middleware precedent. The entailment (each step forced by the previous, proven with the compiler
in `spike-17`):

1. `Return` is universally generic — the middleware is compiled once for *all* `Return`, so it can't
   assume it's `Void` or construct one (a literal `return ()` fails: *cannot convert '()' to `Return`*).
2. ⟹ the only value of type `Return` reachable inside `intercept` is what `next` hands back.
3. ⟹ control flow must reach `next` to return at all → **every middleware runs the continuation**; there
   is no control-flow short-circuit (throwing is the only non-`next` exit, and that's the error channel).
4. ⟹ a middleware can't produce the response *as a value* → the response is only ever a **sender
   side-channel effect**.
5. ⟹ since the chain always completes, "who responded / stop handling" can't be control flow — it must
   be **state carried forward** in the box.

So "everyone always runs," "the decision is state in the box," and "a middleware that responds *writes*
via the sender" are one consequence with one cause. The upside is deliberate and matches Wire's
philosophy: participation is **structural, not positional** — an audit/metrics/tracing middleware can't
be silently skipped by an upstream gate. To get classic control-flow short-circuit (inner middleware
skipped) you would have to **change the middleware shape** (pin `Return` to a concrete/associated type
so a middleware can `return` one) — i.e. stop being the proposal's `Middleware`. Staying proposal-native
and this model are the same decision. (Prior art for data-flow short-circuit: Envoy filter-status
enums, railway-oriented / `Either`, http4s `OptionT` — the streaming-first stacks land here too.)

**The box is therefore two-state and `~Copyable`** (`Sources/WireMVC/Middleware.swift`). It is a struct
wrapping an *internal* `~Copyable` enum rather than being one: the cases hold the reader, sender and
response-header registry in `WireDisconnected` so they survive extraction as `sending`, and that wrapping
is a detail no middleware should see. The states are the point; the container is not.

```swift
public struct RequestResponseMiddlewareBox<RequestContext, Reader, ResponseSender>: ~Copyable where … {
    // internal — pending carries the registry, responded carries none, because nothing drains a box
    // whose response is already written
    enum Storage: ~Copyable { case pending(request:requestContext:reader:responseSender:responseHeaders:), responded(request:) }

    public var peekedRequest: HTTPRequest { … }          // borrowing, both states
    public var isPending: Bool { … }
    public static func pending(request:requestContext:reader:responseSender:responseHeaders:) -> Self
    public static func responded(request:) -> Self
    public consuming func responding(_ write: (consuming ResponseSender) async throws -> Void) async throws -> Self
    public consuming func respondingWith(_ outcome: consuming WireMVCOutcome) async throws -> Self   // drains
    public consuming func contributing(_: (inout ResponseHeaderRegistry) throws -> Void, then: (consuming Self) async throws -> R) async throws -> R
    public consuming func withPendingContents(_ handler: (HTTPRequest, consuming RequestContext, consuming sending Reader, consuming sending ResponseSender, consuming sending ResponseHeaderRegistry) async throws -> Void) async throws
    public consuming func withContents<R: ~Copyable>(pending: (…) async throws -> R, responded: (HTTPRequest) async throws -> R) async throws -> R
}
```

- A gate that rejects calls `input.responding { sender in … write 403 … }` — it *is* handling the
  request; the sender is consumed, the box becomes `.responded`, and it still calls `next`.
- The generated terminal calls `withPendingContents { … bind → handler → send … }`, which **no-ops when
  the box is `.responded`** — the handler is skipped, exactly once, without any control-flow branch in
  the chain.
- **Single-write and first-wins are enforced by the type**: `.responded` has no sender, so nothing can
  write again or override an earlier decision. No discipline required.
- **Sender is *not* reachable after a write** (the reason for the enum over a struct-with-optional-flag):
  a middleware that responds owns the write and can even stream it; afterward there is structurally no
  sender to hand out. What survives in `.responded` is only the Copyable `request` (add `status` if a
  downstream metrics middleware needs it).
- **No response post-processing** — once the terminal (or a gate) streams via the sender, outer
  middleware can't touch the response. That's inherent to a streaming, sender-based response, and it's
  the same root as `Return` being vestigial; it is not a limitation this shape adds.

## The box & projection

- **The box is WireMVC-owned `RequestResponseMiddlewareBox`** — the `pending`/`responded` `~Copyable`
  enum above (see *Short-circuit & the box shape*). **Grounding (4a):** the proposal's own
  `RequestResponseMiddlewareBox` lives *only* in the `HTTPClientConformance` **test module** (under
  `HTTPServerForTesting`), is referenced by nothing, and drags in the whole NIO server stack — not a
  viable dependency for WireMVC's framework-agnostic core. WireMVC ships its own (initially the struct
  spike-15 vendored; now the Model-B enum). Middleware stay the proposal's `Middleware` (the shippable
  `Middleware` module — protocol + `MiddlewareBuilder` + `ChainedMiddleware`); only the
  `Input`/`NextInput` box type is WireMVC's, and the box being unused upstream is why owning it is free.
  `spike-16` confirms the fold compiles over a
  *generic* builder's associated types; `spike-17`
  confirms the enum + `responding`/`withPendingContents` and the always-run short-circuit.
- **Explode = the box's `withPendingContents`.** `consuming func withPendingContents { request, context, reader, sender in … }`
  runs the terminal on a `.pending` box and no-ops on `.responded`; the generated terminal calls it.
  (`@Explode` is only for a *custom* box — e.g. one that retypes `request` — where the author supplies
  the destructure; the standard path never writes it.)
- **Enrichment rides `RequestContext`.** A capability is a child protocol of
  `HTTPServerCapability.RequestContext` (e.g. `protocol AuthenticatedContext: RequestContext { var principal: User { get } }`);
  a middleware's output context conforms to the ones it adds. The `request`/`reader`/`sender`
  slots are structural on the standard box; retyping *them* means a custom box (`@Explode`).
- **A projection type-checks against the final box.** The terminal binds each handler param
  from the box; if the folded final box doesn't provide an attribute at the declared type, the
  bind fails to compile. Nothing in the macro resolves middleware output types — it emits
  type-directed projections and defers to the type-checker.

## Middleware = proposal `Middleware` **and** a Wire component

- A WireMVC middleware *is* the proposal's `Middleware<Input, NextInput>` **and** a normal Wire
  component (its own `@Singleton`/`@Scoped` scope, its own `@Inject` deps). `@Middleware(…)` names a
  middleware *type* (see the naming record below — a generic type can't be named `T.self`, so it takes
  placeholder type args). Request-scoped middleware come from M5.4 for free.
- Three forms (revised — see *`@Middleware` naming, dispatch & the fold* below for what actually
  type-checks):
  1. **Concrete** — `@Middleware(Concrete.self)`, constructed inline. A fully concrete middleware pins
     its box, so it fits *only downstream of an erasing middleware* (one whose `NextInput` is a concrete
     box); it can never unify with the generic base box. Real, but a niche position.
  2. **Generic, dep-free** — `@Middleware(Generic<WireContext, WireReader, WireSender>.self)`. The
     common logging/timing form; constructs inline (no graph). Both non-transforming and
     context-transforming.
  3. **Generic with `@Inject` deps** — declared `@Factory(key) @MiddlewareFactory` and referenced
     `@Middleware(key)`; the plugin synthesises one factory per consumed key (generic over the
     injected axis, `create` over the box roles) and injects it onto the controller. The one form
     needing a swift-wire change; see *Generic middleware: the `@Factory` template + `@MiddlewareFactory`
     mapping*.

## Chains = per-route folds

- `@Middleware` at **controller scope** wraps every route; at **route scope** wraps one route;
  composed **controller-outer → route-inner → handler**.
- Each route's chain is a `MiddlewareBuilder` result-builder **fold** over its middleware,
  terminating in the generated terminal. The final box type is **compiler-inferred** from the
  fold (`MiddlewareBuilder`'s `First.NextInput == Second.Input` thread) — the macro never names
  it; the terminal just explodes it via `withPendingContents`.
- **The fold is witness-local concrete codegen, not a graph binding** — proven by
  `spike-15`. It is *not* a
  `BuilderKey` fold: `BuilderKey` yields a binding whose type must be nameable/opaque, but
  `Middleware` has two primary associated types (`Input`, `NextInput`) that can't be partially
  bound, so "pinned input, opaque output" is not expressible. So the chain is built inline in the
  route witness (where the final box stays concrete-inferred and `withPendingContents` works), with the
  *middleware* pulled from the graph (concrete binding / specialised factory).

## The compile-time guarantee & forwarding

- **The guarantee is the compiler's.** The terminal calls the handler with the projected values
  (`getUser(request: AuthHttpRequest)`); that call type-checks only if the folded box provides
  the projected capability. Remove the middleware that supplies it → the final box no longer
  conforms → compile error at the handler. Neither the macro nor the plugin asserts this.
- **Forwarding is the plugin's, and it's bounded.** A generic wrapping middleware can't
  enumerate the open set of upstream capabilities to forward — but the **build plugin's global
  view** sees every specialisation the folds actually produce, so it emits exactly the
  conditional-conformance forwarding those need
  (`extension SessionWrap: AuthenticatedContext where Base: AuthenticatedContext { … }`),
  bounded by real co-occurrences. This is the one thing only a global-view plugin can do that a
  plain library can't — watch cross-module conformance coherence (retroactive conformance on
  wrapper types).

## Spelling (pinned)

- **`@RawRoute`** — a func-level marker: greppable, stands in for the "exactly one response
  annotation per route" invariant (raw = the handler writes its own response), and flips param
  binding from annotation-required to type-identified.
- **Separate destructured params**, not one box param. The macro proves the `consuming`
  projections are disjoint.
- **Raw params are type-identified** (`reader`/`sender` by their `~Copyable` types; a capability
  by its protocol type); **typed params keep their annotations** (`@Path`/`@JSONBody` — decoded
  sub-parts are genuinely ambiguous, so they must be annotated). Unified: "type-identified vs
  annotated projections of the same box." (Not pure signature-detection — a bare "has a sender
  param ⇒ raw" would leave the route with no greppable response annotation, which the design
  rule forbids.)
- Residual: "whole-slot by type" is really "by type *spelling*" for a syntactic macro; an
  aliased `ResponseSender` is where a minimal marker (or requiring the canonical spelling) might
  return.

## `@Middleware` naming, dispatch & the fold — 4a implementation record

Building 4a surfaced constraints the conceptual design didn't anticipate. All findings validated by
`spike-16` and the wire-mvc implementation.

**The naming problem.** A composable middleware must be generic over the box (`<Ctx, Reader, Sender>`)
to sit at any position — the reader/sender are irreducibly the *server's* associated types (the live
body stream and connection writer; not concretizable without buffering + an existential `~Copyable`
sender, which isn't expressible). But a **generic type can't be named `Generic.self`** — no metatype
without type arguments. Two rescue attempts also failed: a factory *method* can't be explicitly
specialized (`Factory.make<…>()` → "cannot explicitly specialize static method"), and a wrapping
`around(next:)` observer can't capture-and-consume the `~Copyable` box values in its nested closure.

**The dispatch (what the `@Controller` macro emits), by argument syntax:**
- `@Middleware(Concrete.self)` — no generic args → construct inline `Concrete()`. A concrete middleware
  pins its box, so it only unifies **downstream of an erasing middleware** (a generic middleware whose
  `NextInput` is a *concrete* box: it buffers/adapts the server's reader+sender, runs the concrete
  downstream chain, then flushes the result into the real sender on return — trading streaming for
  concreteness, by choice). Proven end-to-end.
- `@Middleware(Generic<WireContext, WireReader, WireSender>.self)` — generic args → strip them, re-spell
  as `Generic<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()`. Inference does **not**
  flow backward through the fold, so the type args must be spelled; and the placeholder types
  (`WireContext`/`WireReader`/`WireSender`, shipped by WireMVC, never instantiated) exist only so the
  annotation's metatype type-checks. This is the common form. Dep-free → inline construction, **no
  swift-wire change**.
- `@Middleware(someKey)` — a `FactoryKey`, not `.self` → the factory case. The key references a
  `@Factory` template; the plugin injects the synthesised factory and the witness calls `.create(…)`
  (see *Generic middleware: the `@Factory` template + `@MiddlewareFactory` mapping*).

**The fold, per route** (built inline in `registerWireRoutes`, witness-local concrete): build the base
`RequestResponseMiddlewareBox` from the register closure's `(request, requestContext, reader,
responseSender)`, `wireCompose { … }` the middleware (controller-outer → route-inner), then
`intercept(input: baseBox) { finalBox in finalBox.withPendingContents { … terminal … } }`. Routes with no
`@Middleware` keep the direct path (conditional emission — internal witness shape, not user surface).

**The `sending` relaxation (load-bearing correctness fix).** The box's `withPendingContents` can only
yield plain `consuming` values (its payload isn't provably in a disconnected region — the proposal's
box yields `consuming` for exactly this reason). But `RoutableHTTPServerBuilder.register` hands the
witness `consuming sending` reader/sender at the boundary, and the terminal's consumers were declared
`consuming sending` to match. Through a fold the sender/reader arrive from `withPendingContents` as plain
`consuming`, so those consumers must **not require `sending`**. Fix: `WireMVCOutcome.send(on:)` and
`WireMVCRequest.collectBody` take `consuming` (not `consuming sending`), and **`@RawRoute` handlers take
`consuming` too** (a raw handler streams within its own region; `consuming` works both directly and
through a fold). A `sending` value still passes fine to a `consuming` parameter, so the no-middleware
and raw-direct paths are unaffected. This refines the M5.2 raw-handler contract: `consuming`, not
`consuming sending`.

**Generic-with-deps: the `@Factory` template.** The deferred piece. The developer declares the
middleware `@Factory(key) @MiddlewareFactory` and references it `@Middleware(key)`; the plugin
synthesises one factory per consumed key — **generic over the injected axis** (the `@Inject`-typed
generic params, threaded through the graph like any generic binding) with a **`create` generic over
the assisted box roles** as metatype parameters, `create(_: RequestContext.Type, _: Reader.Type, _:
ResponseSender.Type) -> Mw<…>` — so the box-role specialisation is *inferred from arguments*,
sidestepping the forbidden explicit method specialisation. The developer never writes the factory:
the plugin reads the deps and the `@MiddlewareFactory` role mapping, synthesises the factory, and
injects it onto the controller's **route-contributor proxy** via the input-edge capability
(macro-generated `@Inject` is invisible to Wire's plugin, so the plugin must do the injection); the
witness calls the uniform
`self._wireFactory_….create(Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)`.
This is the swift-wire Core change; everything above ships as 4a with no swift-wire change. See
*Generic middleware: the `@Factory` template + `@MiddlewareFactory` mapping* for the full record.

## Who does what

For a controller with two controller-scope and two route-scope middleware on a typed route:

- **You** — declare the controller + scope, the route, the response mode, and the two tiers of
  `@Middleware`.
- **`@Singleton` / Wire graph** — makes the controller (and each middleware) a graph binding /
  factory and constructs them (lift-the-minimum).
- **`@Controller` macro** — generates a `RouteContributor` **proxy** (`_WireRouteContributor_<C>`)
  holding the plain controller plus any lifted factories (`.contributesProxy(to:
  WireMVCKeys.routeContributors)`), carries the witness, and reads the controller-scope `@Middleware`
  as the outer wrapping for every route. The controller itself stays a footgun-free `@Singleton`.
- **`@Get`/`@JSONResponse`/route `@Middleware`** — synthesise this route's fold
  (`[ctrl-outer…, route-inner…]` through `MiddlewareBuilder` → terminal) and the terminal
  (explode → project → call handler → encode the return via the sender).
- **Wire build plugin** — emits the graph + folds, specialises generic middleware, and emits the
  forwarding conformances for the specialisations the folds surface.
- **Swift compiler** — threads the fold, infers the final box, and enforces the projection
  type-check (the guarantee).
- **Proposal runtime (per request)** — the server hands the base-box ingredients; the fold's
  `intercept` runs the middleware in order; the terminal explodes, projects, calls the handler,
  and writes the response.

Request flow: `base box → ctrl-mw… → route-mw… → [ explode → project → handler → encode ] → response`.

## What this rests on

- **Shipped Wire:** generic `@Provides` factories (demand-driven specialisation, dedup,
  ambiguity diagnostics). Dep-free and concrete middleware need nothing more — the chain fold is
  witness-local codegen that references ordinary bindings. The **generic-with-deps** tier is the one
  exception: it needs the adapter contract's factory input-edge capability
  (`.injectsFactoryOnArgument`) plus the `@Factory`/`@MiddlewareFactory` template synthesis. The
  *injected* axis of that synthesis reuses the same demand-driven generic specialisation as generic
  `@Provides`; only the *assisted* box-role axis (the `create` metatypes) is genuinely new. Both stay
  domain-free in Wire — it injects a synthesised binding onto a decorated binding, reads the role
  mapping as opaque slot identifiers, and never learns "middleware".
- **Shipped proposal:** `Middleware`/`ChainedMiddleware`/`MiddlewareBuilder`,
  `RequestResponseMiddlewareBox` + `withContents`, `HTTPServerCapability.RequestContext`.
- **No opaque fold to build — corrected by
  `spike-15`.** An earlier
  draft named the type-preserving *opaque `BuilderKey` fold* as the one unbuilt piece. spike-15
  found it is **not expressible**: `Middleware`'s two primary associated types can't be partially
  bound, so a fold can't be returned through a `some Middleware`-with-pinned-input boundary. The
  fold is therefore **witness-local concrete** (which spike-15 proves works end-to-end with the
  real proposal types), so it is *not* a `BuilderKey`/opaque-member fold and there is nothing
  opaque to emit. The one Core-codegen item the design reduces to is the **generic-with-deps
  `@Factory` template** — see the next section.
- **Codegen detail (spike-15):** every plugin-generated forwarding conformance must restate
  `& ~Copyable` in its `where` clause (`extension …: Cap where Base: Cap & ~Copyable`) or Swift
  silently re-imposes `Copyable` and it fails to compile.

## Generic middleware: the `@Factory` template + `@MiddlewareFactory` mapping

> **Status:** settled design. Supersedes both the earlier `make<In>()` "factory-object" model
> (a hidden non-binding lifted onto the controller) *and* the first single-annotation `@Factory`-only
> sketch (a positional `create` in template-declaration order). The settled model makes the template
> **a binding that looks like a binding**, referenced by key, and separates the two genuinely
> different generic axes (below). **Built — the tier is complete:** `@Factory` + `FactoryKey`, factory
> synthesis, the `@MiddlewareFactory` role mapping, and the injected/assisted axis split (the
> generic-aware factory), with every `@Middleware` folding a graph binding via the `.injectsFromGraph`
> capability. The build sequencing is recorded in
> Archive/WireMVCCodegen.md.

For multi-stage chains, middleware are generally **generic over their input box** (a middleware
pinned to one concrete input can only sit where that exact box appears). How the witness obtains
such a middleware splits by whether it has dependencies:

- **Works today, no Core change:** *concrete* middleware (an ordinary binding, injected onto the
  controller) and *generic dep-free* middleware (the witness constructs `Mw<In>()` inline — proven
  in `spike-15`). Covers the
  logging/timing tier.
- **Needs the `@Factory` template:** *generic middleware with `@Inject` deps*
  (auth-with-a-verifier, session-with-a-store). The reason it doesn't fit as a plain binding: the
  `_WireGraph` is a struct of **pre-constructed stored properties, one per binding**, and generic
  bindings are only ever *specialised into concrete stored properties, demand-driven by written
  dependency types*. A middleware in a fold is specialised at the **compiler-inferred** box type —
  never written — so it can be neither a stored property nor demand-specialised.

### Two annotations: `@Factory` (the gate) + `@MiddlewareFactory` (the mapping)

A generic-with-deps middleware carries **two** attributes, mirroring the consumer's two
(`@Singleton @Middleware(key)`):

```swift
@Factory(SessionMiddleware.factory)     // Wire (domain-free): keyed factory template
@MiddlewareFactory                      // WireMVC (adapter): middleware factory, default role mapping
struct SessionMiddleware<RequestContext, Reader, ResponseSender>: Middleware
where RequestContext: HTTPServerCapability.RequestContext {
    @Inject var store: SessionStore
}

extension SessionMiddleware { static let factory = FactoryKey() }
```

- **`@Factory(key)`** is swift-wire's **domain-free** marker: it makes the type a Wire component and
  reads its `@Inject` members as deps, parallel to `@Singleton`. It's a **fixed native name**, so the
  build plugin gates the expensive template extraction (the member walk + generic-clause capture)
  behind a cheap `hasAttribute("Factory")` check — the plugin never has to run that extraction on
  types it later discards.
- **`@MiddlewareFactory`** is WireMVC's adapter annotation: it carries the box-role mapping (below)
  and is captured for free as a use-site, resolved after aggregation and **joined to the `@Factory`
  template by type identity** (the same hash-join `injectAliasContributions` uses). The roles stay
  entirely in WireMVC; swift-wire reads the mapping as opaque ordered slot identifiers.

Two annotations rather than one is the right split on three counts: **efficiency** (only a fixed
native name can gate the extraction cheaply — an adapter-declared name isn't known until after the
per-file scan, forcing extract-everything-just-in-case); **domain-cleanliness** (`@Factory` stays
domain-free, the roles live on `@MiddlewareFactory`); and it's **forced anyway** — `@MiddlewareFactory`
can't macro-attach `@Factory` because macro-added attributes are invisible to the plugin's
pre-expansion scan (the same reason peer macros can't see each other's output). A `@MiddlewareFactory`
without `@Factory` is a diagnostic — the producer-side mirror of a stray adapter alias with no producer.

### Two axes: injected vs assisted

A middleware's generic parameters are not one kind. They fall on **two axes**, and each is threaded
by a completely different mechanism:

- **The injected axis** — a backend/model type the middleware `@Inject`s but doesn't want to name
  (the lifted-generic pattern, `struct C<R: Repo> { @Inject var r: R }` — the primary reason a
  *controller* is generic too). This is a **dependency**, resolved by the graph.
- **The assisted axis** — the box roles `RequestContext`, `Reader`, `ResponseSender`. These are
  **compiler-inferred at the fold** (see *Chains = per-route folds*), never written, never a graph
  binding — so they can only be supplied as **metatypes at the `create` call**.

swift-wire **partitions the parameters from data it already has**: a generic parameter is
injected-axis *iff it appears as the type of an `@Inject` member*; every other parameter is
assisted. So `@MiddlewareFactory`'s mapping only ever concerns the assisted params — the injected
ones are auto-detected and out of its scope.

The injected axis is the load-bearing simplification: it **rides Wire's existing generic
specialisation** rather than any new coordination. The synthesised factory becomes *generic over the
injected type* and holds it as a stored (graph-resolved) property; a generic controller and the
middleware "share" the backend because both injection edges resolve to the same binding — threaded
through the **graph**, not the call site. This dissolves what looked like the hard case (a middleware
generic over a controller's parameter): when that parameter is *injected*, there is no call-site
threading, no per-controller adapter, and no "which controller generic" ambiguity. A middleware
generic over a controller's *assisted* (non-injected) parameter is not a real use case — a controller
is generic to inject an unknown backend, and the box roles are the only other assisted axis — so it
is **disallowed**, not supported.

### The calling convention & the role-assignment problem

The `@Controller` macro authors the `create` call **blind to the template** (it's a peer/type-level
macro; the template's generic clause lives in another type, possibly another module). So the call
must be **uniform** — always the canonical box-role triple, nothing else:

```swift
self._wireFactory_SessionMiddleware_factory.create(
    Builder.RequestContext.self, Builder.Reader.self, Builder.ResponseSender.self)
```

Two things fall out. First, the macro never passes injected params or controller generics — those
are on the factory struct, already specialised via the graph. Second, because the macro fixes a
**canonical role order**, swift-wire must emit `create`'s parameters *in that same order* — which
means it must know each assisted parameter's **role** to reorder the template's arbitrarily-ordered
generic clause into canonical order. That is the **role-assignment problem**: a Swift generic
parameter carries no intrinsic tag saying which slot it fills, and the assignment can't be inferred
domain-free (by position it breaks under subsetting; by name it's an arbitrary author choice; by
constraint the constraints are often on the `Middleware` conformance's `where` clause the scanner
can't see). So the assignment must be *declared* — that is exactly what `@MiddlewareFactory` supplies,
and why the mapping is load-bearing for **emission**, not merely validation.

Because `create` accepts the full canonical triple and maps the used subset into the return type,
there is **no separate adapter type** — the reordering/subsetting *is* `create`'s body. An unused
role is still a `create` parameter (`_: Reader.Type`) so it type-checks, just absent from the return.

### The synthesised factory

```swift
// plugin-generated — a generic binding: struct generic over the injected axis, create over the assisted axis
struct _WireFactory_SessionMiddleware_factory<Repository: TodoRepository> {   // injected axis
    let repository: Repository                                                //   → stored, graph-resolved
    func create<RequestContext, Reader, ResponseSender>(                      // assisted axis
        _: RequestContext.Type, _: Reader.Type, _: ResponseSender.Type
    ) -> SessionMiddleware<RequestContext, Reader, ResponseSender, Repository>
    where RequestContext: HTTPServerCapability.RequestContext {
        SessionMiddleware(repository: repository)
    }
}
```

- The **struct** is generic over the injected params and stores the deps; it is registered as an
  ordinary **generic binding**, so demand-driven specialisation threads the injected type through the
  dependency edge (a generic controller depending on this factory pins its `Repository` for it). This
  exercises **chained** generic specialisation (generic controller → generic factory → concrete
  backend) — the shape the lifted-generic / constrained-parameter bridge is built for, worth
  validating explicitly rather than assumed free.
- **`create`** is generic over the box roles as **metatype parameters**, so specialisation is
  *inferred from arguments* — sidestepping the forbidden explicit method specialisation
  (`Factory.make<…>()` → "cannot explicitly specialize static method"). Its generic parameters are
  named by the **canonical roles** (in the fixed WireMVC order the macro calls with); the mapping
  decides how they thread into the middleware's actual generic slots.

This splits exactly along the macro/plugin line: only the **plugin** (global view) sees the deps and
writes the construction; the **macro-witness** (syntactic) only *names* the factory and calls
`.create(…)`. The generic `create` lives on a *concrete-per-specialisation* struct, sidestepping the
"a bare generic function isn't a first-class value" problem. (A whole-graph back-reference is
reserved for M5.4's request-scope proxy; middleware construction doesn't need one.)

### `@MiddlewareFactory`: the role mapping

`@MiddlewareFactory`'s *entire* job is to role-tag the **assisted** parameters — at most three, the
box roles it knows about. Nothing about the injected params.

- **Common case → defaulted.** Parameters ordered canonically → bare `@MiddlewareFactory`, no
  arguments. The default is **positional** (resolved): `param[i]` takes `canonicalRole[i]`, so
  `<Ctx, Reader, Sender>` works with a bare marker regardless of the names; subsetting or reordering
  reaches for the explicit list. (Name-based was the rejected alternative — it maps by name and subsets
  bare, but forces the verbose names `RequestContext`/`Reader`/`ResponseSender`.)
- **Custom case → an ordered role list**, positional over the *non-injected* parameters, e.g.
  `@MiddlewareFactory(.requestContext, .responseSender)` for a middleware that pins its own reader.
  It deliberately doesn't *name* parameters inside the attribute (a type's own generics aren't in
  scope there, and the plugin must read it pre-expansion), so the mapping is a literal the scanner
  can parse.
- **Validation** is total: every non-injected parameter must be assigned a role, every injected
  parameter must appear in an `@Inject` type, and a parameter that is neither is an error — so the
  name-default's failure mode is *loud* ("`Context` matches no role; declare the mapping"), never a
  silent mis-assignment.

### `FactoryKey` — a namespace identifier

`FactoryKey` joins Wire's key family (`BindingKey` / `CollectedKey` / `MappedKey` / `BuilderKey`).
Unlike those, it is **not** typed to the produced value — the produced type is generic and varies
per consumer, so no single `Value` could be fixed. It is a **namespace identifier**: its identity
is the canonical text of its declaring reference (`SessionMiddleware.factory`), and the synthesised
factory type name derives from it. This is a lighter compile-time check than a typed key; the real
type safety lands at the `create` call, where the compiler unifies the assisted metatypes against the
template's generic signature.

### The consumer: `@Middleware(key)` and the concrete `.self` case

Synthesis is **consumer-driven** (like a generic `@Provides` factory, the template defines but
synthesises nothing on its own): collate every `@Middleware(key)` use-site, dedupe by key, synthesise
one factory per consumed key, register it as a binding, and inject it into the consuming controllers
via the capability `@Middleware` declares — **`.injectsFromGraph`** (the input edge; see
[AdapterModel.md](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/AdapterModel.md), *The capability axis*). The consumer surface is unchanged across
every tier above — a controller always writes just `@Middleware(SessionMiddleware.factory)`; the
box-role subsetting and the injected axis are entirely absorbed producer-side.

Every `@Middleware` folds a graph binding; the plugin dispatches on the argument's *kind*:

- **`@Middleware(key)` — the factory case.** The key references a `@Factory` template; the plugin
  synthesises the factory, lifts it onto the proxy, and the witness calls `.create(…)`.
- **`@Middleware(key)` — a keyed binding.** A `BindingKey`, not a factory template: the graph binding
  stored under that key is injected onto the proxy and folded directly (`_wire<sanitisedKey>`).
- **`@Middleware(ConcreteType.self)` — a binding by type.** `.self`, not a key: the `ConcreteType`
  binding is injected by type onto the proxy and folded directly (`_wire<Type>`) — no inline
  construction. A generic middleware always moves to a keyed `@Factory` template (retiring the earlier
  `@Middleware(Generic<WireContext, WireReader, WireSender>.self)` spelling). See
  Archive/WireMVCCodegen.md, *3.4*.

## Open sub-decisions

- `@Explode` vs `@Explode` + a capability-declaration attribute — one attribute or two (the
  write-side sugar for custom boxes; the common path uses neither).
- The whole-slot type-spelling fragility above (canonical spelling vs a minimal marker).
- Per-route folds vs a small number of deduplicated chain bindings (an optimisation, not a
  correctness question).

## Settled during design (no longer open)

- **Chained generic specialisation** — validated: the injected-axis factory is a generic binding a
  generic controller depends on (generic → generic → concrete backend), threaded through the graph's
  lift parameter by the existing transitive-lift machinery. Shipped as the injected axis (see
  Archive/WireMVCCodegen.md, *A5*), proven end-to-end by a generic
  controller and its middleware sharing one repository backend.
- **`@MiddlewareFactory` default-mapping dial** — **positional** (`param[i] → canonicalRole[i]`), so a
  bare marker maps `<Ctx, Reader, Sender>` by order; subset/reorder uses the explicit role list.
  Name-based (map by parameter name, subset bare, verbose names) was rejected.
- **Middleware generic over a controller's *assisted* parameter** — disallowed, not supported. The
  real "shared with the controller" case is the *injected* axis (both `@Inject` the same backend),
  which rides graph specialisation; there is no other assisted axis than the box roles. A `.fromController`
  marker was considered and dropped.
- **A separate per-controller adapter type** — not needed. `create` accepts the full canonical
  box-role triple and maps the used subset into its return; the reordering *is* `create`'s body.

---

<sub>Milestone shorthand used in this note (M1, M5.4, M7b…) is defined in ROADMAP.md; outstanding gaps are indexed in KnownGaps.md.</sub>
