# Error handling

Mapping a thrown error to a response, at the scope the mapping belongs to.

## Overview

`@ErrorResponse` maps an error thrown by a route — from the handler, or from a request-scoped
binding built at scope entry — to a response. It sits at controller scope, covering every route,
or at route scope, covering one.

```swift
@Singleton
@Controller("/todos")
@ErrorResponse(TodoNotFound.self, .notFound)
struct TodosController {

    @Get("/{id}")
    @JSONResponse
    @ErrorResponse(Forbidden.self, .forbidden, { e in Problem(detail: e.reason) })
    func get(@Path id: String) async throws -> Todo { … }
}
```

Route entries are consulted before controller entries, so a route overrides its controller. The
annotation is a marker: the codegen folds the mapping into the generated terminal's `catch`.

## Three forms

- **`@ErrorResponse(E.self, .status)`** — for a thrown `E`, respond with that status. The
  ultralight case, and all a bodiless response can say.
- **`@ErrorResponse(E.self, .status, { e in Body(…) })`** — the closure's value is encoded as the
  JSON body of a response with that status.
- **`@ErrorResponse({ (e: E) in … })`** — an inline typed-parameter closure returning a full
  outcome, for a richer response. The parameter type must be annotated, and it is what selects
  the matched error type.

Which of the first two is right is not always the author's choice: an adapter reading an OpenAPI
document knows whether a status declares a body, and can require the matching form.

The closure is static by construction — there is no `self` — which is what lets one mapping cover
both a handler throw and a throwing request-scoped binding at scope entry.

## The order things are consulted

1. **Binding failures first.** A parameter that fails to decode is mapped by the built-in
   `WireMVCBindingError` rules, so a malformed body keeps its `415` or `422` rather than being
   swallowed by a catch-all.
2. **Route mappings**, then **controller mappings**, most specific error type first.
3. **The catch-all**, if declared — a form whose error type is `Swift.Error`. At most one per
   scope, and it must be the last error entry at its scope.
4. **The built-in `500`.**

WireMVC owns that last one deliberately. An escaped throw makes the server abort the connection
rather than synthesise a response, so leaving it unhandled would drop the request instead of
answering it.

## What is not supported yet

A named-function reference — `@ErrorResponse(SomeType.map)` — does not work. A reference to the
annotated controller's own method is a circular macro reference, since the compiler cannot
resolve the type mid-expansion, and a reference to a separate type needs cross-module signature
resolution the codegen does not do. Use an inline closure.

## Global mappings

An `@ErrorResponse` on the `@WireMVCBootstrap` composition root applies to every route in the
application, including the fallback. It is the same annotation meaning the same thing, with the
scope set by placement — as `@Middleware` and `@ResponseHeader` are. See
<doc:TheCompositionRoot>.
