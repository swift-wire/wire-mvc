import SwiftBasicFormat
import SwiftParser
public import SwiftSyntax

// The two output forms the shared route codegen feeds:
//   • the `@Controller` macro splices `renderRegisterWireRoutesWitness` into its peer *struct* (subject
//     accessor `controller`) — its structural scaffolding is unchanged;
//   • the `WireMVCRouteGen` tool wraps the same witness in an `extension` (subject accessor
//     `_wireSubject`) on the plugin-emitted structural proxy (Phase A), and formats it.
// Both fold the identical witness body from `RouteBlockGenerator`, so they cannot drift.

/// The `RouteContributor` witness signature — invariant boilerplate restating the `~Copyable`
/// requirements that don't propagate across the generic boundary. Shared so the macro's struct member
/// and the tool's extension member spell it identically.
private let witnessSignature = """
    registerWireRoutes<Builder: HTTPServerRouteBuilder>(on builder: inout Builder) throws
    where
        Builder.RequestContext: ~Copyable,
        Builder.Reader: ~Copyable,
        Builder.ResponseSender: ~Copyable,
        Builder.ResponseSender.Writer: ~Copyable
    """

/// The full `RouteContributor` witness method — access + signature + `where` clause + `{ body }` — for
/// one controller, plus any route-shape diagnostics. `access` is the `"public "`/`"package "`/`""`
/// keyword prefix; `subjectAccessor` is the stored field the body calls the controller through;
/// `factoryKeys` are the `@Factory` template keys the middleware fold classifies against.
public func renderRegisterWireRoutesWitness(
    access: String,
    controller: ControllerDeclaration,
    pathPrefix: String,
    subjectAccessor: String,
    factoryKeys: Set<String>,
    globalErrorMappings: [ErrorMapping] = [],
    keyedScopeEntry: KeyedScopeEntry? = nil,
    doublesThreadedFactoryKeys: Set<String> = []
) -> (witness: String, diagnostics: [RouteCodegenDiagnostic]) {
    var generator = RouteBlockGenerator(
        subjectAccessor: subjectAccessor,
        factoryKeys: factoryKeys,
        globalErrorMappings: globalErrorMappings,
        keyedScopeEntry: keyedScopeEntry,
        doublesThreadedFactoryKeys: doublesThreadedFactoryKeys
    )
    let body = generator.routeBlocks(of: controller, pathPrefix: pathPrefix)
    let witness = """
        \(access)func \(witnessSignature)
        {
        \(body)
        }
        """
    return (witness, generator.diagnostics)
}

/// The route-contributor witness as an `extension` on the plugin-emitted structural proxy — the domain
/// half the `WireMVCRouteGen` tool emits into the consumer module (Phase A). The struct itself (fields +
/// init + `Sendable`) is emitted by WireGen; this extension adds the `RouteContributor` conformance and
/// the witness, meeting the struct on the `_wireSubject` / `_wireFactory_<key>` field names. Formatted so
/// the generated file reads cleanly.
public func renderRouteContributorExtension(
    controller: ControllerDeclaration,
    pathPrefix: String,
    factoryKeys: Set<String>,
    globalErrorMappings: [ErrorMapping] = [],
    keyedScopeEntry: KeyedScopeEntry? = nil
) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
    let rendered = renderRegisterWireRoutesWitness(
        access: controller.access,
        controller: controller,
        pathPrefix: pathPrefix,
        subjectAccessor: contributorProxySubjectAccessor,
        factoryKeys: factoryKeys,
        globalErrorMappings: globalErrorMappings,
        keyedScopeEntry: keyedScopeEntry
    )
    let raw = """
        extension \(controller.proxyTypeName): RouteContributor {
        \(rendered.witness)
        }
        """
    return (formatted(raw), rendered.diagnostics)
}

