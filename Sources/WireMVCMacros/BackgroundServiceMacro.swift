// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import SwiftSyntax
import SwiftSyntaxMacros

/// Backs `@BackgroundService`. It's a marker Wire reads as an alias for
/// `@Contributes(to: WireMVCKeys.services)` (see `wireMVCServiceAlias`); it expands to nothing itself,
/// so it's legal on any binding — a `@Singleton`/`@Scoped` *type* or a `@Provides` *function*. The
/// annotated (or returned) type is expected to already conform to `ServiceLifecycle.Service`.
public struct BackgroundServiceMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
