// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

public import HTTPAPIs
import Logging
public import ServiceLifecycle

// Runtime support for the `@WireMVCBootstrap` composition root. The generated `@main`
// (emitted by `WireMVCRouteGen`) bootstraps the graph, constructs the `@WireMVCBootstrap`
// binding, applies the collated routes onto its route builder, and hands the server + builder
// + collated `ServiceLifecycle` services to `WireMVC.serve`, which serves the router and runs
// the services together until shutdown.

extension WireMVC {
    /// Serve `handler` on `server` while running the graph's collated app-scoped `services`. Serving
    /// runs in the task-group *body* (the current isolation — so the non-Sendable `server`/`handler`
    /// are used directly, never captured into a `@Sendable` child-task closure); only the `Sendable`
    /// `services` go into a child task. Returns when serving ends (or a service errors); with no
    /// services the child task completes immediately and serving keeps the process alive.
    public static func serve<Server: HTTPServer, Handler: HTTPServerRequestHandler>(
        on server: Server,
        handler: Handler,
        services: [any Service]
    ) async throws
    where
        Server.RequestContext: ~Copyable,
        Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable,
        Server.ResponseSender.Writer: ~Copyable,
        Handler.RequestContext == Server.RequestContext,
        Handler.Reader == Server.Reader,
        Handler.ResponseSender == Server.ResponseSender
    {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await Self.runServices(services) }
            try await server.serve(handler: handler)
            group.cancelAll()
        }
    }

    /// Run the graph's collated app-scoped services in a `ServiceGroup`. Returns immediately when
    /// there are none. Non-generic (`[any Service]`), so the caller stays free of service-typing.
    public static func runServices(_ services: [any Service]) async throws {
        guard !services.isEmpty else { return }
        let group = ServiceGroup(services: services, logger: Logger(label: "WireMVC"))
        try await group.run()
    }
}