/// The route-contributor witness as an `extension` on the **variant** proxy type
/// (`_<Variant>_WireRouteContributor_<Subject>`) — the keyed half a keyed test suite serves. The witness body
/// carries the doubles-threaded scope entry (`keyedScopeEntry`): each request correlates its doubles from the
/// per-key `TestBindStore` (an explicit 500 when absent) and enters request scope via the variant proxy's
/// `self._wireEnterScope(request, doubles)` — no production branch, since the variant graph selects this proxy
/// structurally. The keyed factory builds the proxy from the variant graph and calls `registerWireRoutes`.
public func renderVariantRouteContributorExtension(
    controller: ControllerDeclaration,
    pathPrefix: String,
    factoryKeys: Set<String>,
    globalErrorMappings: [ErrorMapping] = [],
    variantName: String,
    keyedScopeEntry: KeyedScopeEntry,
    doublesThreadedFactoryKeys: Set<String> = []
) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
    let rendered = renderRegisterWireRoutesWitness(
        access: controller.access,
        controller: controller,
        pathPrefix: pathPrefix,
        subjectAccessor: contributorProxySubjectAccessor,
        factoryKeys: factoryKeys,
        globalErrorMappings: globalErrorMappings,
        keyedScopeEntry: keyedScopeEntry,
        doublesThreadedFactoryKeys: doublesThreadedFactoryKeys
    )
    let raw = """
        extension \(variantProxyTypeName(variantName: variantName, subject: controller.name)): RouteContributor {
        \(rendered.witness)
        }
        """
    return (formatted(raw), rendered.diagnostics)
}

/// The stored-property name the plugin-emitted structural proxy holds its subject under — WireGen's
/// `_wireSubject` contract (`WireGenCore.contributorProxySubjectFieldName`). Restated here so the domain
/// witness references the same field the structural half declares. The two meet on this name.
public let contributorProxySubjectAccessor = "_wireSubject"

/// The method name the plugin-emitted structural proxy exposes a *bridging* (scoped) controller's
/// scope-entry thunk under — WireGen's `_wireEnterScope` contract
/// (`WireGenCore.contributorProxyScopeEntryFieldName`). A scoped controller's witness calls
/// `self._wireEnterScope(seed)` per request to construct the controller fresh; restated here so the
/// domain witness names the same field the structural half declares.
public let contributorProxyScopeEntryAccessor = "_wireEnterScope"

