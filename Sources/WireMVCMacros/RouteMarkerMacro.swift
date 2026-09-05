// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import SwiftSyntax
import SwiftSyntaxMacros

/// Backs the verb (`@Get`, `@Post`, …) and response (`@JSONResponse`, `@ResponseStatus`)
/// annotations. They exist only so the attributes are legal syntax on a function; the
/// `@Controller` macro reads them off the function. They expand to nothing themselves.
public struct RouteMarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
