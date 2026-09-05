// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import SwiftSyntax

/// The `try `/`await ` prefix a call to `function` needs — both, one, or neither, read off the
/// declaration's own effect specifiers.
///
/// The generated route closures are `async throws` regardless, so emitting `try await` unconditionally
/// always compiled; it just told the compiler something untrue about half the calls, and every sync or
/// non-throwing handler paid for it with a pair of `UnnecessaryEffectMarker` warnings in a file the
/// consumer cannot edit. A controller is ordinary Swift — `@Get func hello() -> String` is a perfectly
/// good route — so this is the common case, not an edge one.
///
/// The declaration is the whole source of truth: what the *call* needs is exactly what the callee
/// declares, and the generator holds the callee's `FunctionDeclSyntax`. Nothing downstream has to change
/// when a controller author adds or removes `async`/`throws`.
func effectMarkers(of function: FunctionDeclSyntax) -> String {
    effectMarkers(
        isAsync: function.signature.effectSpecifiers?.asyncSpecifier != nil,
        isThrowing: function.signature.effectSpecifiers?.throwsClause != nil
    )
}

/// The same prefix from flags already read off a declaration — `try ` precedes `await `, as Swift spells it.
func effectMarkers(isAsync: Bool, isThrowing: Bool) -> String {
    (isThrowing ? "try " : "") + (isAsync ? "await " : "")
}