/// Parse each input Swift source, generate a route-contributor `extension` for every `@Controller` type
/// across them, and return one combined source (the files' imports + `import WireMVC` + the extensions)
/// plus the diagnostics resolved to source locations. No controllers → header only. This is the tool's
/// core; the executable is a thin CLI over it. Deterministic order: extensions by controller name,
/// imports sorted.
///
/// A `@WireMVCBootstrap` root emits exactly one program entry: `testEntry == false` (a program consumer,
/// e.g. the executable) gets the `@main`; `testEntry == true` (a test consumer that depends on the
/// `WireMVCTesting` product) gets the `.wiremvc()` suite-trait factory (and `import WireMVCTesting` +
/// `import Testing`) *instead* — the two are mutually exclusive because a `@main` in a test bundle collides
/// with the runner's own entry. `extraImports` are `import <Module>` lines for the modules the generated
/// content depends on: the Wire-aware dependencies whose sources were re-parsed into this consumer (a test
/// target re-composing the app), so the extensions can name the app's `package`/`public` controllers,
/// response types, and factories. The generated factory names no concrete server, so nothing else has to be
/// imported for it: whatever bound a transport needs is discharged where the test writes its mode.
/// `consumerModule` is the target being built — the only module whose `TestingKey` this target may serve. A
/// key composed in from a Wire-aware dependency is skipped (swift-wire refuses it outright), so a library's
/// key cannot be served in place of this target's own. Omit it, and every attributed module is eligible.
///
/// `sourceModules` maps a source path to the module it belongs to, when the caller knows it. Only the keyed
/// harness reads it, to reconstruct the served `TestingKey`'s `#fileID` for its identity assertion; a path
/// absent from the map simply yields no assertion. Empty by default, so a caller that doesn't care (every
/// test in this package) is unaffected.
public func generateRouteContributors(
    files: [(path: String, source: String)],
    testEntry: Bool = false,
    extraImports: [String] = [],
    sourceModules: [String: String] = [:],
    consumerModule: String? = nil
) -> (source: String, diagnostics: [LocatedRouteDiagnostic]) {
    // Parse every source once, then collect (in one pass) the imports, `@Factory` template keys, bootstrap
    // declarations, and the first bootstrap's global error tier + `@NotFound` fallback — a controller in one
    // file may reference a factory declared in another, so the full key set must be known before any witness
    // is folded (it classifies each `@Middleware(key)` as factory-vs-graph-binding).
    let parsed = files.map { file -> (path: String, tree: SourceFileSyntax) in
        (file.path, Parser.parse(source: file.source))
    }
    var composition = analyzeComposedInputs(parsed)
    var located = composition.diagnostics
    // The generated `@main`/`.wiremvc()` entry calls `Wire.bootstrap()`, so the consumer needs `import Wire`;
    // a test consumer's `.wiremvc()` suite-trait factory adds `Testing` + `WireMVCTesting` (a program consumer
    // must not link the test client).
    if !composition.bootstraps.isEmpty {
        composition.imports.insert("import Wire")
        if testEntry {
            composition.imports.insert("import WireMVCTesting")
            composition.imports.insert("import Testing")
        }
    }

    // The keyed test harness's `TestingKey` (H2.2b), discovered only for a test consumer that links
    // `WireMVCTesting` (`testEntry`) — the sole context the keyed factory + doubles-aware dispatch belong in.
    // One key per target: a second is an error, since only one factory is emitted for it to be served by.
    let harness: (key: DiscoveredTestingKey?, diagnostics: [LocatedRouteDiagnostic]) =
        testEntry
        ? discoverTestingKeys(in: parsed, sourceModules: sourceModules, consumerModule: consumerModule)
        : (key: nil, diagnostics: [])
    let harnessKey = harness.key
    located.append(contentsOf: harness.diagnostics)

    // The lifted `@Factory`s that consume the harness key's mocked slots — mock-consuming under this key, so
    // swift-wire re-emits each as a variant factory whose `create` takes doubles. One hop: a factory whose
    // `@Inject` doubles-field intersects a `@BindType` slot field (the same rule swift-wire applies).
    let doublesThreadedFactoryKeys: Set<String> =
        harnessKey.map { key in
            let slotFields = Set(key.substitutions.map(\.fieldName))
            return Set(
                composition.factoryInjectFields.compactMap { factoryKey, injectFields in
                    injectFields.isDisjoint(with: slotFields) ? nil : factoryKey
                }
            )
        } ?? []

    let controllerExtensions = renderControllerExtensions(
        parsed,
        testEntry: testEntry,
        factoryKeys: composition.factoryKeys,
        globalErrorMappings: composition.globalErrorMappings,
        harnessKey: harnessKey,
        doublesThreadedFactoryKeys: doublesThreadedFactoryKeys
    )
    located.append(contentsOf: controllerExtensions.diagnostics)

    // The caller-supplied modules the generated extensions/entry depend on — re-parsed Wire-aware
    // dependencies (whose types they name) and test-transport modules (whose retroactive
    // `WireMVCTestServer` conformance the entry needs in scope). Imported only when there is generated
    // content that references them (avoids an unused-import otherwise).
    if !controllerExtensions.extensions.isEmpty || !composition.bootstraps.isEmpty {
        composition.imports.formUnion(extraImports.map { "import \($0)" })
    }
    // A raw-route shim's signature names `HTTPResponse` (HTTPTypes) and `HTTPClientRequestBody` (HTTPAPIs),
    // which a consumer's own sources may not import.
    if controllerExtensions.clients.contains(where: { $0.source.contains("HTTPClientRequestBody") }) {
        composition.imports.insert("import HTTPTypes")
        composition.imports.insert("import HTTPAPIs")
    }

    // The `@WireMVCBootstrap` composition root's generated entry (and the keyed harness), emitted last at
    // module scope.
    let bootstrap = renderBootstrapSources(
        composition: composition,
        subjects: controllerExtensions.subjects,
        clientSubjects: Set(controllerExtensions.clients.map(\.name)),
        harnessKey: harnessKey,
        testEntry: testEntry
    )
    located.append(contentsOf: bootstrap.diagnostics)

    let source = assembleGeneratedSource(
        imports: composition.imports,
        extensions: controllerExtensions.extensions,
        clients: controllerExtensions.clients,
        bootstrapSources: bootstrap.sources
    )
    return (source, located)
}

