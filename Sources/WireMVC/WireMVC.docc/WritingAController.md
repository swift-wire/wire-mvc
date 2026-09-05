# Writing a controller

What `@Controller` reads, what it generates, and why the annotations expand to nothing.

## Overview

`@Controller` marks a type whose methods are routes. Each `@Get` / `@Post` / `@Put` / `@Patch` /
`@Delete` member becomes one registration on the route builder, under the controller's optional
path prefix.

```swift
@Singleton
@Controller("/todos")
struct TodosController {
    @Inject var repository: TodoRepository

    @Get("/{id}")
    @JSONResponse
    func get(@Path id: String) async throws -> Todo { try repository.find(id) }

    @Post
    @JSONResponse(status: .created)
    func create(@JSONBody new: NewTodo) async throws -> Todo { repository.insert(new) }

    @Delete("/{id}")
    @ResponseStatus(.noContent)
    func delete(@Path id: String) async throws { try repository.remove(id) }
}
```

The prefix is optional: `@Controller` with no argument leaves each verb annotation carrying the
full path, and a verb annotation with no argument routes the prefix itself.

## The annotations expand to nothing

This is worth stating plainly, because it explains most of WireMVC's behaviour. The verb,
parameter and response annotations are **markers**. They generate no code. `@Controller` reads
them off its own members at build time, and the code generator emits a separate witness type.

So there is no macro-expanded body inside your controller to step through, and a controller with
annotations on it is still an ordinary type you can construct and call directly in a unit test.

What the generator emits is one `transport.register` per route, and each does the same three
things in order: decode the parameters, call the handler, encode the response. `@RawRoute` is
the escape hatch that skips the first and third — see <doc:ResponsesAndHeaders>.

## What the controller contributes

A `@Controller` does not itself flow into the graph's route collection. The generator synthesises
a **proxy** — `_WireRouteContributor_<Controller>` — which conforms to ``RouteContributor``, and
that proxy is what contributes.

The indirection buys two things. The controller stays a plain, footgun-free binding: it holds
its own `@Inject` dependencies and nothing else, while the proxy holds any middleware factories
its routes demand. And because the proxy is app-scoped while the controller may not be, the
proxy can *bridge* into a narrower scope — which is what makes a request-scoped controller
possible at all. See <doc:RequestScope>.

You never name the proxy. It is generated in your module, and swift-wire collates it through the
same multibinding machinery a hand-written `@Contributes` uses.

## Path templates

A `{name}` segment is a placeholder bound by `@Path` — see <doc:RequestBindings>. Templates cross
the boundary to the host runtime as OpenAPI-style templates, which is why a catch-all
(`{name*}`) is available on the native router but refused by the Hummingbird and Vapor adapters.
That difference, and the others, are set out in <doc:WhatDiffersByRuntime>.

## Where a controller can live

Anywhere in the module graph the build plugin scans — a controller in a shared library composes
into a consumer's routes without that consumer restating anything. The one thing that must be
true is that the consuming target applies `WireMVCBuildPlugin`, since that is what generates the
witness.
