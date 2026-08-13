public import SwiftSyntax

// Reading `@ResponseMode(…)` off a response mode's *macro declaration*, wherever it lives — the mirror of
// `BindingObligations.swift`, and the same mechanism for the same reason.
//
// A response annotation has to be a macro: it attaches to a function, and a property wrapper cannot. So
// unlike a request binding, whose facts sit on a `struct`, a mode's facts sit on a `macro` declaration. That
// is the only difference; a macro declaration accepts a custom attribute and `MacroDeclSyntax.attributes`
// exposes it with labelled arguments intact, which was verified against the compiler before this was written.
//
// What the declaration must state is what a syntactic generator cannot infer from a handler it never runs:
// which terminal builds the response, what encodes the return, and what the typed client does with the body.

/// Which terminal a mode uses. Mirrors `WireMVCResponseTerminal`, which the codegen cannot import.
public enum DeclaredResponseTerminal: String, Sendable {
    case buffered
    case streaming
    case bodiless
}

/// What the typed client hands back. Mirrors `WireMVCResponseClientBody`.
public enum DeclaredResponseClientBody: String, Sendable {
    case decoded
    case text
}

/// One response mode, as its macro declaration states it.
public struct DeclaredResponseMode: Sendable, Equatable {
    public let terminal: DeclaredResponseTerminal
    /// The codec's **spelling**, resolved in the controller's module at the generated call site — `nil` for
    /// a `.bodiless` mode, which encodes nothing.
    public let codec: String?
    public let clientBody: DeclaredResponseClientBody

    public init(
        terminal: DeclaredResponseTerminal,
        codec: String?,
        clientBody: DeclaredResponseClientBody = .decoded
    ) {
        self.terminal = terminal
        self.codec = codec
        self.clientBody = clientBody
    }
}

/// A mode together with the annotation name a route spells it under.
///
/// The name is not on ``DeclaredResponseMode`` because that type is what a *declaration* states, and a
/// declaration does not state its own name twice. The generator needs both — the pair to decide what to
/// emit, the name to read this route's `status:` argument off the right attribute and to say which
/// annotation a diagnostic is about.
public struct ResolvedResponseMode {
    public let name: String
    public let declared: DeclaredResponseMode

    public init(name: String, declared: DeclaredResponseMode) {
        self.name = name
        self.declared = declared
    }

    public var terminal: DeclaredResponseTerminal { declared.terminal }
    public var codec: String? { declared.codec }
    public var clientBody: DeclaredResponseClientBody { declared.clientBody }
}

/// Every `@ResponseMode`-annotated macro declaration reachable in `files`, keyed by macro name.
///
/// Keyed on the bare name because that is what a route spells: `@YAMLResponse` names `YAMLResponse`. Two
/// modules declaring a mode of the same name would collide — the same collision the old hardcoded name set
/// would have had, and worth a diagnostic if it ever arises rather than a silent last-wins.
public func scanResponseModes(in files: [SourceFileSyntax]) -> [String: DeclaredResponseMode] {
    var found: [String: DeclaredResponseMode] = [:]
    for file in files {
        let scanner = ResponseModeScanner(viewMode: .sourceAccurate)
        scanner.walk(file)
        found.merge(scanner.found) { existing, _ in existing }
    }
    return found
}

/// Walks rather than iterating top-level statements, for the reason `RequestBindingScanner` does: a mode may
/// be declared inside a namespace enum, and the scan should not depend on where its author put it.
private final class ResponseModeScanner: SyntaxVisitor {
    var found: [String: DeclaredResponseMode] = [:]

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        for case let .attribute(attribute) in node.attributes
        where attribute.attributeName.trimmedDescription == "ResponseMode" {
            if let mode = Self.mode(of: attribute) { found[node.name.text] = mode }
        }
        return .visitChildren
    }

    /// `@ResponseMode(.buffered, codec: "YAMLCodec", client: .text)`.
    ///
    /// An unreadable attribute yields `nil` rather than a diagnostic. The scan runs over *every* parsed file
    /// including dependencies, so a message about one would be reported against source the consumer cannot
    /// edit; a route using an unrecognised annotation is diagnosed at its own use site instead, which is
    /// where the author can act on it.
    private static func mode(of attribute: AttributeSyntax) -> DeclaredResponseMode? {
        guard case let .argumentList(arguments) = attribute.arguments else { return nil }
        var terminal: DeclaredResponseTerminal?
        var codec: String?
        var clientBody: DeclaredResponseClientBody = .decoded

        for argument in arguments {
            let text = argument.expression.trimmedDescription
            switch argument.label?.text {
            case nil:
                // The trailing member name, so `.buffered` and `WireMVCResponseTerminal.buffered` read alike.
                terminal = text.split(separator: ".").last.flatMap {
                    DeclaredResponseTerminal(rawValue: String($0))
                }
            case "codec":
                // A string literal, so the written quotes are not part of the spelling. `nil` written
                // explicitly is the bodiless case and leaves this absent.
                codec = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
            case "client":
                clientBody =
                    text.split(separator: ".").last
                    .flatMap { DeclaredResponseClientBody(rawValue: String($0)) } ?? .decoded
            default:
                break
            }
        }
        guard let terminal else { return nil }
        return DeclaredResponseMode(terminal: terminal, codec: codec, clientBody: clientBody)
    }
}