/// The `@WireMVCBootstrap` root's module-scope sources: the global-middleware proxy extension + the program
/// entry (`@main` or keyless `.wiremvc()`) via ``bootstrapArtifacts``, then — for a test consumer whose
/// composed sources declare a `TestingKey` with at least one matching `@Scoped(seed:)` subject — the keyed
/// harness (H2.2b): the per-key statics + typed `withClient(supplying:)`, and the `.wiremvc(_:)` factory. A key with
/// no matching subject appends nothing, so the keyless path stands unchanged. Empty when there's no bootstrap.
private func renderBootstrapSources(
    composition: ComposedInputs,
    subjects: [String],
    clientSubjects: Set<String>,
    harnessKey: DiscoveredTestingKey?,
    testEntry: Bool
) -> (sources: [String], diagnostics: [LocatedRouteDiagnostic]) {
    guard let bootstrap = composition.bootstraps.first else { return ([], []) }
    let artifacts = bootstrapArtifacts(
        bootstrap: bootstrap,
        factoryKeys: composition.factoryKeys,
        notFoundRegistration: composition.notFoundRegistration,
        converter: composition.bootstrapConverter,
        testEntry: testEntry
    )
    var sources = artifacts.sources
    // The `withClient` family — emitted for every test consumer, keyed or not: it is how a keyless suite
    // reaches a client at all, and how a keyed one drives a route without supplying doubles.
    if testEntry {
        sources.append(renderClientAccessors(controllersWithClients: clientSubjects.sorted()))
    }
    if testEntry, let harnessKey, !subjects.isEmpty {
        sources.append(
            renderKeyedHarnessStatics(
                key: harnessKey,
                subjects: subjects,
                clientSubjects: clientSubjects
            )
        )
        sources.append(
            renderBootstrapKeyedTestEntry(
                bootstrap: bootstrap,
                notFoundRegistration: composition.notFoundRegistration,
                factoryKeys: composition.factoryKeys,
                key: harnessKey,
                subjects: subjects
            )
        )
    }
    return (sources, artifacts.diagnostics)
}

/// The whole-composition facts the generator reads once up front: the collected imports, `@Factory` template
/// keys, every `@WireMVCBootstrap` declaration, and the first bootstrap's global `@ErrorResponse` tier +
/// `@NotFound` fallback registration (with its file converter for locating later proxy diagnostics).
private struct ComposedInputs {
    var imports: Set<String> = ["import WireMVC"]
    var factoryKeys: Set<String> = []
    /// Each `@Factory` template key → the doubles-field names its `@Inject`s resolve to — the one-hop
    /// mock-consumption facts a variant witness classifies its lifted factories against.
    var factoryInjectFields: [String: Set<String>] = [:]
    var bootstraps: [ControllerDeclaration] = []
    var globalErrorMappings: [ErrorMapping] = []
    var notFoundRegistration = ""
    var bootstrapConverter: SourceLocationConverter?
    var diagnostics: [LocatedRouteDiagnostic] = []
}

/// One pass over the parsed sources, gathering ``ComposedInputs`` — split out of `generateRouteContributors`
/// so the orchestration reads as a short pipeline.
private func analyzeComposedInputs(_ parsed: [(path: String, tree: SourceFileSyntax)]) -> ComposedInputs {
    var result = ComposedInputs()
    var readBootstrap = false
    for file in parsed {
        result.imports.formUnion(importDeclarations(of: file.tree))
        result.factoryKeys.formUnion(factoryTemplateKeys(in: file.tree))
        result.factoryInjectFields.merge(factoryTemplateInjectFields(in: file.tree)) { $0.union($1) }
        let fileBootstraps = bootstrapDeclarations(in: file.tree)
        result.bootstraps.append(contentsOf: fileBootstraps)
        guard !readBootstrap, let bootstrap = fileBootstraps.first else { continue }
        readBootstrap = true
        let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
        result.bootstrapConverter = converter
        var reader = RouteBlockGenerator(subjectAccessor: "", factoryKeys: [], globalErrorMappings: [])
        result.globalErrorMappings = reader.errorMappings(from: bootstrap.attributes, scopeLabel: "bootstrap")
        let notFound = renderNotFoundRegistration(bootstrap: bootstrap)
        result.notFoundRegistration = notFound.registration
        for diagnostic in reader.diagnostics + notFound.diagnostics {
            result.diagnostics.append(
                LocatedRouteDiagnostic(
                    message: diagnostic.message,
                    location: diagnostic.node.startLocation(converter: converter)
                )
            )
        }
    }
    return result
}

