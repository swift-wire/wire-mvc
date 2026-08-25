# A linear response-header registry — implementation brief

> **Status:** designed, not started, and **deliberately the second choice.** It exists so that the
> in-house option is written down rather than re-derived, not because it is the one to take. The same
> outcome is available for one word upstream — `requestContext: consuming sending RequestContext` on
> `HTTPServerRequestHandler.handle` — after which today's generated code compiles unchanged. **Start this
> only if the proposal declines that annotation or stalls on it.** See *Abandon criteria* at the end.
>
> Reached from swift-wire's
> [`RemainingSurfaceWork.md`](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/RemainingSurfaceWork.md)
> (Phase 3, item 1) and wire-mvc-examples'
> [`HummingbirdExamplesParity.md`](https://github.com/tachyonics/wire-mvc-examples/blob/main/Documentation/Notes/HummingbirdExamplesParity.md),
> which carry the measurements this plan is a response to.

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
- `drain(into:)` and `drain()` stay non-mutating — `borrowing`.
- Internal storage is unaffected: `InlineArray<4, Registration?>`, `overflow: [Registration]` and the
  `.deferred` closures are all copyable and stay exactly as they are.
- **`onSend`'s closure stays non-`@Sendable`.** This is the advantage over making the registry `Sendable`,
  and it is not incidental — a middleware computing a deferred contribution captures per-request,
  non-`Sendable` state (a session, to derive a cookie). That capability survives this plan and would not
  survive the other one.

The consequence that drives steps 3–5: *reach it borrowing and mutate through the reference* stops working.
Every holder must own it or borrow it explicitly.

### 2. `WireMVCContext` carries it in `WireDisconnected`

`WireDisconnected` stays internal, as it is inside the box today.

The protocol requirement has to change. `ResponseHeaderCarrying.responseHeaders` (`RequestContextCourier.swift:12-20`)
is a `{ get }`, which cannot hand out a linear value. It becomes a consuming destructure — and it must be
the **closure-yielding** form, mirroring the box's `withPendingContents`, because `sending` cannot be
applied to tuple elements (checked: `error: 'sending' cannot be applied to tuple elements`, so a
`consuming func take() -> (sending ResponseHeaderRegistry, Base)` is not expressible):

```swift
consuming func withContents<R: ~Copyable>(
    _ body: (sending ResponseHeaderRegistry, consuming Base) async throws -> R
) async throws -> R
```

`takeBase()` folds into it. Folding rather than keeping both is the safer shape: a linear registry must be
accounted for by *someone*, and a surviving `takeBase()` would let a caller drop it silently.

Both construction sites wrap: `RequestContextCourier.swift:100` and
`WireMVCServerTransport.swift:339` — note the second builds its courier **inside an unstructured
`Task`**, which is fine (the registry is constructed there, so it is disconnected at birth) but is worth
re-checking after the change rather than assuming.

### 3. The front layer takes it out and puts it back

`GlobalMiddlewareHandler.handle` reads the registry, builds its box with it, runs the chain, and its
terminal calls `inner.handle(request:requestContext:reader:responseSender:)` — passing the **courier**
onward, because it pins `Inner.RequestContext == RequestContext`.

With a linear registry it must instead destructure the courier into (registry, base), build the box owning
the registry, and then — in the terminal, from the box's own destructure — **reconstruct** a courier from
base + registry to hand to `inner.handle`. One re-wrap per request.

This is the step most likely to be fiddly, because it is where a value has to make a round trip through two
`~Copyable` containers without either being partially consumed on a throwing path.

### 4. The box owns it and exposes mutating access

`RequestResponseMiddlewareBox.Storage` already carries `responseHeaders` in both cases; those become owned
linear values, which the enum being `~Copyable` already permits.

`public var responseHeaders: ResponseHeaderRegistry { get }` cannot survive. Replace it with mutating
methods on the box:

```swift
public mutating func contribute(_ contribution: ResponseHeaderContribution)
public mutating func onSendResponseHeaders(_ contribute: @escaping () async throws -> [ResponseHeaderContribution])
```

Both must work in **both** storage states — a gate responding must not destroy contributions for an
always-run observer further in, which is a property the current box has and the rewrite must preserve.
`intercept` receives `input` as `consuming`, so a middleware binds `var input = input` and calls these.

`withPendingContents` and `withContents` gain a `sending ResponseHeaderRegistry` in their closure
parameters, so a terminal receives the registry **from the destructure** rather than from a captured local.
That threading *is* the fix — it is what makes the wrapper's two inputs both disconnected.

`respondingWith` already consumes the box, so it owns the registry and needs no other change.

### 5. `ResponseHeaderApplyingSender` owns the registry

`let registry: ResponseHeaderRegistry` (`RequestContextCourier.swift:162-173`) becomes an owned linear
stored property, and `init(wrapping:registry:)` takes it `consuming sending`. `applying(to:)` stays
`borrowing` since `drain(into:)` only reads.

Watch the `consuming` methods: `send(_:)` and `sendAndFinish(_:buffer:trailer:)` do `let inner = consume
self.base`, which becomes a *partial* consumption of a struct with two noncopyable fields. Legal without a
`deinit`, which this type does not have — but it is the sort of thing that compiles in one method and not
in the next, so do it early rather than last.

### 6. Codegen threads it instead of capturing it

Every emitter that writes `let … = requestContext.responseHeaders` changes to the destructure, and the
registry is then threaded to whoever consumes it — the box when there is one, the outcome or the wrapper
when there is not:

- `RouteCodegen.swift:460` (typed, no middleware), `:480-481` (box construction), `:486` (typed terminal,
  which already reads the registry **off the box** — that path is closest to the target shape already)
- `RawRouteCodegen.swift:53` (raw, no middleware), `:167` (`@NotFound`)
- `BootstrapGeneration.swift:301-302` (introspection mount), `:419` (synthesised 404), `:453` (405)

The linchpin is the raw-route-with-middleware path: the wrapper must be built from the registry the box
hands back, not from the closure's captured local. Everything else in this plan exists to make that line
expressible.

### 7. `wire-open-api` follows, across a pin

Not confined to wire-mvc. `WireOpenAPIGen/DirectDispatchEmission.swift` emits the same shapes — `:197` and
`:205` read `requestContext.responseHeaders`, `:208` hands it to a box, `:138` hands it to
`ResponseHeaderApplyingSender` — and `:244` constrains on `ResponseHeaderCarrying`, the protocol step 2
changes.

So this is a source-breaking change across a repository boundary. Order: wire-mvc → wire-open-api → move
the pin → wire-mvc-examples. The examples repo is the only place all of it is compiled together, which is
also where the acceptance test belongs.

## The public break, stated plainly

Middleware today write `input.responseHeaders.add(.set(…))`, and that works *only* because a class
reference mutates through a borrow. After step 4 every such call site changes. In these repositories that
is `CORSMiddleware.swift:82`, the examples' `LogRequests` / `AuditGate` / `RequireAPIKey` /
`ResponseDefaults` / `ServeStaticFiles`, and the fixtures. Outside them it is every middleware anyone has
written.

This is the honest cost of the plan and the main reason it ranks second. The upstream annotation breaks
nothing.

## Verification

The acceptance test does not exist today, which is how the constraint went unnoticed: add a fixture raw
route declaring `consuming sending Sender`, **both** with and without a middleware fold. It must compile.
Nothing in `Fixtures` currently spells `sending` on a sender, and `notFoundHandlerRegistersAsFallback`
spells it only in a string it never compiles — correct that test at the same time, since it becomes true.

The regression net already exists and should stay green untouched: the suites that pin contributions
reaching raw routes, the authored fallback, the synthesised 404 and the 405 are exactly the paths this
rewrite moves ownership through. `WireMVCFallbackExample` matters most — it is the fixture whose whole
point is the synthesised 404 nobody declares.

Measure afterwards rather than assuming: a linear struct registry should remove **one heap allocation per
request** against today's class, which is Phase 5 territory in swift-wire's
[`RemainingSurfaceWork.md`](https://github.com/tachyonics/swift-wire/blob/main/Documentation/Notes/RemainingSurfaceWork.md). If
it does, this plan has a second payoff that the upstream annotation does not, and that may change the
ranking — but only if measured, and the `.deferred` closure box and the `overflow` array are still there to
allocate when used.

## Abandon criteria

- **Upstream accepts `consuming sending RequestContext`.** Delete this note; today's code reaches the same
  parity with no redesign and nothing breaking.
- **The round trip in step 3 does not typecheck cleanly.** If the courier cannot be rebuilt without an
  `unsafe` escape hatch, stop — the plan's whole claim is that it restores a *checked* property, and one
  that needs laundering to work is the unsound version wearing a hat.

## What it does not buy

The request context itself stays task-isolated. This plan launders exactly one value out of it. Anything
else that later needs to travel in the context and reach a `sending` position — a connection-info
capability, say — faces the same problem again and does not inherit a solution from this.
