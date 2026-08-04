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

/// Which server the build sequence constructs its route builder over. The `@main` uses the app's own
/// `createServer()`; a suite uses the one its ``WireMVCTestMode`` carries, so the app's production server
/// configuration (TLS, bind interface, timeouts, HTTP/2, graceful shutdown) never has to be un-configured
/// for tests. It is the *only* line that differs — the builder, `apply`, the registrations, `finalize()`
/// and the global-middleware wrap are identical, so a suite exercises the app's real router, middleware
/// fold, error tiers and `@NotFound` fallback whichever transport it runs on.
enum BootstrapTransport {
    /// The app's own `createServer()` — the `@main`'s production entry.
    case appServer
    /// The server the suite's mode carries — every test transport, in-process and live alike.
    case suiteMode

    /// The line binding the `server` local the route builder is created for.
    func serverLine(bootstrap: ControllerDeclaration) -> String {
        switch self {
        case .appServer:
            // `createServer` may throw (building a server configuration conventionally does), so the call
            // is prefixed with `try` when the declaration is `throws`.
            let createServerTry = functionThrows(named: "createServer", in: bootstrap) ? "try " : ""
            return "let server = \(createServerTry)bootstrap.createServer()"
        case .suiteMode:
            return "let server = mode.makeTestServer()"
        }
    }
}

/// The shared build sequence every generated entry inlines — graph → bootstrap → server → builder →
/// `apply` → registrations → `finalize()` → `wrapGlobalMiddleware`, producing the locals `server`,
/// `wireMVCServices`, and the opaque `~Copyable` `wireMVCServed` handler. The handler can't be returned or
/// stored (opaque `~Copyable`), so each entry inlines this and hands the locals straight to a generic
/// helper by inference — the `@main` to `WireMVC.serve`, a suite to `WireMVCTesting.runSuite`.
func bootstrapBuildLines(
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>,
    bootstrapCall: String = "Wire.bootstrap()",
    extraRegistrations: String = "",
    transport: BootstrapTransport = .appServer,
    prologue: String = ""
) -> String {
    let property = graphBindingPropertyName(bootstrap.name)
    let proxyProperty = graphBindingPropertyName(globalMiddlewareProxyTypeName(bootstrap.name))
    // The app-wide tier. `@Coding` on the Bootstrap is lifted onto the same keyless proxy the global
    // `@Middleware` factories are, so the composition root can read it — and unlike middleware, which
    // wraps the finished router once, coding has to be handed *inward* to every witness, because it is
    // consumed at binding and encoding sites inside each route.
    let appCoding = bootstrapAppCodingExpression(bootstrap: bootstrap)
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
    // `prologue` (the keyed factory's key-identity `precondition`) leads the block, joined the same way the
    // registrations are so an absent one adds no line. It rides here rather than being interpolated ahead of
    // the build at the call site because `BasicFormat` re-indents only the first line of an interpolated
    // block: a prologue spliced in above would leave the statement after it skewed.
    let leading = prologue.isEmpty ? "" : prologue + "\n"
    return """
        \(leading)let graph = try await \(bootstrapCall)
        let bootstrap = graph.\(property)
        \(transport.serverLine(bootstrap: bootstrap))
        var builder = bootstrap.createRouteBuilder(for: server)
        let wireMVCServices = try WireMVC.apply(graph, to: &builder, coding: \(appCoding))
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
                try await WireMVC.serve(on: server, handler: wireMVCServed, services: wireMVCServices)
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
        \(suiteFactory(
            signatureParameters: "_ mode: WireMVCTestMode<WireMVCTestServerType>",
            bootstrap: bootstrap,
            notFoundRegistration: notFoundRegistration,
            factoryKeys: factoryKeys
        ))
        }
        """
    return Parser.parse(source: raw).formatted().description
}