/// Join the collected imports, controller extensions, and bootstrap entry-point sources into the
/// final generated source. Imports and extensions are emitted in sorted order; the bootstrap
/// sources (its generated `@main`/`.wiremvc()` entry) come last, at module scope. Split out of
/// `generateRouteContributors` to keep it within the body-length budget.
private func assembleGeneratedSource(
    imports: Set<String>,
    extensions: [(name: String, source: String)],
    clients: [(name: String, source: String)],
    bootstrapSources: [String]
) -> String {
    var lines = ["// Generated by WireMVCRouteGen — do not edit."]
    for line in imports.sorted() {
        lines.append("")
        lines.append(line)
    }
    for declaration in extensions.sorted(by: { $0.name < $1.name }) {
        lines.append("")
        lines.append(declaration.source)
    }
    for declaration in clients.sorted(by: { $0.name < $1.name }) {
        lines.append("")
        lines.append(declaration.source)
    }
    for source in bootstrapSources {
        lines.append("")
        lines.append(source)
    }
    lines.append("")
    return lines.joined(separator: "\n")
}

/// Render a route-contributor `extension` for every `@Controller` across the parsed files, each diagnostic
/// located to its file. Split out of `generateRouteContributors` to keep it within the body-length budget.
/// The controller-extension render output — the `RouteContributor` extensions, their located diagnostics,
/// and the variant subjects (matching `@Scoped(seed:)` controller names) the keyed harness parks a proxy for.
private struct ControllerExtensionsResult {
    let extensions: [(name: String, source: String)]
    let diagnostics: [LocatedRouteDiagnostic]
    let subjects: [String]
    /// The per-controller typed clients, for a test consumer — emitted alongside the witnesses because both
    /// read the same route declarations.
    let clients: [(name: String, source: String)]
}

private func renderControllerExtensions(
    _ parsed: [(path: String, tree: SourceFileSyntax)],
    testEntry: Bool,
    factoryKeys: Set<String>,
    globalErrorMappings: [ErrorMapping],
    harnessKey: DiscoveredTestingKey?,
    doublesThreadedFactoryKeys: Set<String>
) -> ControllerExtensionsResult {
    var extensions: [(name: String, source: String)] = []
    var located: [LocatedRouteDiagnostic] = []
    var subjects: [String] = []
    var clients: [(name: String, source: String)] = []
    for file in parsed {
        let converter = SourceLocationConverter(fileName: file.path, tree: file.tree)
        let finder = ControllerFinder()
        finder.walk(file.tree)
        for found in finder.controllers {
            // The production witness is always keyless — a keyed suite serves the variant graph, whose scoped
            // subjects are registered from their variant witnesses below; the production witness serves the
            // keyless graph (`.wiremvc()` / `@main`).
            let rendered = renderRouteContributorExtension(
                controller: found.declaration,
                pathPrefix: found.pathPrefix,
                factoryKeys: factoryKeys,
                globalErrorMappings: globalErrorMappings,
                keyedScopeEntry: nil
            )
            extensions.append((found.declaration.name, rendered.source))

            // The typed client is a test-only surface: it exists to be driven by a suite, and a program
            // consumer must not link `TestClient`.
            if testEntry,
                let client = renderControllerClient(controller: found.declaration, pathPrefix: found.pathPrefix)
            {
                clients.append((found.declaration.name, client))
            }
            for diagnostic in rendered.diagnostics {
                located.append(
                    LocatedRouteDiagnostic(
                        message: diagnostic.message,
                        location: diagnostic.node.startLocation(converter: converter)
                    )
                )
            }

            // A keyed variant subject also gets a witness on its variant proxy type, carrying the
            // doubles-threaded scope entry — the keyed factory hand-registers it. Its route-shape diagnostics
            // duplicate the production witness's (same routes), so they are not re-reported.
            guard let harnessKey, let entry = keyedScopeEntry(for: found.declaration, key: harnessKey) else {
                continue
            }
            subjects.append(found.declaration.name)
            let variant = renderVariantRouteContributorExtension(
                controller: found.declaration,
                pathPrefix: found.pathPrefix,
                factoryKeys: factoryKeys,
                globalErrorMappings: globalErrorMappings,
                variantName: harnessKey.variantName,
                keyedScopeEntry: entry,
                doublesThreadedFactoryKeys: doublesThreadedFactoryKeys
            )
            extensions.append((found.declaration.name + "Variant", variant.source))
        }
    }
    return ControllerExtensionsResult(
        extensions: extensions,
        diagnostics: located,
        subjects: subjects,
        clients: clients
    )
}

