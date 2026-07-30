import SwiftParser
public import SwiftSyntax

// The generated program entry point for a `@WireMVCBootstrap` composition root. `WireMVCRouteGen`
// emits a top-level `@main` type into the consumer module (in `_WireRoutes.swift`, alongside the
// route-contributor extensions) that: bootstraps the graph, reads the `@WireMVCBootstrap` binding
// off it, builds the server + route builder from the type's factories, registers the collated routes
// via `WireMVC.apply`, and serves the router alongside the graph's collated services.
//
// M5.5 Phase 1: no global middleware/error tiers, no introspection mount, no synthetic fallback route
// (later phases). The `@main` is *generated*, not user-written; the composition root carries only
// `@Singleton @WireMVCBootstrap` (the `@Singleton` makes it a graph binding, as `@Singleton @Controller`
// does), and the factory methods.

/// The generated entry type name — the `@main` struct emitted into `_WireRoutes.swift`.
let bootstrapEntryTypeName = "_WireMVCBootstrapEntry"

/// The graph property a `@Singleton`-bound `typeName` is reachable under on the generated `_WireGraph`
/// — WireGen names each binding `lowerCamel(sanitize(type))` (`WireGenCore` `identifierName(forType:key:)`).
/// For a simple, non-generic type name that is the first character lowercased; this restates that
/// contract so the generated `@main` reads `graph.<property>`. (Matches WireGen for plain identifiers;
/// generic/qualified bootstrap names are out of Phase-1 scope.)
func graphBindingPropertyName(_ typeName: String) -> String {
    guard let first = typeName.first else { return typeName }
    return first.lowercased() + typeName.dropFirst()
}

/// Which server the build sequence constructs its route builder over — the *only* difference between the
/// two generated build paths. Everything downstream (the builder, `apply`, the registrations, `finalize()`,
/// the global-middleware wrap) is identical, so both paths exercise the app's real router, middleware fold,
/// error tiers and `@NotFound` fallback.
enum BootstrapTransport {
    /// The app's own `createServer()` — the `@main` and the live suite mode.
    case appServer
    /// `WireMVCTesting`'s in-memory ``InProcessServer`` — the `.inProcess` suite mode. The app's
    /// `createServer()` is never called, so its `ServerConfig` (host, port, TLS) does not apply.
    case inProcess

    /// The line binding the `server` local the route builder is created for.
    func serverLine(bootstrap: ControllerDeclaration) -> String {
        switch self {
        case .appServer:
            // `createServer` may throw (building a server configuration conventionally does), so the call
            // is prefixed with `try` when the declaration is `throws`.
            let createServerTry = functionThrows(named: "createServer", in: bootstrap) ? "try " : ""
            return "let server = \(createServerTry)bootstrap.createServer()"
        case .inProcess:
            return "let server = InProcessServer()"
        }
    }
}

/// The shared build sequence every generated entry inlines — graph → bootstrap → server → builder →
/// `apply` → registrations → `finalize()` → `wrapGlobalMiddleware`, producing the locals `server`,
/// `services`, and the opaque `~Copyable` `wireMVCServed` handler. The handler can't be returned or
/// stored (opaque `~Copyable`), so each entry inlines this and hands the locals straight to a generic
/// helper by inference — the `@main` to `WireMVC.serve`, the live suite mode to
/// `WireMVCTesting.serveForSuite`, the in-process mode to `WireMVCTesting.driveInProcess`.
func bootstrapBuildLines(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>,
    bootstrapCall: String = "Wire.bootstrap()",
    extraRegistrations: String = "",
    transport: BootstrapTransport = .appServer
) -> String {
    let property = graphBindingPropertyName(bootstrap.name)
    let proxyProperty = graphBindingPropertyName(globalMiddlewareProxyTypeName(bootstrap.name))
    let mountIntrospection = introspectionMount(
        bootstrap: bootstrap,
        factoryKeys: factoryKeys,
        proxyProperty: proxyProperty
    )
    // Pre-finalize registrations (introspection mount + `@NotFound` fallback + any keyed-harness variant-proxy
    // registrations), combined so an absent piece adds no blank line to the entry.
    let registrations = [mountIntrospection, notFoundRegistration, extraRegistrations]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    // The finalized router is wrapped once in the global-middleware front layer: the keyless proxy's
    // `wrapGlobalMiddleware` folds the Bootstrap's `@Middleware` factories around every request — matched
    // routes and the `@NotFound` fallback alike — or returns the router unchanged (identity) when there are
    // none. Always emitted, so the entries are uniform.
    return """
        let graph = try await \(bootstrapCall)
        let bootstrap = graph.\(property)
        \(transport.serverLine(bootstrap: bootstrap))
        var builder = bootstrap.createRouteBuilder(for: server)
        let services = try WireMVC.apply(graph, to: &builder)
        \(registrations)
        let handler = builder.finalize()
        let wireMVCServed = graph.\(proxyProperty).wrapGlobalMiddleware(handler)
        """
}

