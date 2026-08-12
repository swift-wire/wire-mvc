# Extensible bindings and response modes — a design note

> **Status:** design settled, nothing built (2026-08-12). The goal is that `@FormBody`, `@YamlBody`,
> `@YamlResponse` and their like are written *outside* WireMVC, against a documented seam — with the
> built-ins (`@Path`, `@Query`, `@Header`, `@JSONBody`, `@JSONResponse`, `@HTMLResponse`) becoming instances
> of that seam rather than privileged names.
>
> **It corrects a claim this repo has been repeating.** The earlier assessment — "`RequestBound` is public
> and user-extensible, so a `@FormBody` is writable without touching WireMVC" — is false. The *runtime*
> protocol is extensible; the *codegen* is not. A user's `@FormBody` today is diagnosed as
> `needs a binding annotation — one of @Path, @Query, @JSONBody, @Header`.
>
> It also recorded a **defect in the shipped `@HTMLResponse`** — HTML routes were silently dropped from the
> generated typed client. **Fixed 2026-08-12**, ahead of this design; see *The client is the constraint*.

## Where the seam actually stops

Four hardcodes, all verified against the current source. The first is the good news.

**1. Binding emission is already fully generic** (`RouteCodegen.swift:556`):

```swift
return "try await \(binding.wrapper)<\(type)>.bind(\(args))"
```

The wrapper name is interpolated. `Path<Int>.bind(…)`, `JSONBody<Login>.bind(…)` — one shape, no per-wrapper
code. `RequestBound` already unified the runtime, and the emitter already treats every binding alike. **A new
binding needs no emission change at all**, which is why this is worth doing: most of it is done.

**2. Recognition is a closed set** (`RouteCodegen.swift:692`):

```swift
let routeBindingWrappers: Set<String> = ["Path", "Query", "JSONBody", "Header"]
```

**3. Body collection is hardcoded to one name** (`RouteCodegen.swift:638`):

```swift
if let binding = binding(from: param.attributes), binding.wrapper == "JSONBody" {
```

That decides whether `let requestBody = try await WireMVCRequest.collectBody(reader)` appears. So even if a
`@FormBody` were recognised, it would be handed `body: nil`.

**4. The typed client hardcodes wire position and response codec**
(`ControllerClientGeneration.swift:120-141`): it filters parameters by `$0.wrapper == "Header"` to build
`headers:`, by `"JSONBody"` to build `json:`, and decodes every response with
`wireMVCResponse.json(T.self)`.

## The objection that turned out not to apply

The obvious blocker is that codegen is **syntactic and cross-module**: it sees `@FormBody input: Login` as
text, in a different module from where `FormBody` is declared, and cannot ask whether `FormBody: RequestBound`.

That is not a constraint here. The build plugin **already re-parses Wire-aware dependency modules**
(`WireMVCBuildPlugin.swift:33,59`), gated on the `_WireExports.swift` marker — the same mechanism that lets a
consumer's graph compose a dependency's `@Controller`s. So the codegen sees the *declaration* of a user's
binding as well as its use.

That single fact is what makes both extension points tractable with machinery that already ships: **the
metadata can live on the declaration, and the plugin can read it.**