/// The `@WireMVCBootstrap` composition root's generated artifacts, emitted last at module scope: the
/// keyless global-middleware proxy's `wrapGlobalMiddleware` extension (M5.5 Phase 5), always, plus exactly
/// one program entry — the `@main` for a program consumer, or the `.wiremvc()` suite-trait factory for a test
/// consumer (`testEntry`). The two entries are mutually exclusive: a `@main` in a test bundle collides with
/// the test runner's own entry point, so a re-composing test target emits `.wiremvc()` in its place.
/// The extension is rendered here so it sees the full `factoryKeys` set (a global `@Middleware(key)` may
/// reference a factory declared in any file); each entry calls it on `graph._WireGlobalMiddleware_<Bootstrap>`.
private func bootstrapArtifacts(
    bootstrap: ControllerDeclaration,
    factoryKeys: Set<String>,
    notFoundRegistration: String,
    converter: SourceLocationConverter?,
    testEntry: Bool
) -> (sources: [String], diagnostics: [LocatedRouteDiagnostic]) {
    let proxyExtension = renderGlobalMiddlewareProxyExtension(bootstrap: bootstrap, factoryKeys: factoryKeys)
    var diagnostics: [LocatedRouteDiagnostic] = []
    if let converter {
        for diagnostic in proxyExtension.diagnostics {
            diagnostics.append(
                LocatedRouteDiagnostic(
                    message: diagnostic.message,
                    location: diagnostic.node.startLocation(converter: converter)
                )
            )
        }
    }
    // A test consumer gets the `.wiremvc(_:)` suite-trait factory (its closure inlines the same build once
    // per mode and hands it to the matching `WireMVCTesting` driver); a program consumer gets the `@main`.
    // Never both — the `@main` would collide with the test runner's entry.
    let entry =
        testEntry
        ? renderBootstrapTestEntry(
            bootstrap: bootstrap,
            notFoundRegistration: notFoundRegistration,
            factoryKeys: factoryKeys
        )
        : renderBootstrapEntry(
            bootstrap: bootstrap,
            notFoundRegistration: notFoundRegistration,
            factoryKeys: factoryKeys
        )
    return ([proxyExtension.source, entry], diagnostics)
}

/// A route-codegen diagnostic resolved to a source location — what the tool prints as
/// `file:line:col: error:`.
public struct LocatedRouteDiagnostic: Sendable {
    public let message: WireMVCDiagnostic
    public let location: SourceLocation
}

/// Run a raw generated declaration through `BasicFormat` so the emitted file is consistently indented
/// — the role `assertMacroExpansion`/the compiler play for macro output, done explicitly here since the
/// tool writes plain text.
private func formatted(_ raw: String) -> String {
    Parser.parse(source: raw).formatted().description
}

/// Collect a parsed file's `import` declarations verbatim, so names the generated extensions reference
/// (the controller's domain types, WireMVC's routing surface) stay in scope.
private func importDeclarations(of sourceFile: SourceFileSyntax) -> [String] {
    sourceFile.statements.compactMap { statement in
        statement.item.as(ImportDeclSyntax.self)?.trimmedDescription
    }
}

/// The canonical key text of every `@Factory(key)` template declared in a parsed file — the set a
/// middleware fold classifies its `@Middleware(key)` arguments against (a match is a factory; anything
/// else is a graph binding). Walks the whole tree, since a factory template can be nested in an
/// enclosing type.
private func factoryTemplateKeys(in sourceFile: SourceFileSyntax) -> Set<String> {
    let finder = FactoryKeyFinder()
    finder.walk(sourceFile)
    return finder.keys
}

/// Walks a parsed file for every `@Factory(key)` attribute, capturing its key argument's canonical text.
private final class FactoryKeyFinder: SyntaxVisitor {
    private(set) var keys: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        guard node.attributeName.trimmedDescription == "Factory",
            case let .argumentList(list) = node.arguments,
            let first = list.first
        else { return .visitChildren }
        keys.insert(first.expression.trimmedDescription)
        return .visitChildren
    }
}

/// The doubles-field names each `@Factory(key)` template `@Inject`s — key → the set of `_<Key>Doubles` fields
/// its injected slots resolve to. A factory is **mock-consuming** under a `TestingKey` iff this set intersects
/// the key's `@BindType` field names; then swift-wire re-emits it as a variant factory whose `create` takes
/// doubles, and the variant witness's fold threads them. Uses the same `identifierName(forType:key:)` field
/// rule as `@BindType` discovery, so the two agree blind — one hop (the factory's own `@Inject`s), matching
/// swift-wire's variant-factory detection (which likewise inspects the factory's direct dependencies).
private func factoryTemplateInjectFields(in sourceFile: SourceFileSyntax) -> [String: Set<String>] {
    let finder = FactoryInjectFinder()
    finder.walk(sourceFile)
    return finder.injectFields
}

