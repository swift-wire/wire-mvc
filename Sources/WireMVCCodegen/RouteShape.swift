public import SwiftSyntax

// The route-shape rules both generated surfaces read: the witness (`RouteCodegen`) and the per-controller
// typed client (`ControllerClientGeneration`). They are free functions rather than methods on either
// generator because both need them and neither owns them — the same reason `WireMVCCodegen` exists at all,
// so the macro and the tool can't drift on route shape.

/// The proposal `HTTPRequest.Method` expression for a verb attribute name — `.get` for `@Get`. `nil` for an
/// attribute that isn't a verb.
func routeVerbMethod(for attributeName: String) -> String? {
    switch attributeName {
    case "Get": return ".get"
    case "Post": return ".post"
    case "Put": return ".put"
    case "Patch": return ".patch"
    case "Delete": return ".delete"
    default: return nil
    }
}

/// The wire method name for a verb attribute — `"GET"` for `@Get`. What the typed client sends, where the
/// witness registers `routeVerbMethod`'s proposal expression.
func routeWireMethod(for attributeName: String) -> String? {
    routeVerbMethod(for: attributeName).map { String($0.dropFirst().uppercased()) }
}

/// Join a controller prefix and a verb subpath into one `{name}`-template path.
func routeJoinPath(_ prefix: String, _ sub: String) -> String {
    let head = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
    let tail = sub.isEmpty ? "" : (sub.hasPrefix("/") ? sub : "/" + sub)
    let joined = head + tail
    return joined.isEmpty ? "/" : joined
}

/// The first argument of an attribute, when it is a string literal — the path of `@Get("/{id}")`, the wire
/// name of `@Path("id")`.
func routeFirstStringLiteral(_ arguments: AttributeSyntax.Arguments?) -> String? {
    guard case let .argumentList(list) = arguments, let first = list.first else { return nil }
    return first.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
}
