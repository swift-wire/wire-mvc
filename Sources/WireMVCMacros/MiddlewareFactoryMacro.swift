// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros
import WireMVCCodegen

/// Backs `@MiddlewareFactory`. Like the verb markers it expands to nothing — the plugin reads the
/// attribute (and its role list) off the type via the `wireMVCMiddlewareFactoryRolesAlias`. Its one job
/// is the producer-side diagnostic: `@MiddlewareFactory` supplies the role mapping *for a `@Factory`
/// template*, so without `@Factory` on the same type there is nothing to map. This mirrors a stray
/// adapter alias with no producer, caught at the seam.
public struct MiddlewareFactoryMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let attributes = declaration.asProtocol(WithAttributesSyntax.self)?.attributes ?? []
        let hasFactory = attributes.contains { element in
            element.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "Factory"
        }
        if !hasFactory {
            context.diagnose(
                Diagnostic(node: node, message: WireMVCDiagnostic.middlewareFactoryRequiresFactory)
            )
        }
        return []
    }
}