/// Walks a parsed file for every `@Factory(key)` template, recording the doubles-field name of each of its
/// `@Inject` members (by-type from the member's type, keyed from its `@Inject(key)` argument).
private final class FactoryInjectFinder: SyntaxVisitor {
    private(set) var injectFields: [String: Set<String>] = [:]

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(attributes: node.attributes, generics: node.genericParameterClause, members: node.memberBlock.members)
        return .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(attributes: node.attributes, generics: node.genericParameterClause, members: node.memberBlock.members)
        return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(attributes: node.attributes, generics: node.genericParameterClause, members: node.memberBlock.members)
        return .visitChildren
    }

    private func record(
        attributes: AttributeListSyntax,
        generics: GenericParameterClauseSyntax?,
        members: MemberBlockItemListSyntax
    ) {
        guard let key = attributeArgument(named: "Factory", in: attributes) else { return }
        // A `@Inject var x: Param` spelled as an injected generic parameter is bound to the slot named by the
        // parameter's constraint (`Repository: TodoRepository` → the `TodoRepository` slot). Resolve it so the
        // field name lines up with the `@BindType` slot — matching swift-wire's constraint-based detection.
        let constraints = genericConstraints(generics)
        var fields: Set<String> = []
        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                let inject = attribute(named: "Inject", in: variable.attributes),
                let type = variable.bindings.first?.typeAnnotation?.type.trimmedDescription
            else { continue }
            let resolvedType = constraints[type] ?? type
            fields.insert(wireGenIdentifierName(forType: strippingAny(resolvedType), key: injectKeyArgument(inject)))
        }
        if !fields.isEmpty { injectFields[key, default: []].formUnion(fields) }
    }

    /// Each generic parameter's constraint (inheritance clause) — `Repository: TodoRepository` →
    /// `["Repository": "TodoRepository"]`; an unconstrained parameter is omitted.
    private func genericConstraints(_ clause: GenericParameterClauseSyntax?) -> [String: String] {
        guard let clause else { return [:] }
        var constraints: [String: String] = [:]
        for parameter in clause.parameters {
            if let inherited = parameter.inheritedType?.trimmedDescription {
                constraints[parameter.name.text] = inherited
            }
        }
        return constraints
    }

    /// The attribute `named` on a declaration, or `nil`.
    private func attribute(named name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == name {
            return attr
        }
        return nil
    }

    /// The first argument's canonical text of the attribute `named`, or `nil` (for `@Factory(key)`).
    private func attributeArgument(named name: String, in attributes: AttributeListSyntax) -> String? {
        guard let attr = attribute(named: name, in: attributes),
            case let .argumentList(list) = attr.arguments, let first = list.first
        else { return nil }
        return first.expression.trimmedDescription
    }

    /// The `@Inject(<key>)` argument expression, or `nil` for the unkeyed `@Inject` form.
    private func injectKeyArgument(_ attribute: AttributeSyntax) -> String? {
        guard case let .argumentList(list) = attribute.arguments, let first = list.first else { return nil }
        return first.expression.trimmedDescription
    }
}

/// Walks a parsed file for every nominal type carrying `@Controller`, capturing its declaration and the
/// route path prefix the annotation supplies. A `SyntaxVisitor` so controllers nested in enclosing types
/// are found too.
private final class ControllerFinder: SyntaxVisitor {
    struct Found {
        let declaration: ControllerDeclaration
        let pathPrefix: String
    }
    private(set) var controllers: [Found] = []

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
        guard let controllerAttribute = controllerAttribute(in: declaration.attributes),
            let controller = ControllerDeclaration(declaration)
        else { return }
        controllers.append(Found(declaration: controller, pathPrefix: pathPrefix(of: controllerAttribute)))
    }

    private func controllerAttribute(in attributes: AttributeListSyntax) -> AttributeSyntax? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "Controller" {
            return attr
        }
        return nil
    }

    /// The `@Controller("/prefix")` path, or `""` for `@Controller` / `@Controller()`.
    private func pathPrefix(of attribute: AttributeSyntax) -> String {
        guard case let .argumentList(list) = attribute.arguments, let first = list.first else { return "" }
        return first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue ?? ""
    }
}
