// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import WireMVCMacros
import XCTest

private let macros: [String: any Macro.Type] = [
    "MiddlewareFactory": MiddlewareFactoryMacro.self
]

final class MiddlewareFactoryMacroTests: XCTestCase {
    /// `@MiddlewareFactory` expands to nothing — the plugin reads it off the type. With `@Factory` on
    /// the same type there's no diagnostic; `@Factory` (not a macro here) is left verbatim.
    func testNoOpWhenFactoryPresent() {
        assertMacroExpansion(
            """
            @Factory(Keys.factory)
            @MiddlewareFactory
            struct Mw {
            }
            """,
            expandedSource: """
                @Factory(Keys.factory)
                struct Mw {
                }
                """,
            macros: macros
        )
    }

    /// Without `@Factory` there is no template to map — the producer-side mirror of a stray adapter alias.
    func testDiagnosesWithoutFactory() {
        assertMacroExpansion(
            """
            @MiddlewareFactory(.responseSender)
            struct Mw {
            }
            """,
            expandedSource: """
                struct Mw {
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message:
                        "@MiddlewareFactory requires @Factory on the same type — it supplies the box-role mapping for a factory template. Add @Factory(key) to make this a Wire factory template.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }
}
