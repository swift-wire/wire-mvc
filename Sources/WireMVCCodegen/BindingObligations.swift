public import SwiftSyntax

// Reading `@RequestBinding(…)` off a binding's *declaration*, wherever it lives.
//
// The codegen sees a use site — `@FormBody input: Login` — as text, in a module that is usually not the one
// declaring `FormBody`. It cannot ask whether `FormBody: RequestBound`. It does not need to: the plugin
// passes the sources of every Wire-aware dependency to `WireMVCRouteGen` alongside the consumer's own
// (`WireMVCBuildPlugin.swift:33`, and the flat `--module`-grouped source list in `WireMVCRouteGen/main.swift`),
// so the declaration is already in front of it.
//
// **There is no table of built-ins.** `@Path`, `@Query`, `@Header` and `@JSONBody` carry `@RequestBinding`
// on their own declarations and are found by this scan like anyone else's, because WireMVC is a Wire-aware
// dependency of every consumer that can use its macros — the plugin re-parses it, so its declarations are
// among the sources scanned. A target that does *not* depend on the WireMVC product directly cannot use
// `@Controller` at all: WireGen never sees the adapter directives and the build fails on a missing
// contributor proxy, loudly, before any of this is reached.
//
// A hardcoded floor stood here until 2026-08-13, justified by a `@Controller` macro expansion path that no
// longer exists — the macro expands to nothing and route generation is entirely the plugin's. Removing it
// took nothing with it: the plugin path was already reading the real declarations.
//
// What the declaration must state is only what a syntactic generator cannot infer from a function body it
// never reads. That is two things — see `Documentation/Notes/ExtensibleBindingsAndResponses.md`. Where the
// value goes on the wire is *not* among them: the reverse bind places it, in code the compiler checks.

/// What the code generator must do differently for a binding. Not a wire position — an obligation.
public struct BindingObligations: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The route reads the request body, so the terminal must collect it, and this parameter supplies the
    /// body when the typed client builds a request. At most one per route.
    public static let body = BindingObligations(rawValue: 1 << 0)

    /// The binding names a `{name}` placeholder, so the route template must contain one
    /// (`RouteCodegen.swift:521`). Today only `@Path` is checked, by name; this is that check generalised.
    public static let path = BindingObligations(rawValue: 1 << 1)
}

/// Every conformance to `name` declared in `files`, by conforming type — read off the inheritance clause of
/// a type declaration or an extension.
///
/// Syntactic, so it sees only what is written in the parsed sources. That is enough for the one use it has:
/// warning that a binding declared `@RequestBinding(.body)` does not conform to `RequestBodySendable`, where
/// the attribute already tells us the declaring module *is* being parsed. A conformance added retroactively
/// from a third module would not be seen — which is why the diagnostic this backs is a warning, not an error.
public func scanConformances(to name: String, in files: [SourceFileSyntax]) -> Set<String> {
    var found: Set<String> = []
    for file in files {
        let scanner = ConformanceScanner(protocolName: name, viewMode: .sourceAccurate)
        scanner.walk(file)
        found.formUnion(scanner.found)
    }
    return found
}

private final class ConformanceScanner: SyntaxVisitor {
    let protocolName: String
    var found: Set<String> = []

    init(protocolName: String, viewMode: SyntaxTreeViewMode) {
        self.protocolName = protocolName
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.extendedType.trimmedDescription, node.inheritanceClause)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.inheritanceClause)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.inheritanceClause)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, node.inheritanceClause)
        return .visitChildren
    }

    private func record(name: String, _ inheritance: InheritanceClauseSyntax?) {
        guard let inheritance else { return }
        // The extended type may be generic or qualified — key on the bare name, as a use site spells it.
        let bare = name.split(separator: "<").first.map(String.init) ?? name
        let simple = bare.split(separator: ".").last.map(String.init) ?? bare
        for inherited in inheritance.inheritedTypes
        where inherited.type.trimmedDescription.split(separator: ".").last.map(String.init) == protocolName {
            found.insert(simple)
        }
    }
}

/// Every `@RequestBinding`-annotated declaration reachable in `files`, keyed by type name.
///
/// Keyed on the bare type name because that is what a use site spells: `@FormBody input: Login` names
/// `FormBody`, generic parameters and module qualification absent. Two modules declaring a binding of the
/// same name would collide — the same collision the existing wrapper set would have, and worth a diagnostic
/// if it ever arises rather than a silent last-wins.
public func scanRequestBindings(in files: [SourceFileSyntax]) -> [String: BindingObligations] {
    var found: [String: BindingObligations] = [:]
    for file in files {
        let scanner = RequestBindingScanner(viewMode: .sourceAccurate)
        scanner.walk(file)
        found.merge(scanner.found) { existing, new in existing.union(new) }
    }
    return found
}

/// Walks rather than iterating top-level statements: a binding may be declared inside a namespace enum, and
/// the scan should not depend on where its author put it.
private final class RequestBindingScanner: SyntaxVisitor {
    var found: [String: BindingObligations] = [:]

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes)
        return .visitChildren
    }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(name: node.name.text, attributes: node.attributes)
        return .visitChildren
    }

    private func record(name: String, attributes: AttributeListSyntax) {
        for case let .attribute(attribute) in attributes
        where attribute.attributeName.trimmedDescription == "RequestBinding" {
            found[name, default: []] = obligations(of: attribute)
        }
    }

    /// `@RequestBinding` → none; `@RequestBinding(.body)` → body; `@RequestBinding(.body, .path)` → both.
    ///
    /// Unknown cases are ignored rather than diagnosed here. The scan runs over *every* parsed file
    /// including dependencies, so a message about one would be reported against source the consumer cannot
    /// edit; the use site is where a bad obligation should surface.
    private func obligations(of attribute: AttributeSyntax) -> BindingObligations {
        guard case let .argumentList(arguments) = attribute.arguments else { return [] }
        var result: BindingObligations = []
        for argument in arguments {
            // The trailing member name, so `.body` and `WireMVCBindingObligation.body` read alike.
            switch argument.expression.trimmedDescription.split(separator: ".").last {
            case "body": result.insert(.body)
            case "path": result.insert(.path)
            default: break
            }
        }
        return result
    }
}