/// The `@main` entry source for the single `@WireMVCBootstrap` composition root. The build is inlined
/// (concrete opaque locals, so the compiler infers the server/handler generics without any explicit
/// threading); only the service run is factored into the non-generic `WireMVC.runServices`.
func renderBootstrapEntry(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>
) -> String {
    let buildLines = bootstrapBuildLines(
        bootstrap: bootstrap,
        notFoundRegistration: notFoundRegistration,
        factoryKeys: factoryKeys
    )
    let raw = """
        @main
        struct \(bootstrapEntryTypeName) {
            static func main() async throws {
                \(buildLines)
                try await WireMVC.serve(on: server, handler: wireMVCServed, services: services)
            }
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// The generated `.wiremvc(_:)` suite-trait factory for the `@WireMVCBootstrap` composition root — the one
/// public way to stand a suite up (`@Suite(.wiremvc(<mode>))`), emitted into the test module (module scope,
/// in place of the `@main`) as a `SuiteTrait` extension. Its `WireMVCSuiteTrait` closure inlines the SAME
/// build as the `@main` and, instead of serving forever, hands the locals to a `WireMVCTesting` driver. The
/// opaque `~Copyable` handler is a local inside the closure (it never escapes it) — exactly why the build
/// composes here. Inlining is forced by that handler (it can't be returned from a shared `buildApplication`),
/// so this duplicates the build the way the `@main` does — the string-building is the only thing shared,
/// via ``bootstrapBuildLines``. This is the keyless form: `.wiremvc()` serves the default/replaced graph.
func renderBootstrapTestEntry(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>
) -> String {
    let raw = """
        extension SuiteTrait where Self == WireMVCSuiteTrait {
            static func wiremvc(_ mode: WireMVCTestMode = .appServer) -> WireMVCSuiteTrait {
                WireMVCSuiteTrait { runTests in
        \(modeSwitch(
            bootstrap: bootstrap,
            notFoundRegistration: notFoundRegistration,
            factoryKeys: factoryKeys
        ))
                }
            }
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// The suite closure's body: one `case` per ``WireMVCTestMode``, each inlining its own build. The two builds
/// cannot be factored into a shared local — they produce *different* opaque `~Copyable` handler types, so
/// each branch must build and consume its handler in place. The driver call is the last line of each branch:
/// `driveInProcess` calls `handle` per request, `serveForSuite` serves on an ephemeral loopback port.
///
/// Both branches are always emitted, so a test consumer needs the app server's ``WireMVCTestServer``
/// conformance in scope (it imports the module supplying it) whichever mode its suites actually select —
/// `serveForSuite`'s bound is checked when the factory is type-checked, not when the case is reached.
func modeSwitch(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>,
    bootstrapCall: String = "Wire.bootstrap()",
    extraRegistrations: String = ""
) -> String {
    func build(_ transport: BootstrapTransport) -> String {
        bootstrapBuildLines(
            bootstrap: bootstrap,
            notFoundRegistration: notFoundRegistration,
            factoryKeys: factoryKeys,
            bootstrapCall: bootstrapCall,
            extraRegistrations: extraRegistrations,
            transport: transport
        )
    }
    // The drivers stay qualified on the `WireMVCTesting` enum — mirroring how the `@main` names `WireMVC`
    // types unqualified but calls `WireMVC.serve`. `runTests` is the trait's type-erasing hook: the closure
    // builds the app afresh each suite entry, so the opaque handler is a local that never escapes.
    return """
        switch mode {
        case .inProcess:
        \(build(.inProcess))
        try await WireMVCTesting.driveInProcess(handler: wireMVCServed, services: services, runTests: runTests)
        case .appServer:
        \(build(.appServer))
        try await WireMVCTesting.serveForSuite(on: server, handler: wireMVCServed, services: services, runTests: runTests)
        }
        """
}

/// The keyless global-middleware proxy type synthesised for a `@WireMVCBootstrap` root —
/// `_WireGlobalMiddleware_<name>`. The prefix is `wireMVCBootstrapAlias`'s `proxyTypePrefix`, so the
/// plugin-synthesised proxy binding and this tool's extension name the same type (mirrors
/// `ControllerDeclaration.proxyTypeName`'s relationship to `wireMVCControllerAlias`).
func globalMiddlewareProxyTypeName(_ bootstrapName: String) -> String {
    "_WireGlobalMiddleware_\(bootstrapName)"
}

/// The `extension _WireGlobalMiddleware_<Bootstrap>`: `wrapGlobalMiddleware<Handler>` (the front layer's
/// fold) always, plus `registerIntrospection<Builder>` when a `@Middleware`-guarded `mountIntrospectionAt` is
/// present. Both fold factories the plugin already lifted onto the proxy (the reattributed type-level *and*
/// method-level `@Middleware`), mirroring the controller proxy's `registerWireRoutes`. By-type/keyed
/// diagnostics ride out through `diagnostics`.
func renderGlobalMiddlewareProxyExtension(
    bootstrap: ControllerDeclaration,
    factoryKeys: Set<String>
) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
    let global = globalMiddlewareConstructions(bootstrap: bootstrap, factoryKeys: factoryKeys)
    let guardChain = introspectionGuardConstructions(bootstrap: bootstrap, factoryKeys: factoryKeys)
    var methods = [renderWrapGlobalMiddleware(access: bootstrap.access, constructions: global.constructions)]
    if !guardChain.constructions.isEmpty {
        methods.append(renderRegisterIntrospection(access: bootstrap.access, constructions: guardChain.constructions))
    }
    let raw = """
        extension \(globalMiddlewareProxyTypeName(bootstrap.name)) {
        \(methods.joined(separator: "\n\n"))
        }
        """
    return (Parser.parse(source: raw).formatted().description, global.diagnostics + guardChain.diagnostics)
}

/// `wrapGlobalMiddleware<Handler>` — folds the global `@Middleware` chain around the router via
/// `GlobalMiddlewareHandler`, or returns `inner` (identity) when there are none.
private func renderWrapGlobalMiddleware(access: String, constructions: [String]) -> String {
    let body =
        constructions.isEmpty
        ? "inner"
        : """
        GlobalMiddlewareHandler(inner: inner, chain: wireCompose {
        \(constructions.joined(separator: "\n"))
        })
        """
    return """
        \(access)func wrapGlobalMiddleware<Handler: HTTPServerRequestHandler>(_ inner: Handler)
        -> some HTTPServerRequestHandler<Handler.RequestContext, Handler.Reader, Handler.ResponseSender>
        where
            Handler.RequestContext: ~Copyable,
            Handler.Reader: ~Copyable,
            Handler.ResponseSender: ~Copyable,
            Handler.ResponseSender.Writer: ~Copyable
        {
            \(body)
        }
        """
}

/// `registerIntrospection<Builder>` — registers the introspection route (its precomputed JSON `response`)
/// with the `@Middleware`-guard chain folded around it, so only requests the guard passes reach the model.
/// Emitted only when `mountIntrospectionAt` carries a `@Middleware`.
private func renderRegisterIntrospection(access: String, constructions: [String]) -> String {
    """
    \(access)func registerIntrospection<Builder: HTTPServerRouteBuilder>(
        into builder: inout Builder,
        at path: String,
        response: WireMVCOutcome
    )
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    {
        builder.register(method: .get, path: path) { request, requestContext, _, reader, responseSender in
            let wireMVCBaseBox = RequestResponseMiddlewareBox.pending(request: request, requestContext: requestContext, reader: reader, responseSender: responseSender)
            let wireMVCChain = wireCompose {
            \(constructions.joined(separator: "\n"))
            }
            try await wireMVCChain.intercept(input: wireMVCBaseBox) { wireMVCFinalBox in
                try await wireMVCFinalBox.withPendingContents { _, _, _, responseSender in
                    try await response.send(on: responseSender)
                }
            }
        }
    }
    """
}

/// The `@main`'s introspection registration for a Bootstrap with `mountIntrospectionAt`: a `@Middleware`-guarded
/// path goes through the proxy's `registerIntrospection` (precomputing the model once), an unguarded one
/// through `WireMVC.mountIntrospection`. No `mountIntrospectionAt` → empty. Registered before `finalize()`,
/// so it's a real route the front layer wraps.
func introspectionMount(bootstrap: ControllerDeclaration, factoryKeys: Set<String>, proxyProperty: String) -> String {
    guard hasFunction(named: "mountIntrospectionAt", in: bootstrap) else { return "" }
    if introspectionGuardConstructions(bootstrap: bootstrap, factoryKeys: factoryKeys).constructions.isEmpty {
        return """
            if let wireMVCIntrospectionPath = bootstrap.mountIntrospectionAt() {
                try WireMVC.mountIntrospection(for: graph, into: &builder, at: wireMVCIntrospectionPath)
            }
            """
    }
    return """
        if let wireMVCIntrospectionPath = bootstrap.mountIntrospectionAt() {
            let wireMVCIntrospectionResponse = try WireMVCResponse.json(graph.introspect(), status: .ok)
            graph.\(proxyProperty).registerIntrospection(into: &builder, at: wireMVCIntrospectionPath, response: wireMVCIntrospectionResponse)
        }
        """
}

/// Global tier `@Middleware` fold-entries (type-level, over `Handler`) — see ``middlewareFactoryConstructions``.
func globalMiddlewareConstructions(
    bootstrap: ControllerDeclaration,
    factoryKeys: Set<String>
) -> (constructions: [String], diagnostics: [RouteCodegenDiagnostic]) {
    middlewareFactoryConstructions(from: bootstrap.attributes, factoryKeys: factoryKeys, boxRole: "Handler")
}

/// Introspection-guard `@Middleware` fold-entries — the `@Middleware` on the `mountIntrospectionAt` method,
/// folded over the route builder (`Builder`). Empty when there's no such method or it carries no `@Middleware`.
func introspectionGuardConstructions(
    bootstrap: ControllerDeclaration,
    factoryKeys: Set<String>
) -> (constructions: [String], diagnostics: [RouteCodegenDiagnostic]) {
    guard let method = bootstrap.functions.first(where: { $0.name.text == "mountIntrospectionAt" }) else {
        return ([], [])
    }
    return middlewareFactoryConstructions(from: method.attributes, factoryKeys: factoryKeys, boxRole: "Builder")
}

/// Read the `@Middleware` fold-entries from an attribute list. Only the **factory** form (`@Middleware(Key)`,
/// generic over the box) is valid on the `@WireMVCBootstrap` root — `self._wireFactory_<key>.create(
/// <boxRole>.RequestContext.self, …)` produces a middleware over the router's box, composing in the
/// non-transforming generic chain. A by-type `@Middleware(T.self)` or a keyed graph binding is a concrete
/// `Box<Fixed>` middleware that can't compose there, so it is diagnosed
/// (``WireMVCDiagnostic/globalMiddlewareUnsupportedArgument``). `boxRole` names the generic parameter the
/// consuming method exposes (`Handler` for `wrapGlobalMiddleware`, `Builder` for `registerIntrospection`).
func middlewareFactoryConstructions(
    from attributes: AttributeListSyntax,
    factoryKeys: Set<String>,
    boxRole: String
) -> (constructions: [String], diagnostics: [RouteCodegenDiagnostic]) {
    var constructions: [String] = []
    var diagnostics: [RouteCodegenDiagnostic] = []
    for case let .attribute(attr) in attributes
    where attr.attributeName.trimmedDescription == "Middleware" {
        guard
            let arguments = attr.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first
        else { continue }
        let expression = first.expression.trimmedDescription
        if factoryKeys.contains(expression) {
            constructions.append(
                "self.\(factoryPropertyName(forKey: expression)).create(\(boxRole).RequestContext.self, \(boxRole).Reader.self, \(boxRole).ResponseSender.self)"
            )
        } else {
            diagnostics.append(RouteCodegenDiagnostic(.globalMiddlewareUnsupportedArgument(expression), at: attr))
        }
    }
    return (constructions, diagnostics)
}

/// The `builder.registerNotFound { … }` for a `@WireMVCBootstrap`'s fallback (M5.5 Phase 4): the
/// `@NotFound` method rendered through the raw-route machinery (subject = the `@main`'s `bootstrap`
/// local), or a synthesised plain 404 when none is declared. The fallback is registered before
/// `finalize()`, so it's a real route the global tiers fold into. Any `@NotFound` diagnostics are
/// surfaced through `diagnostics`.
func renderNotFoundRegistration(
    bootstrap: ControllerDeclaration
) -> (registration: String, diagnostics: [RouteCodegenDiagnostic]) {
    let synth404 = """
        builder.registerNotFound { _, _, _, _, responseSender in
        try await responseSender.sendAndFinish(HTTPResponse(status: .notFound))
        }
        """
    guard let notFound = bootstrap.functions.first(where: hasNotFoundAttribute) else {
        return (synth404, [])
    }
    var generator = RouteBlockGenerator(subjectAccessor: "", factoryKeys: [], globalErrorMappings: [])
    guard let registration = generator.notFoundRegistration(function: notFound, subjectExpression: "bootstrap")
    else {
        return (synth404, generator.diagnostics)
    }
    return (registration, generator.diagnostics)
}

/// Whether a method carries `@NotFound`.
private func hasNotFoundAttribute(_ function: FunctionDeclSyntax) -> Bool {
    function.attributes.contains { attribute in
        if case let .attribute(attr) = attribute {
            return attr.attributeName.trimmedDescription == "NotFound"
        }
        return false
    }
}

/// Whether the named method on `declaration` is declared `throws` — so the generated entry mirrors the
/// factory's effect on its call.
private func functionThrows(named name: String, in declaration: ControllerDeclaration) -> Bool {
    for function in declaration.functions where function.name.text == name {
        return function.signature.effectSpecifiers?.throwsClause != nil
    }
    return false
}

/// Whether `declaration` declares a method with the given name — the Bootstrap's optional factory methods
/// (`mountIntrospectionAt`) are recognised by name, as `createServer`/`createRouteBuilder` are.
private func hasFunction(named name: String, in declaration: ControllerDeclaration) -> Bool {
    declaration.functions.contains { $0.name.text == name }
}

/// Every nominal type carrying `@WireMVCBootstrap` in a parsed file, as a `ControllerDeclaration` (the
/// shared decl model — reused for its name/access/method access). A `SyntaxVisitor` so a bootstrap
/// nested in an enclosing type is found too.
func bootstrapDeclarations(in sourceFile: SourceFileSyntax) -> [ControllerDeclaration] {
    let finder = BootstrapFinder()
    finder.walk(sourceFile)
    return finder.declarations
}

private final class BootstrapFinder: SyntaxVisitor {
    private(set) var declarations: [ControllerDeclaration] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node)
        return .visitChildren
    }

    private func record(_ declaration: some DeclSyntaxProtocol & DeclGroupSyntax) {
        let hasBootstrap = declaration.attributes.contains { attribute in
            if case let .attribute(attr) = attribute {
                return attr.attributeName.trimmedDescription == "WireMVCBootstrap"
            }
            return false
        }
        guard hasBootstrap, let bootstrap = ControllerDeclaration(declaration) else { return }
        declarations.append(bootstrap)
    }
}