A consequence worth noting, because it inverts the usual trade: declaration-based recognition *improves*
diagnostics rather than costing them. Convention-based recognition ("any unrecognised parameter attribute is a
binding") cannot distinguish a `@FormBody` from a typo'd `@Pth` — it would turn today's clear message into a
type error further from the cause. Reading declarations keeps the distinction: found means binding, absent
means the same error as today.

## Request side: a reverse bind, and two obligations

Two questions were riding on the word "position", and separating them is what made this converge.

**1. Where does the value go on the wire?** Answered by a **reverse bind** — the mirror of `RequestBound.bind`.
The server turns a request into a value; the client turns a value into a request. The binding writes itself
into the request under construction, in code the compiler checks, rather than declaring a position in text
that can drift from what it does.

```swift
public protocol RequestSendable: RequestBound {
    static func send(
        name: String, value: Value,
        into request: inout WireMVCOutgoingRequest,   // path, query, headers — no body slot
        coding: WireMVCCoding
    ) throws
}

public protocol RequestBodySendable: RequestBound {
    /// Contributes the request body, and may write path/query/header entries alongside it.
    static func sendBody(
        name: String, value: Value,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String)
}
```

Both take `name`, because `@Query("q") searchTerm` binds a wire name that is not the parameter name. Both take
`coding`, because `Coding.swift:15` already records why: *"a date is not only a JSON concern: it appears in a
`@Header` and a `@Query` too, where there is no encoder to configure."* A `@Query since: Date` must serialise
through the same transcoder it parsed with, or client and server disagree about date format.

Sibling protocols rather than new requirements on `RequestBound`, per that file's own rule
(`RequestBinding.swift:35`): adding a requirement would break every conformance outside this package. A binding
that cannot be sent simply does not conform, and its route gets **no typed client method — diagnosed, not
silently dropped**, which is the failure the client fix was about.

**Why two protocols rather than one method with a body slot.** A single `send` writing into a shared
`request.setBody(…)` makes "at most one binding supplies the body" a *rule needing enforcement* — two writes,
second silently overwriting the first. Split, it is **structurally impossible**: `WireMVCOutgoingRequest` has
no body field, and the codegen asks exactly one binding for a body. `RequestBodySendable` still takes
`request: inout`, so a binding needing a body *and* a digest header does both in one call. Nothing is given up
for the guarantee.

**2. What must the code generator do differently?** Exactly two things exist, and neither is inferable from a
function body the generator cannot read. They go on an attribute — matching every other recognition in this
toolchain, all of which key off attributes (`@Controller`, `@Scoped`, `@Singleton`, `@Factory`); nothing here
reads inheritance clauses today.

```swift
@RequestBinding(.body)   // emit collectBody; this parameter is the request body
@RequestBinding(.path)   // validate {name} against the route template
@RequestBinding          // neither
```

These are **codegen obligations, not positions**. The client learns nothing from them — the reverse bind tells
it everything. Recognition needs no flag at all: finding the declaration *is* recognition, which keeps today's
clear diagnostic for a typo'd `@Pth` rather than degrading it into a type error further from the cause.

`.body` is **compiler-checked**: it makes the codegen emit `sendBody`, which only type-checks if the binding
really conforms to `RequestBodySendable`. So a declaration that lies about being a body binding fails to build.
`.path` has no conformance to check against, but a mis-declared one only produces a spurious placeholder
diagnostic, which is harmless.

**`@Path` is not special-cased.** An earlier draft of this note said to leave it privileged, on the grounds
that only it is validated against the route's `{name}` placeholders (`RouteCodegen.swift:521`). That check is
just the `.path` obligation, so `@Path` becomes an ordinary binding carrying an ordinary flag. Two intermediate
drafts got this wrong in both directions — first privileging it, then generalising it via a position enum that
no longer exists — because "position" was doing two jobs.

A second diagnostic falls out for free: the codegen counts `.body` parameters and rejects two on one route.
A request has one body, and nothing says so today.

## Response side: smaller, because of what `@HTMLResponse` turned out to be

After the streaming tier there are exactly **two terminals** — buffered (`WireMVCOutcome`) and streaming
(`WireMVCStreamingOutcome`). Every response mode is a **pair**: which terminal, and what wraps the handler's
return.

A pair, not a triple. An earlier draft added a third field for the default content type, because the two
shipped modes set it in two different places — `WireMVCOutcome.json` seeds `application/json` internally,
while the codegen seeded `text/html` as a `.setIfAbsent` static contribution. That was an accident of how each
was built, not a design: **a content type belongs to the codec**, and the wrapper is the thing that knows the
bytes are HTML. `RequestBodySendable.sendBody` already returns `(bytes, contentType)` together for exactly
that reason; the request side settled this question first.

So `WireMVCBodyProducer` carries `contentType`, seeded by the terminal only when the route named none — which
keeps a route's own `@ResponseHeader(.contentType, …)` winning, as the static header tier gave it before. The
codegen names no content type at all now, and could not have served a mode it does not know by name while it
did.

| mode | terminal | wrapper |
| --- | --- | --- |
| `@JSONResponse` | buffered | `WireMVCResponse.json` |
| `@HTMLResponse` | streaming | `WireMVCHTMLProducer` |
| `@YamlResponse` (hypothetical) | buffered | `WireMVCResponse.yaml` |

That is the entire extension point on this side. It is small *because* `@HTMLResponse` shipped as a second
**terminal** rather than a second codec — had it been buffered like JSON, the streaming tier would still be
unbuilt and this table would have one column and no seam.

A mode declares its pair; `ResponseCodegen` stops switching on annotation names and looks the pair up. The
content-type seeding `@HTMLResponse` does (a `.setIfAbsent` static, first in the tier list) generalises
cleanly as a third field: the default content type, or none.

## The client is the constraint — and a defect

The client was the reason this design took several passes: it constructs a request, so it needs to know where
each value goes, which looked like metadata the server never needs. The reverse bind above dissolves that — the
binding places itself — but the client remains the constraint in one respect: it needs a generalised
`routeResponse(…, body:contentType:)` overload to replace today's `json: some Encodable` special case
(`TypedRouteClient.swift:192`), which bakes position and codec together and is why a `@FormBody` has nowhere to
put its payload.

The response half of the client is worse than under-general — it is **wrong today**
(`ControllerClientGeneration.swift:264-269`):

```swift
if hasAttribute("JSONResponse", on: function.attributes) {
    guard returnsValue else { return nil }
} else if hasAttribute("ResponseStatus", on: function.attributes) {
    guard !returnsValue else { return nil }
} else if !selfDescribing {
    return nil          // ← an @HTMLResponse route lands here
}
```

An `@HTMLResponse` route matched none of the branches and was **dropped from the typed client with no
diagnostic**. That shipped. The comment eight lines above it says silently dropping a route "is the same
failure the tuple projection was added to fix", so the codebase already held this to be a bug — and the
`@HTMLResponse` work reintroduced it by adding a fourth response mode to a three-way test.

**Fixed.** `ClientRoute` gained an `isHTML` flag and the method returns the rendered markup as a `String`,
which is what a test wants to assert on — there is no type to decode into, the handler's return being an
opaque `some HTML` the client could not name. The `guard` for a non-2xx is unchanged, so an HTML route obeys
the same rule as every other typed method.

The check that was missing matters more than the case: **nothing asserted that every annotated route appears
in its controller's client.** `noRouteIsSilentlyDropped` now does, over all four response modes at once, and
fails for any future mode that forgets to admit itself. That is the test this design needs in place before it
starts adding modes.

`wireMVCResponse.json(T.self)` (`:141`) remains the same hardcode one layer down — a `@YamlResponse` route's
client would JSON-decode a YAML body. That one is this design's to fix, not a defect in shipped behaviour.

## Order of work

1. ~~Fix the dropped HTML client.~~ **Done** (2026-08-12). The lasting part is not the fix but
   `noRouteIsSilentlyDropped`, which asserts every annotated route reaches its client. This design adds
   response modes and binding kinds; that test is what stops the next one going missing the same way.
2. ~~Settle the wire vocabulary.~~ **Done** — the reverse bind plus two obligation flags, above. Prototype the
   attribute-reading path against the compiler before building on it; every design decision in this repo that
   was reasoned rather than compiled has needed correcting.
3. ~~Open the request side.~~ **Server half done.** Recognition, `.body` (body collection) and `.path`
   (placeholder validation) all come off declaration metadata; emission was already generic. What remains is
   the *client* half — the reverse bind plus a generalised `body:contentType:` overload — without which a
   user binding cannot appear in a generated request.
4. **Open the response side** — the (terminal, wrapper) pair, read off the mode's *macro* declaration.
   Verified viable: a macro declaration accepts a custom attribute, and `MacroDeclSyntax.attributes` exposes
   it with labelled arguments intact, so the same declaration-scanning mechanism serves both sides. The
   content-type half is already done — the producer supplies its own.
5. **Write `@FormBody` in wire-mvc-examples**, not here. Demonstrating the seam is the point; a `@FormBody`
   inside WireMVC would prove nothing about whether the seam works, and this note exists because the last
   claim that the seam worked was never tested.

## What this is not

Not a runtime-checked design. Where an invariant can be made structurally impossible it is — the request
carries no body slot, so two bindings cannot both fill one — rather than made possible and then guarded. An
earlier draft proposed a `precondition` on `setBody`; it was removed by changing the shape so the case cannot
arise. A check that defends an invariant the types could have enforced is a design smell, not diligence.

Not a plugin architecture. The mechanism is "the plugin already parses the declaring module, so put the facts
on the declaration" — no registry, no runtime discovery, no dynamic dispatch. The generated code stays exactly
as concrete as it is today; only the *decision* about what to generate stops being a hardcoded name test.
