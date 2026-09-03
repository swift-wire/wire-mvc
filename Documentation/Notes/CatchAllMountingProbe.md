# Catch-all mounting — a probe brief

> **Status:** proposed spike, not started. Belongs in the out-of-tree spike repository, the way the
> `ServerTransport` bridge and the duplex-route question were both answered before being built here —
> not in wire-mvc.

## The question

**Is WireMVC's per-request bridge closure separable from `ServerTransport.register`, such that a catch-all
route can be mounted through the host framework's own API while every other route stays on the bridge?**

Deliberately not "should WireMVC have native per-framework adapters". That is too large to answer in one
go, and answering it by argument is what this project keeps declining to do. This asks the narrow version:
whether the gap is closable at a **small seam** or only by forking the adapter. That is the actual fork in
the road, and it is measurable.

Also deliberately not a gate on *native* catch-all. The trie is WireMVC's own, and a catch-all edge there
waits on nothing — see `WireMVCRouter.md` item 3. This probe is about the bridged runtimes only, and
running it does not block, or depend on, building the native side.

## Why it matters — the category the gap belongs to

Two kinds of difference between the native runtime and the bridged ones, and they are not comparable:

**Convention alignment** — 405-vs-404, percent-decoding, trailing slash. Each runtime behaves the way its
own ecosystem expects. A Hummingbird user receiving Hummingbird's 404 is *correct*, and imposing WireMVC's
405 there would be the wrong kind of consistency. These are documented, pinned by tests in all three
runtimes, and are **not** a reason to build anything.

**Capability subtraction** — catch-all and the other wildcards, connection metadata, protocol upgrade,
non-`{name}` path syntax. The host can do these; routing through `ServerTransport` takes them away. WireMVC
makes the host *worse than it would be without WireMVC*. That is a design property rather than a
preference, it needs no adopter complaint to be real, and it grows every time a host gains a capability.

Catch-all is the cheapest concrete instance of the second kind — connection metadata is blocked upstream
and protocol upgrade is out of scope, while both hosts already have a direct target to translate onto:

- **Hummingbird** `RouterPath` has four wildcard forms — `*`, `*.jpg` (prefix), `file.*` (suffix), and
  `**` (recursive).
- **Vapor** `RoutingKit` has `.catchall`.

A WireMVC controller can express none of them on those runtimes.

## Why the probe is small

Both transports are thin. They parse the path into their own route type, convert the request into OpenAPI
currency types, call the handler, and convert back:

```swift
// OpenAPIHummingbird
self.on(.init(path), method: method) { request, context in
    let (openAPIRequest, openAPIRequestBody) = try request.makeOpenAPIRequest(context: context)
    let openAPIRequestMetadata = context.makeOpenAPIRequestMetadata()
    …
}

// OpenAPIVapor
self.routesBuilder.on(HTTPMethod(method), [PathComponent](path), body: .stream) { vaporRequest in
    let request = try HTTPTypes.HTTPRequest(vaporRequest)
    …
}
```

Only two things differ for a catch-all: how the route path is constructed, and where the matched remainder
lands in `ServerRequestMetadata`. Everything downstream of the handler closure — the middleware box, the
terminals, error tiers, response-header contributions — is untouched.

The conversion helpers are `internal` to each adapter, so the probe reimplements them. That looks like
~20 lines each; **measuring it is part of the point**, since "small" is the claim under test.

## What it builds

One spike directory. No codegen and no annotation — registration is hand-written, because the question is
about the mounting seam and not about the template surface.

1. A minimal route set: two ordinary routes plus one catch-all.
2. Ordinary routes mounted through `WireMVCServerTransport` exactly as today.
3. The catch-all mounted directly — `Router.on(RouterPath("/files/**"), method:)` and
   `routesBuilder.on(_, [.catchall])` — calling **the same WireMVC handler closure**.
4. Served over a real socket on both frameworks, driven with multi-segment paths.

Step 3 is where the answer lives, and it forces the refactor that reveals it.
`ServerTransportRouteBuilder.apply(to:)` currently builds that closure *inline* inside the `register` call.
The probe extracts it —

```swift
func makeHandler(_ route: Route)
    -> @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
```

— and mounts it two ways. If the extraction is clean, the seam exists.

## Success criteria

- The catch-all matches multi-segment paths on both frameworks.
- The remainder reaches the WireMVC handler under the name the template declared.
- Middleware, `@ResponseHeader` contributions and error tiers behave exactly as on a bridged route — the
  box and terminal machinery genuinely untouched.
- **A literal route still beats the catch-all** on both hosts. If their precedence differs from the native
  router's, that is convention divergence being inherited, and it must be known before a surface is
  designed. (It is also the other half of `WireMVCRouter.md`'s precedence item.)
- The framework-specific code is confined and small — tens of lines per framework, not a fork of `apply`.

## What a negative result looks like, and why it is equally useful

- `BridgeReader`/`BridgeResponseSender` having to be reimplemented against framework types.
- The catch-all needing a *different* handler signature, so codegen would have to know which runtime it is
  targeting.
- The remainder's naming or percent-decoding diverging in a way that cannot be reconciled.

Any of these means the seam does not exist, per-framework support implies a real adapter, and
`WireMVCRouter.md`'s item 3 option of *native-only with an explicit bridge refusal* becomes the honest
answer rather than a premature one.

## Out of scope, deliberately

- **The template surface.** Hummingbird has four wildcard forms and Vapor one, so a single `{path*}`
  convention can only be lossless against `**`. Worth *noting* what is unreachable; choosing a spelling
  comes after knowing the seam exists.
- **Connection metadata and protocol upgrade.** Same category, but each carries its own blocker, and one
  probe answering one question is the point.
