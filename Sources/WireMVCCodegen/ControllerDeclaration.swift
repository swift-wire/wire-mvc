public import SwiftSyntax

/// The pieces of an annotated controller the route codegen needs — normalised across `struct` / `class`
/// / `actor` hosts. Reads from any nominal type declaration, so it serves both the `@Controller` macro
/// (which receives the attached declaration) and the `WireMVCRouteGen` tool (which finds `@Controller`
/// types by walking a parsed source file). `nil` for any declaration that isn't a nominal type.
public struct ControllerDeclaration {
    public let name: String
    let genericParameterClause: GenericParameterClauseSyntax?
    let genericWhereClause: GenericWhereClauseSyntax?
    public let attributes: AttributeListSyntax
    let modifiers: DeclModifierListSyntax
    let memberBlock: MemberBlockSyntax

    public init?(_ declaration: some DeclSyntaxProtocol) {
        if let structDecl = declaration.as(StructDeclSyntax.self) {
            name = structDecl.name.text
            genericParameterClause = structDecl.genericParameterClause
            genericWhereClause = structDecl.genericWhereClause
            attributes = structDecl.attributes
            modifiers = structDecl.modifiers
            memberBlock = structDecl.memberBlock
        } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
            name = classDecl.name.text
            genericParameterClause = classDecl.genericParameterClause
            genericWhereClause = classDecl.genericWhereClause
            attributes = classDecl.attributes
            modifiers = classDecl.modifiers
            memberBlock = classDecl.memberBlock
        } else if let actorDecl = declaration.as(ActorDeclSyntax.self) {
            name = actorDecl.name.text
            genericParameterClause = actorDecl.genericParameterClause
            genericWhereClause = actorDecl.genericWhereClause
            attributes = actorDecl.attributes
            modifiers = actorDecl.modifiers
            memberBlock = actorDecl.memberBlock
        } else {
            return nil
        }
    }

    var functions: [FunctionDeclSyntax] {
        memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
    }

    /// `"public "` / `"package "` / `""` — the proxy inherits the controller's visibility so the graph
    /// consumer (another module) can construct it.
    public var access: String {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            default: continue
            }
        }
        return ""
    }

    /// The generic parameter clause verbatim (`"<Repository: TodoRepository>"`) restated on the proxy,
    /// or `""` for a non-generic controller.
    public var genericClause: String { genericParameterClause?.trimmedDescription ?? "" }

    /// The generic `where` clause verbatim, space-prefixed for splicing after `Sendable`, or `""`.
    public var whereClause: String { genericWhereClause.map { " \($0.trimmedDescription)" } ?? "" }

    /// The controller type the proxy stores — its name applied to its own parameter names
    /// (`TodosController<Repository>`, so the proxy threads the graph's lift parameter transitively), or
    /// the bare name for a non-generic controller.
    public var selfType: String {
        guard let parameters = genericParameterClause?.parameters, !parameters.isEmpty else { return name }
        let arguments = parameters.map { $0.name.text }.joined(separator: ", ")
        return "\(name)<\(arguments)>"
    }

    /// The proxy type name for this controller — `_WireRouteContributor_<name>`. The prefix is the
    /// structural half's `proxyTypePrefix` (declared by `wireMVCControllerAlias`), so the macro's peer
    /// type, the plugin-synthesised binding, and the tool's extension all name the same type.
    public var proxyTypeName: String { "_WireRouteContributor_\(name)" }

    /// The seed type of a `@Scoped(seed: S.self)` controller (`"S"`), or `nil` for an app-scoped
    /// (`@Singleton`) controller. Drives per-request scope entry in the witness: a scoped controller is
    /// constructed fresh per request from the proxy's `_wireEnterScope` thunk rather than held directly.
    public var scopedSeedType: String? {
        for case let .attribute(attr) in attributes where attr.attributeName.trimmedDescription == "Scoped" {
            guard case let .argumentList(list) = attr.arguments,
                let seedArgument = list.first(where: { $0.label?.text == "seed" })
            else { continue }
            let expression = seedArgument.expression.trimmedDescription
            return expression.hasSuffix(".self") ? String(expression.dropLast(".self".count)) : expression
        }
        return nil
    }
}
