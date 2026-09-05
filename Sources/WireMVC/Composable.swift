// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import ServiceLifecycle
public import Wire

/// The surface a facade consumes — the graph's collated controllers (as route contributors) and its
/// app-scoped `ServiceLifecycle` services. Wire emits this conformance on the generated graph, mapping
/// each member to its `CollectedKey`'s product (see `wireMVCComposition`). The two members are
/// independent: a graph with controllers but no services (or vice versa) still conforms, the absent
/// member resolving to an empty collection.
public protocol WireMVCComposable {
    var routeContributors: [any RouteContributor] { get }
    var services: [any Service] { get }
}

/// Tells Wire to emit `extension _WireGraph: WireMVCComposable`, mapping each member to its
/// `CollectedKey`'s product — `routeContributors` (from `@Controller`) and `services` (from
/// `@BackgroundService` / `@Contributes(to: WireMVCKeys.services)`).
public let wireMVCComposition = WireGraphConformanceV1(
    conformsTo: (any WireMVCComposable).self,
    members: [
        .init("routeContributors", from: WireMVCKeys.routeContributors),
        .init("services", from: WireMVCKeys.services),
    ]
)

public enum WireMVC {
    /// Register the graph's collated controllers onto a route builder — any
    /// `HTTPServerRouteBuilder` (a router, an adapter's builder) — and return the graph's collated
    /// app-scoped `ServiceLifecycle` services to hand to the app's `ServiceGroup`. WireMVC stays router-agnostic,
    /// exactly as the old `apply` stayed transport-agnostic over `some ServerTransport`; the concrete
    /// builder — which is also the proposal's `HTTPServerRequestHandler`, so it can serve — is the
    /// caller's:
    ///
    /// ```swift
    /// let graph = try await Wire.bootstrap()
    /// var router = WireRouter(for: server)   // a concrete HTTPServerRouteBuilder + handler
    /// let services = try WireMVC.apply(graph, to: &router)
    /// try await server.serve(handler: router)  // run `services` in a ServiceGroup alongside serving
    /// ```
    ///
    /// The inverse (`~Copyable`) requirements are restated here because they don't propagate across
    /// the generic boundary on their own.
    @discardableResult
    public static func apply<Builder: HTTPServerRouteBuilder>(
        _ graph: some WireMVCComposable,
        to builder: inout Builder,
        coding: WireMVCCoding = .default
    ) throws -> [any Service]
    where
        Builder.RequestContext: ~Copyable & ResponseHeaderCarrying,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        for contributor in graph.routeContributors {
            try contributor.registerWireRoutes(on: &builder, coding: coding)
        }
        return graph.services
    }

    /// Register a `GET` endpoint serving the graph's wiring model (`introspect()`) as JSON onto a
    /// router (or any `HTTPServerRouteBuilder`). The model is encoded once, at mount time.
    public static func mountIntrospection<Builder: HTTPServerRouteBuilder>(
        for graph: some Introspectable,
        into builder: inout Builder,
        at path: String = "/wiring"
    ) throws
    where
        Builder.RequestContext: ~Copyable & ResponseHeaderCarrying,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        let outcome = try WireMVCResponse.json(graph.introspect(), status: .ok)
        builder.register(method: .get, path: path) { _, _, _, _, responseSender in
            try await outcome.send(on: responseSender)
        }
    }
}