/// One generated suite-trait factory: generic over the server its ``WireMVCTestMode`` carries, with a
/// single inlined build over `mode.httpServer`. Generic because the app's `createRouteBuilder(for:)` is —
/// the route builder takes its `~Copyable` associated types from the server, so the mode has to supply the
/// server for the build to have types at all. Two consequences fall out and are the point of the shape:
/// the generated code names no concrete server (whatever bound a transport needs is discharged where the
/// test writes `.inProcess` / `.swiftHttpServer` / `.server(_:)`), and there is exactly one build path
/// rather than one per mode.
///
/// `signatureParameters` is the factory's parameter list before the shared `services:` override, so the
/// keyed form can prepend its `TestingKey`. `runTests` is the trait's type-erasing hook: the closure builds
/// the app afresh each suite entry, so the opaque `~Copyable` handler stays a local that never escapes —
/// which is exactly why the build is inlined here rather than shared through a `buildApplication`.
///
/// `prologue` leads the build — i.e. it runs at suite *entry*, not when the attribute is evaluated. That
/// matters for the keyed form's key-identity `precondition`: a mode is constructed for every suite in the
/// bundle, filtered-out ones included, and trapping there would fail a run that doesn't even include the
/// offending suite. The same reasoning already defers `makeServer`.
func suiteFactory(
    signatureParameters: String,
    bootstrap: ControllerDeclaration,
    notFoundRegistration: String,
    factoryKeys: Set<String>,
    bootstrapCall: String = "Wire.bootstrap()",
    extraRegistrations: String = "",
    prologue: String = ""
) -> String {
    let buildLines = bootstrapBuildLines(
        bootstrap: bootstrap,
        notFoundRegistration: notFoundRegistration,
        factoryKeys: factoryKeys,
        bootstrapCall: bootstrapCall,
        extraRegistrations: extraRegistrations,
        transport: .suiteMode,
        prologue: prologue
    )
    // The `~Copyable` suppressions the proposal's `HTTPServer` declares must be restated here: a generic
    // context that merely names `Server` re-imposes `Copyable` on its associated types, and no proposal
    // server satisfies that. `runSuite` stays qualified on the `WireMVCTesting` enum, mirroring how the
    // `@main` names `WireMVC` types unqualified but calls `WireMVC.serve`.
    return """
        static func wiremvc<WireMVCTestServerType: HTTPServer>(
            \(signatureParameters),
            environment: (@Sendable () throws -> [String: String])? = nil,
            services: WireMVCTestServices? = nil
        ) -> WireMVCSuiteTrait
        where
            WireMVCTestServerType.RequestContext: ~Copyable,
            WireMVCTestServerType.Reader: ~Copyable,
            WireMVCTestServerType.ResponseSender: ~Copyable,
            WireMVCTestServerType.ResponseSender.Writer: ~Copyable
        {
            WireMVCSuiteTrait { runTests in
                try await WireMVCTesting.withEnvironment(environment) {
                    \(buildLines)
                    try await WireMVCTesting.runSuite(mode, on: server, handler: wireMVCServed, services: wireMVCServices, servicePolicy: services, runTests: runTests)
                }
            }
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

/// The app-wide coding the composition root resolves and hands to every contributor.
///
/// `@Coding` on the Bootstrap is lifted onto the same keyless proxy the global `@Middleware` factories
/// are, so the entry can read it there. Unlike middleware — which wraps the finished router once — coding
/// is consumed inside each route, so it has to be passed inward rather than wrapped around. Shared with
/// the keyed harness, which registers its variant proxies from the same entry.
func bootstrapAppCodingExpression(bootstrap: ControllerDeclaration) -> String {
    let proxyProperty = graphBindingPropertyName(globalMiddlewareProxyTypeName(bootstrap.name))
    guard
        let source = RouteBlockGenerator(subjectAccessor: "", factoryKeys: [], globalErrorMappings: [])
            .codingSource(from: bootstrap.attributes)
    else { return "WireMVCCoding.default" }
    // `graph.` matters: `proxyProperty` names a *property of the graph*, and both call sites run in the
    // generated entry where `graph` is the local the bootstrap produced. Emitted bare it parses fine and
    // reads as a static member on the proxy type, which is the shape of error that survives a test
    // asserting the rendered text and only fails once an app compiles it.
    return "graph.\(proxyProperty).\(dependencyPropertyName(forType: source)).wireMVCCoding"
}
