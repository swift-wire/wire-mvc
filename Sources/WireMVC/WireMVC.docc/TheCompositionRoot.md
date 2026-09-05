# The composition root

`@WireMVCBootstrap` and the program entry point generated from it.

## Overview

You do not write `@main`. A composition root carrying `@WireMVCBootstrap` is a graph binding like
any other, and the build plugin generates the entry point from it.

```swift
@Singleton
@WireMVCBootstrap
@Middleware(GlobalMiddleware.cors)
struct AppBootstrap {
    @Inject let config: ServerConfig

    /// Optional. Runs *before* the graph exists; its return value is the graph's inputs.
    static func prepare() throws -> AppInputs {
        LoggingSystem.bootstrap { StreamLogHandler.standardOutput(label: $0) }
        return AppInputs(config: ConfigReader(providers: [EnvironmentVariablesProvider()]))
    }

    func createServer() throws -> NIOHTTPServer { … }
    func createRouteBuilder<Server: HTTPServer>(for server: borrowing Server) -> some … { … }

    /// Optional: mount the graph's own wiring as JSON. Returning `nil` skips it.
    func mountIntrospectionAt() -> String? { "/wiring" }

    /// Optional: the app's own fallback. Without one, a plain 404 is synthesised.
    @NotFound @RawRoute
    func noRoute<Sender: HTTPResponseSender & ~Copyable>(
        request: HTTPRequest, responseSender: consuming sending Sender
    ) async throws { … }
}
```

`@Singleton` is required — it is what makes the type a graph binding, exactly as it does for a
controller.

## The two required factories

`createServer()` and `createRouteBuilder(for:)` are what make this a *composition root* rather
than a configuration struct: the concrete server and route builder are the application's choice,
written by the application and constructed with the graph's own dependencies.

`createServer()` returns the concrete server type rather than `some HTTPServer`, because the
proposal's reader and sender types are non-copyable, which a bare opaque return cannot express.

## What the generated entry point does

In order, and worth reading once because the rest follows from it:

1. Calls `prepare()` if present, passing its result to the graph bootstrap.
2. Reads the composition root off the graph and asks it for the server and route builder.
3. Registers every collated route contributor, and collects the graph's background services.
4. Mounts introspection, if `mountIntrospectionAt()` returned a path.
5. Registers the `@NotFound` fallback — or a synthesised `404` — and a `405` handler, **before**
   finalising.
6. Finalises the builder into an immutable router, wraps it once in the global middleware layer,
   and serves it alongside the services.

Step 5 is the one worth pausing on. A fallback is the response nobody declares, and therefore the
easiest place to lose the header fields a global middleware contributed. Registering it as a real
route rather than as a special case is what stops that being a per-application mistake.

## The pre-graph step

`prepare()` exists for work that has to happen before any binding is constructed, and it is the
only place that work can go. Bootstrapping the logging system is the motivating case: it traps on
a second call, and the unbound default logger is captured at first access, so bootstrapping
*after* the graph is built leaves every binding constructed so far holding a logger that ignores
the configuration.

Being pre-graph, `prepare()` can inject nothing. That is the trade for running first, and it is
why it reads the environment directly there and nowhere else. Its return type is a swift-wire
`@GraphInputs` struct — values supplied to the graph rather than produced by it, declared in your
application because a library cannot decide what its consumers must pass in.

## Background services

A type with a `run()` loop is not a route and not a teardown case. Mark it `@BackgroundService`
and the graph collates it into the services the generated entry point serves alongside the
router:

```swift
@Singleton
@BackgroundService
final class QueueWorker: Service { … }
```

It is sugar for contributing to the services key, and it expands to nothing, so it goes on either
producer form — a service type, or a `@Provides` function returning one. The annotated or
returned type must conform to `Service` itself; the marker does not add the conformance.

## Not using the generated entry point

An application that is not WireMVC-shaped throughout — one that writes its own routes on a host
framework, or is not an HTTP program at all — bootstraps the graph itself and mounts through the
adapter's facade instead. Nothing about the graph differs between the two forms; the generated
entry point is a convenience over exactly that, not a different mechanism.
