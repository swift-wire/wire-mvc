# A linear response-header registry — implementation brief

> **Status: built.** wire-mvc and wire-open-api are done and green; wire-mvc-examples' two call sites are
> converted but cannot compile until the pin moves (see *Sequencing*). The upstream annotation was never
> declined — it was never *asked*, and this was taken instead on the grounds that the API break is
> affordable while there are no consumers. If `requestContext: consuming sending RequestContext` still
> lands upstream later it is now a simplification, not a rescue.
>
> **What it cost, concretely:** every contributing middleware moved from `input.responseHeaders.add(…)`
> to `input.contributing { headers in … } then: { … }`, and a transforming one's `withContents` lost the
> registry from its `responded` branch. Ten middleware across four repositories.
>
> **Since built:** `drain()` became `consuming` and the terminals took ownership of the drain — see
> *The sequel: exactly-once draining*, which is where this brief's central claim about linearity gets
> corrected.
>
> **What it bought, measured:** the second payoff this brief hoped for and could not promise —
> **six allocations and 1536 bytes per request**, reproducible to the allocation, on a case where the
> registry genuinely escapes. See *Measured*, and note that the brief predicted one allocation, not six.
>
> Reached from swift-wire's
> `RemainingSurfaceWork.md`
> (its response-header allocation item) and wire-mvc-examples'
> [`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md),
> which carry the measurements this plan is a response to.

## Where the plan was wrong

Four things, and the first two matter because the plan's stated reasoning was *right about the conclusion
and wrong about the cause* — which would have sent the next reader down the same path.

1. **The destructure must not be closure-yielding.** The plan specified
   `withContents(_ body: (sending Registry, consuming Base) -> R)`, reasoning that a tuple cannot carry
   `sending`. True, but the real constraint is blunter: **a tuple may not have a noncopyable element at
   all**, so no tuple spelling was ever available. More importantly the closure form is actively wrong
   here. The front layer's `reader` and `responseSender` are its own `sending` parameters; inside a closure
   they become *captures*, captures are task-isolated, and the box then refuses them — the exact region
   merge this whole exercise exists to prevent, reintroduced one layer up.

   What works is a `~Copyable` struct, ``WireMVCContextContents``, whose two fields the caller consumes
   separately **in its own frame**. It hands the registry back still wrapped in ``WireDisconnected``, so no
   `sending` annotation is needed to return it; unwrapping is the caller's `take()`, performed where the
   reader and sender are still parameters.

2. **`WireMVCContextContents` has to be `@frozen`.** Partial consumption of a non-frozen type is refused
   *across a module boundary*, and every caller is across one — the code that destructures a courier is the
   generated `_WireRoutes.swift` in the app's own module. An in-module spike will not surface this.

3. **The registry lives in `pending` only — `responded` carries none.** The plan had it in both cases, as
   the class was. That is not merely unnecessary but actively misleading: nothing drains a `responded`
   box, so a field contributed after a gate responds could never reach any response. Leaving the registry
   out of that case makes the mistake unwriteable instead of documented.

   This forced the contribution API. A `mutating contribute` cannot reach a registry inside an enum
   payload — mutating it there means consuming and reinitialising the storage, a partial reinitialisation
   of `self`, which is rejected. A **consuming** method can, because it consumes `self` whole. So
   contribution is `contributing(_:then:)`, built on the same `withContents` primitive a transforming
   middleware uses.

4. **The front layer's box is over `Base`, not over the courier.** The plan said "reconstruct a courier
   from base + registry" in the terminal, which is right, but did not draw the consequence: with exactly
   one registry the box cannot both own it *and* hold a courier that also carries it. So the box is built
   over the unwrapped context, and global middleware now fold over `Handler.RequestContext.Base` — the same
   context every other route's box already used. ``ResponseHeaderCarrying`` gained an
   `init(base:responseHeaders:)` requirement to make the rebuild expressible.

**The abandon criterion was not hit.** The step 3 round trip typechecks with no `unsafe` escape hatch
beyond the ``WireDisconnected`` that was already there.

### One compiler bug, worked around

A wildcard-bound `consuming sending` noncopyable closure parameter — `withPendingContents { …, _ in }` —
fails SIL verification before ownership lowering and **crashes the compiler** rather than diagnosing
anything. It is reached by exactly one emission, the introspection mount, whose terminal wants none of what
the box yields. Codegen names the parameter and consumes it explicitly instead; see `unusedRegistryLocal`.
Verified on `6.4.x-snapshot-2026-08-01`, and worth re-testing before anyone tidies it back to `_`.

## What it buys

A `@RawRoute` cannot today declare its response sender `consuming sending Sender` when the sender is the
**untransformed** one — every raw route not sitting behind a sender-transforming middleware, and always a
`@NotFound`, since `registerNotFound` folds no middleware and so can never be handed a transformed sender.

A reader already takes `sending`, including through a middleware fold. So does a transformed sender
(`MultiPartSender<S>`). Only the untransformed sender refuses, and it refuses for one reason: codegen wraps
it as `ResponseHeaderApplyingSender(wrapping: responseSender, registry: …)`, and the registry is
task-isolated, so the composite is too.

The registry is task-isolated because of **provenance, not aliasing** — regions permit aliasing within a
region. `handle` hands `reader` and `responseSender` over `consuming sending` and `requestContext` plain
`consuming`; the registry travels inside the context (it must: `handle` takes exactly four values and the
context is the only extension point among them), so everything read out of it is in the task's region.

This plan gives the registry the treatment the reader and sender already get.

## The mechanism, and why it needs both halves

``WireDisconnected`` works by `nonisolated(unsafe) var wrapped`, which opts its contents out of region
tracking; the wrapper is itself `Sendable`, so an aggregate storing one does not merge regions. That is
precisely why a task-isolated box can still hand out `sending` reader and sender.

Putting the registry in one makes the wrapper disconnected, and it compiles. **On its own it is unsound.**
`WireDisconnected`'s stated safety argument is that *"the stored value is never aliased"* — true of a
`~Copyable` reader or sender by construction, false of a class reference. This compiles today with no
diagnostic:

```swift
let escapee = ctx.registry.wrapped          // a second reference, trivially
let reg = ctx.takeRegistry()                // handed out `sending`
await handler(sender: Wrapper(base: sender, registry: reg))
return escapee                              // still live after the transfer
```

`nonisolated(unsafe)` does not remove the aliases; it removes the compiler's ability to see them. And the
aliases are real in the shipping code — `GlobalMiddlewareHandler.swift:52` holds `let registry =
requestContext.responseHeaders` in an outer frame for the whole duration of `chain.intercept(…)`.

So the registry has to become `~Copyable` as well. That is the half that costs, and everything below is a
consequence of it.

## Steps, in dependency order

### 1. `ResponseHeaderRegistry` becomes a `~Copyable` struct

Swift has no noncopyable classes, so `public final class` (`ResponseHeaderRegistry.swift:34`) becomes
`public struct … : ~Copyable`.

- `add(_:)`, the variadic `add(_:…)` and `onSend(_:)` become `mutating`.
- `drain(into:)` and `drain()` stay non-mutating — `borrowing`. **Both are `consuming` now**: `drain(into:)` in #159 and `drain()` in the sequel below, which is where the reasoning is.
- Internal storage is unaffected: `InlineArray<4, Registration?>`, `overflow: [Registration]` and the
  `.deferred` closures are all copyable and stay exactly as they are.
- **`onSend`'s closure stays non-`@Sendable`.** This is the advantage over making the registry `Sendable`,
  and it is not incidental — a middleware computing a deferred contribution captures per-request,
  non-`Sendable` state (a session, to derive a cookie). That capability survives this plan and would not
  survive the other one.

The consequence that drives steps 3–5: *reach it borrowing and mutate through the reference* stops working.
Every holder must own it or borrow it explicitly.

### 2. `WireMVCContext` carries it in `WireDisconnected`

`WireDisconnected` becomes **public** — generated code has to name it, since it is what
``WireMVCContextContents`` hands the registry back in — but its `wrapped` storage stays internal, so
`init(_:)` and `take()` remain the only way in and out and the type's safety argument survives. It also
gains `withMutable`, so the box can contribute to the registry without consuming and reinitialising itself.

The protocol requirement changes. `ResponseHeaderCarrying.responseHeaders` is a `{ get }`, which cannot
hand out a linear value. It becomes a consuming destructure returning a `~Copyable` struct — **not** the
closure-yielding form this brief originally specified, for the two reasons in *Where the plan was wrong*:

```swift
consuming func takeContents() -> WireMVCContextContents<Base>

@frozen
public struct WireMVCContextContents<Base: HTTPServerCapability.RequestContext & ~Copyable>: ~Copyable {
    public var responseHeaders: WireDisconnected<ResponseHeaderRegistry>
    public var base: Base
}
```

`takeBase()` folds into it. Folding rather than keeping both is the safer shape: a linear registry must be
accounted for by *someone*, and a surviving `takeBase()` would let a caller drop it silently. A second
requirement, `init(base:responseHeaders:)`, is what lets the front layer put the courier back together.

Both construction sites wrap: `RequestContextCourier.swift` and `WireMVCServerTransport.swift:339` — the
second builds its courier **inside an unstructured `Task`**, which is fine (the registry is constructed
there, so it is disconnected at birth).

### 3. The front layer takes it out and puts it back

`GlobalMiddlewareHandler.handle` reads the registry, builds its box with it, runs the chain, and its
terminal calls `inner.handle(request:requestContext:reader:responseSender:)` — passing the **courier**
onward, because it pins `Inner.RequestContext == RequestContext`.

With a linear registry it instead destructures the courier into (registry, base), builds the box owning the
registry, and then — in the terminal, from the box's own destructure — **reconstructs** a courier from
base + registry to hand to `inner.handle`. One re-wrap per request.

The pin changes with it: `Chain.Input` becomes
`RequestResponseMiddlewareBox<Inner.RequestContext.Base, …>`, because the box cannot own the only registry
*and* hold a courier that carries it. Global middleware therefore fold over the unwrapped context now, like
every other tier.

This was expected to be the fiddly step and was not. What actually bit was one layer up: doing the
destructure inside a closure, which is what the original brief prescribed and which silently turns the
front layer's `reader` and `responseSender` into task-isolated captures.

### 4. The box owns it, in `pending` only

`Storage.pending` gains a `WireDisconnected<ResponseHeaderRegistry>`; `Storage.responded` loses its
registry entirely and becomes `responded(request:)`. A responded box has written its head, and no drain is
reachable from it — `respondingWith` drains on its way out, raw `responding` never drains, and a route
terminal reaches its drain through `withPendingContents`, which does nothing in that state. Carrying a
registry there would let a middleware contribute a field that could not reach any response.

`public var responseHeaders: ResponseHeaderRegistry { get }` cannot survive. In its place, one primitive
and one convenience:

```swift
// the primitive — also what a transforming middleware already used
consuming func withContents<R: ~Copyable>(
    pending: (HTTPRequest, consuming RequestContext, consuming sending Reader,
              consuming sending ResponseSender, consuming sending ResponseHeaderRegistry) async throws -> R,
    responded: (HTTPRequest) async throws -> R      // no registry to thread
) async throws -> R

// the convenience — what almost every contributing middleware wants
consuming func contributing<R: ~Copyable>(
    _ contribute: (inout ResponseHeaderRegistry) throws -> Void,
    then body: (consuming Self) async throws -> R
) async throws -> R
```

`contributing` hands the registry over `inout`, so several fields — and conditional ones, which CORS has
four of — are added in one pass rather than nesting one call deep each; `body` then receives the rebuilt
box, so a middleware that short-circuits after contributing calls `respondingWith` on what it is given.
`ResponseHeaderRegistry.with(_:)` is the transform spelling for the primitive path
(`responseHeaders: responseHeaders.with(.set(…))`).

**`contributing` is the one place the `responded` case is absorbed rather than spelled out**: there is no
registry, so the closure is simply not called. That is deliberate — an always-run observer contributes
unconditionally and cannot know a gate outside it already answered — and it is the single documented
silence in the design, pinned by a test rather than left to the comment.

`withPendingContents` gains the registry as its fifth yielded value, so a terminal receives it **from the
destructure** rather than from a captured local. That threading *is* the fix: it is what makes the
wrapper's two inputs both disconnected.

`respondingWith` already consumes the box, so it owns the registry, drains it, and returns a `responded`
box with none.

### 5. `ResponseHeaderApplyingSender` owns the registry

`let registry: ResponseHeaderRegistry` (`RequestContextCourier.swift:162-173`) becomes an owned linear
stored property, and `init(wrapping:registry:)` takes it `consuming sending`. `applying(to:)` stays
`borrowing` since `drain(into:)` only reads. (It consumes now — see the sequel below.)

Watch the `consuming` methods: `send(_:)` and `sendAndFinish(_:buffer:trailer:)` do `let inner = consume
self.base`, which becomes a *partial* consumption of a struct with two noncopyable fields. Legal without a
`deinit`, which this type does not have — but it is the sort of thing that compiles in one method and not
in the next, so do it early rather than last.

### 6. Codegen threads it instead of capturing it

Every emitter that wrote `let … = requestContext.responseHeaders` now emits the destructure, and the
registry is threaded to whoever consumes it — the box when there is one, the outcome or the wrapper when
there is not. The two hand-rolled preambles (raw route, `@NotFound`) collapsed into one `registryLocal`
parameter on `emitRegisterClosure`, which binds the registry from the courier on the fold-less path and
from the **box's own destructure** on the folded one, under whichever name that terminal expects.

Two knock-on corrections:

- **`rawArgument(forPrimitive:)` had to become path-aware.** It emitted `requestContext.takeBase()` for a
  `.context` role unconditionally, including on the fold path where the terminal's `requestContext` is
  *already* the base. Latent, because no fixture combined a raw route, a fold, and a context parameter.
- **`middlewareFactoryConstructions`' `contextType`** moved from `Handler.RequestContext` to
  `Handler.RequestContext.Base` for the global tier, following step 3. Both call sites now pass `.Base`,
  so the parameter survives only to name the differing generic parameter.

The linchpin is the raw-route-with-middleware path: the wrapper is built from the registry the box hands
back, not from a captured local. Everything else in this plan exists to make that line expressible, and
`WireMVCFallbackExample`'s `pingSending` is where it is now compiled.

### 7. `wire-open-api` follows, across a pin

Not confined to wire-mvc. `WireOpenAPIGen/DirectDispatchEmission.swift` emits the same shapes, and its
folded path needed the same correction as wire-mvc's: the wrapper takes the registry from
`withPendingContents`'s fifth yielded value, not from a local read before the fold.

**Sequencing.** wire-mvc → wire-open-api → move the pin → wire-mvc-examples. Both downstream repos pin
wire-mvc from git `main`, so neither compiles against these changes until wire-mvc is pushed. Both were
verified here with `swift package edit wire-mvc --path …`, which is a verification device and not a state
to leave behind — the overrides were removed.

> **Note for whoever moves the pin.** wire-mvc-examples does *not* build against wire-mvc `main` today, and
> did not before this work: `SwiftHttpServerExample/Sources/SwiftHttpServerExample/CouchDB.swift` fails
> with "property cannot be declared package because its type uses an internal type", from import-visibility
> changes that landed after the revision the examples' `Package.resolved` pins. Confirmed pre-existing by
> building both repos clean against wire-mvc `HEAD`. Fix it as part of moving the pin; it is not this
> change's doing, and it will otherwise look like it is.

## The public break, stated plainly

Middleware used to write `input.responseHeaders.add(.set(…))`, and that worked *only* because a class
reference mutates through a borrow. Every such call site becomes:

```swift
return try await input.contributing { headers in
    headers.add(.set(.init("x-served-by")!, "wire-mvc"))
} then: { input in
    try await next(input)
}
```

Two lines become six, and that is the honest cost. It buys the thing a shorter spelling could not: there
is no way to contribute to a box that has already responded, because such a box holds no registry.

The realised blast radius was smaller than this brief feared: `CORSMiddleware`, three fixture middleware,
three in wire-mvc's own tests, wire-open-api's fixture, and wire-mvc-examples' `ResponseDefaults` and
`MultiPartExport`. The examples' `LogRequests` / `AuditGate` / `RequireAPIKey` / `ServeStaticFiles`, named
here as casualties, never touched the registry at all — the list was written from memory rather than from
a grep. Outside these repositories it is still every middleware anyone has written.

A transforming middleware pays a second, smaller change: `withContents`'s `pending` branch gained the
registry as a trailing parameter, replacing the local read before the destructure, and its `responded`
branch takes only the request — there is nothing left to thread.

## Verification

The acceptance test did not exist, which is how the constraint went unnoticed. It does now, in both halves,
and **compiling is the test**:

- `WireMVCFallbackExample`'s `PingController.pingSending` — a `@RawRoute` declaring
  `consuming sending Sender` **behind a middleware fold**, on the controller that folds `ControllerStamp`.
  This is the linchpin: the generated terminal reads
  `ResponseHeaderApplyingSender(wrapping: responseSender, registry: wireMVCResponseHeaderRegistry)` where
  the registry is the box destructure's fifth value, not a captured local.
- `WireMVCBootstrapExample`'s `handleNotFound` — the same spelling **with no fold**. A `@NotFound` folds no
  middleware by construction, so its sender is always the untransformed one; it was the route this could
  never work on.

`notFoundHandlerRegistersAsFallback` still asserts only on rendered source — it parses that spelling and
never compiles it. It is no longer advertising something impossible, and its doc comment now points at the
fixture that does compile it.

The regression net stayed green untouched: 309 tests across wire-mvc and its fixtures, plus wire-open-api's.
The only test edits were golden-source expectations for the new emission.

### Measured: six allocations and 1536 bytes per request

Counted with wire-mvc-performance's `malloc` interposer, using its slope method — each case run at 22,000
and 62,000 requests, the difference divided by 40,000, so process startup cancels. Two matched pairs, two
replicates, **identical to the allocation** across both:

| pair | before | after | saved |
|---|---|---|---|
| `+courier` − `trie-only` | +6.00 allocs, +1536 B | +0.00, +0 B | **−6.00 allocs, −1536 B** |
| `courier-headers` − `routed-match` | +36.00 allocs, +3924 B | +30.00, +2388 B | **−6.00 allocs, −1536 B** |

The baselines are the control and they did not move: `trie-only` measures 48.00 allocations and
`routed-match` 66.00 on *both* builds, byte-identical. Nothing outside the courier path changed.

**The second pair is the one that matters, and it is why this is trustworthy.** wire-mvc-performance's
README warned that its `+registry` case had stopped measuring the registry — it never escaped the handler,
so the optimiser was free to promote it, and a struct registry would have measured "free" for the wrong
reason. `courier-headers` genuinely uses it: it contributes a field, drains it, and wraps the sender. The
saving there is **the same 6.00**, not a smaller one. So this is the allocation going away, not the
optimiser deleting work nobody asked for.

**It is six, and the brief predicted one.** The class instance is one of them; what the other five were is
*not* established by this measurement, and the obvious guess is wrong — an extra async frame for
``WireMVCContextHandler`` would still be paid after the change, since that type is untouched and the
after-figure is zero. Something about a class reference riding in the courier cost five more allocations
than the instance itself. Worth attributing before the number is quoted as a design argument; the honest
claim today is the delta, which is measured, and not the mechanism, which is not.

For context, `courier-headers` still costs +30 allocations over `routed-match` after this change. The
registry was never the expensive part of contributing a header — the README puts `HTTPFields` insertion at
3–4 allocations per field, and that is untouched here.

## Abandon criteria — both retired

- **Upstream accepts `consuming sending RequestContext`.** Not asked, so not declined. If it lands later it
  no longer rescues anything; it would let the courier hold the registry directly and let this note's
  machinery be deleted, which is a simplification worth taking but not urgent.
- **The round trip in step 3 does not typecheck cleanly.** It does, with no `unsafe` beyond the
  ``WireDisconnected`` that was already in the design.

## The sequel: exactly-once draining

**Status: shipped.** This brief argued ownership on the grounds that linearity turns "drained exactly once"
from a convention into a compiler-checked property. It delivered exclusive **ownership** of the registry. It
did not deliver exactly-once **draining**, and the gap between the two was a live defect for the whole
interval — recorded as [#176](https://github.com/tachyonics/wire-mvc/issues/176), found by trying to make `drain()` `consuming` and
being refused.

### What the gap was

A typed terminal needs the middleware's contributions on two paths that are **not exclusive**: the outcome
the handler built, and the `@ErrorResponse` mapping of a throw. It drained at both. Argument evaluation
reaches the success drain last, so a handler that throws never got there — the ordinary path drained once.
The window was a *deferred* contribution: the success drain runs `onSend` closures in order, one throws
part-way, the `catch` maps the error and drains **the same registry again from the start**, re-running every
closure that had already succeeded. `onSend`'s closure is deliberately non-`@Sendable` so a middleware can
capture per-request state in it — the capability this brief calls the advantage over making the registry
`Sendable` — which is exactly what makes a second run a hazard rather than a curiosity.

### Why generated code could not close it

Three arrangements were available and all three trade something the tier had already bought:

- **Drain before the route body.** Runs `onSend` ahead of the handler, which is precisely what deferral
  exists to avoid.
- **Drain after the mapping.** Loses the documented behaviour that a throw from `onSend` maps through
  `@ErrorResponse` like any other route error.
- **Hold the registry in an `Optional` and take it.** Preserves both, and works — `take()` on an `Optional`
  of a noncopyable is five lines the standard library does not supply but nothing prevents. Enforcement is
  the `nil`, not the compiler, which is the property #148 was argued on.

The **streaming** tier settles it, and is the half worth recording. There, the two drains sit in the
`building` and `errorMapping` closures handed to `wireMVCStreamingTerminal`, and a noncopyable value
captured by a closure cannot be consumed **at all** — not twice, once:

```
error: noncopyable 'wireMVCResponseHeaderDrain' cannot be consumed when captured by an escaping
       closure or borrowed by a non-Escapable type
   |         `- error: noncopyable 'wireMVCResponseHeaderDrain' cannot be consumed ...
   |   building: { … try await wireMVCResponseHeaderDrain.drain() … },
   |                                                      `- note: consumed here
```

So no rearrangement of the drain sites reaches a `consuming drain()` on that tier. The registry has to stop
being something generated code holds.

### What shipped

The terminals own it. `wireMVCBufferedTerminal` and the three `wireMVCStreamingTerminal` overloads each take
`responseHeaders: consuming ResponseHeaderRegistry`, run `building`, drain **once**, and resolve the result
onto whichever branch ran (`ResponseTerminals.swift`). The drain sits after the handler, so deferral still
works; before anything reaches the wire, so a throw from a contribution still maps; on every path, so a
mapped `401` still carries the `WWW-Authenticate` #155 restored. `drain()` is `consuming`, and every route
in the fixture suite compiles against it.

This is the move the **response sender** already made, for the same reason and one value over. `wireMVCStreamingTerminal`'s
own note records it: discriminate inside the `do`/`catch`, consume the sender once, outside it — because
`'responseSender' consumed more than once` is what the checker says otherwise. The registry was the second
linear value in that function and had not been given the same treatment. The reader is now the third: a
route body that has moved inside `building` can no longer consume the reader either, which is why the
buffered terminal grew the same `collectingBodyFrom:` / `lendingBodyFrom:` overloads the streaming one had.

### What it cost, and what it gave back

Generated code got **smaller**. The buffered tier no longer writes its own `do`/`catch`, so the mapped-error
block — `var wireMVCMapped = …; wireMVCMapped.headerFields = resolved(returned:middleware:); wireMVCOutcome =
wireMVCMapped` — collapses to `return WireMVCOutcome.status(…)`, and the two terminal emitters merged into
one: they had differed only in the shape the buffered `do`/`catch` forced. Net −107 lines of codegen (208
deleted against 101 added) for +193 of hand-written, tested runtime.

Two things came out of the emission that had been hidden by it. A route now names `headerFields:` only when
it states one — the empty-arguments fallback was unreachable while every typed route named at least
`middleware:`, and it emitted `[:]`, which allocates where the defaulted `HTTPFields()` does not. And the
late fold rests on an equivalence worth stating: middleware contributions apply **last**, over whatever
`statics` and `returned` composed, so `resolved(returned: resolved(statics:returned:), middleware:)` is
`resolved(statics:returned:middleware:)`. The mapped-error path had always relied on it; it now has a test.

### What this says about the original argument

The brief was right that ownership was the thing to buy and right that soundness, not allocations, was the
forcing reason. What it got wrong is smaller and more useful: it treated "exactly once" as something
linearity *gives* you. Linearity gives you one owner. Exactly-once is a property of where the owner puts the
value, and on a control-flow shape with two non-exclusive exits, the only place that works is a function
that owns the value and discriminates before it consumes anything. That shape already existed in this tier,
for the sender, and was not recognised as the general answer.

## What it does not buy

The request context itself stays task-isolated. This plan launders exactly one value out of it. Anything
else that later needs to travel in the context and reach a `sending` position — a connection-info
capability, say — faces the same problem again and does not inherit a solution from this.
