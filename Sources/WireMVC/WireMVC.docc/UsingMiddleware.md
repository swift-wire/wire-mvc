# Using middleware

One annotation, three scopes, and the two ways to name what it folds.

## Overview

`@Middleware` wraps a route — or every route on a controller, or every route in the application —
in a middleware resolved from the graph. The middleware runs before the handler and can transform
the box it receives, enriching the request context or replacing the reader or sender.

Scope is set by **placement**, and nesting runs outside-in:

```
global (composition root) → controller → route → handler
```

That is the same rule `@ErrorResponse`, `@ResponseHeader` and `@Coding` follow, for the same
reason: a policy is usually scope-wide and occasionally not.

## Naming what to fold

```swift
@Middleware(RequestLogging.self)      // by type
@Middleware(Sessions.middleware)      // by @Factory key
```

The by-type form folds the binding for `RequestLogging` directly. It is the right form for a
middleware that has dependencies but no generic parameters of its own.

The keyed form exists for a middleware that is **generic with dependencies**, which the by-type
form cannot express: the middleware's own generic parameters have to be filled in with the box's
types at the point it is folded, and those are not known where the binding is declared.

## Generic middleware

Such a middleware is a swift-wire `@Factory` template — a type whose `@Inject` members come from the
graph and whose generic parameters are supplied per use site. `@MiddlewareFactory` says which of
those generic parameters fill which **box role**:

```swift
extension Sessions {
    static let middleware = FactoryKey()
}

@Factory(Sessions.middleware)
@MiddlewareFactory
struct SessionMiddleware<Ctx, Reader, Sender>: Middleware where … {
    @Inject var store: SessionStore
}
```

Bare `@MiddlewareFactory` maps the assisted parameters positionally to `RequestContext`, `Reader`
and `ResponseSender` — the common `<Ctx, Reader, Sender>` case. The explicit form,
`@MiddlewareFactory(.requestContext, .responseSender)`, maps them by the listed roles instead,
for a middleware that reorders or pins one.

WireMVC supplies those role names; swift-wire reads them as opaque ordered identifiers and never
learns what a request context is. That is the adapter contract doing its job — the roles stay in
the adapter that has an opinion about them.

## How it reaches the route

`@Middleware` declares swift-wire's `.injectsFromGraph` capability, so the plugin lifts what the
annotation names onto the controller's **route-contributor proxy** rather than onto the
controller. The route codegen then folds the matching proxy field.

That is why a controller carrying middleware stays an ordinary binding: the proxy holds the
factories, and the controller holds only its own dependencies. See <doc:WritingAController>.

## Global middleware

On the composition root, `@Middleware` wraps the finished router once — a front layer around
every route *and* the fallback. The generated entry point registers the fallback as a real route
before finalising precisely so that this layer folds into it too, which is what stops a
`404` response from quietly missing the header fields every other response carries.

The mechanism is the proxy machinery again, with no contribution: the root gets a generated
global-middleware proxy holding its factories, and the generated `@main` reads it. See
<doc:TheCompositionRoot>.
