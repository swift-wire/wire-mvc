# Extensible bindings and response modes — a design note

> **Status:** design only (2026-08-12). Nothing here is built. The goal is that `@FormBody`, `@YamlBody`,
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

## Request side: what a binding must declare

Two facts beyond its own name:

- **that it is a binding** — recognition, replacing the closed set.
- **whether it wants the collected request body** — replacing the `== "JSONBody"` test.

Sketch, to be checked against the compiler before it is believed:

```swift
@RequestBinding(wire: .body)          // read by the plugin off this declaration
public struct FormBody<Value: Decodable & Sendable>: RequestBound { … }
```

**`@Path` is the one that resists.** The codegen validates it against the route's `{name}` placeholders
(`pathPlaceholderMissing`), which no other binding gets. Generalising that means a third metadata fact — "this
binding names a path placeholder" — and a validation hook to go with it. **Recommendation: leave `@Path`
privileged.** One special case with a good diagnostic beats a general mechanism whose only client is that
special case. Generalise `@Query`, `@Header` and `@JSONBody`, which need nothing but the two facts above.

## Response side: smaller, because of what `@HTMLResponse` turned out to be

After the streaming tier there are exactly **two terminals** — buffered (`WireMVCOutcome`) and streaming
(`WireMVCStreamingOutcome`). Every response mode is a pair: which terminal, and what wraps the handler's
return.

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

The server side needs to know *that* a binding reads the body. The typed client needs to know **where on the
wire the value goes**, because it constructs the request: a path segment, a query item, a header, or the body.
That is strictly more metadata, and it is what decides whether the seam is "declare two booleans" or "declare a
wire position." **Settle this first; it sets the shape of everything else.** The sketch above spells it
`wire: .body` for that reason.

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

1. **Fix the dropped HTML client.** A defect, independent of this design, and the fixtures should have caught
   it — no test asserts that every annotated route appears in its controller's client.
2. **Settle the wire-position vocabulary**, since it constrains the metadata shape.
3. **Open the request side** — recognition and body collection off declaration metadata. Emission is already
   generic, so this is smaller than it sounds.
4. **Open the response side** — the (terminal, wrapper, default content type) triple.
5. **Write `@FormBody` in wire-mvc-examples**, not here. Demonstrating the seam is the point; a `@FormBody`
   inside WireMVC would prove nothing about whether the seam works, and this note exists because the last
   claim that the seam worked was never tested.

## What this is not

Not a plugin architecture. The mechanism is "the plugin already parses the declaring module, so put the facts
on the declaration" — no registry, no runtime discovery, no dynamic dispatch. The generated code stays exactly
as concrete as it is today; only the *decision* about what to generate stops being a hardcoded name test.
