# Request scope

Controllers and bindings that live for one request, and what ends when the request does.

## Overview

A controller does not have to be a singleton. Seed it on the request instead and it is
constructed fresh per request, with the request itself injectable:

```swift
@Scoped(seed: HTTPRequest.self)
@Controller("/todos")
struct TodosController {
    @Inject var request: HTTPRequest        // the seed
    @Inject var repository: TodoRepository  // a singleton, injected across the boundary
    @Inject var logger: Logger              // request-scoped
}
```

Nothing else changes. The routes, bindings and response annotations are what they were; only the
lifetime differs.

## How a per-request controller is still collated once

Routes register once, at bootstrap, so the generated route-contributor proxy is app-scoped. A
request-scoped controller is therefore a **scope bridge**: the app-scoped proxy holds a scope
entry rather than the controller, and constructs the controller per request from the seed.

This is a sanctioned bridge rather than a cross-scope violation, and it is the reason the proxy
indirection exists at all — see <doc:WritingAController>. Each such controller is its own
per-request reachability root, so entering the scope constructs exactly that controller's
transitive request-scoped subgraph and nothing else.

## What you get in the scope

The seed, and anything else seeded on `HTTPRequest`. A request logger is the common case, and the
request-scoped binding a resolving parameter binding uses is another — see
<doc:RequestBindings>.

Singletons inject through unchanged. The boundary rule is swift-wire's: a scoped binding sees
singletons, a singleton does not see scoped bindings, and asking for one is a build error at the
injection site.

## Teardown

A request-scoped binding marked `@Teardown` has its action run when the request scope ends,
including when it ends by cancellation. A transaction that rolls back unless committed is the
canonical use:

```swift
@Scoped(seed: HTTPRequest.self)
struct RequestTransaction {
    @Teardown
    func finish() async throws { if !committed { try await rollback() } }
}
```

Actions run in reverse construction order, and a throwing action does not stop the ones after it.

## When to reach for it

Scope a controller to the request when it genuinely holds per-request state — a request logger,
an authenticated caller, a transaction. A controller whose dependencies are all singletons should
stay a singleton: it is constructed once instead of per request, and nothing about the routes
changes either way.
