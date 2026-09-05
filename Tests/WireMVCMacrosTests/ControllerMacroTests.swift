// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import WireMVCMacros
import XCTest

private let macros: [String: any Macro.Type] = [
    "Controller": ControllerMacro.self,
    "Get": RouteMarkerMacro.self,
    "Post": RouteMarkerMacro.self,
    "Put": RouteMarkerMacro.self,
    "Patch": RouteMarkerMacro.self,
    "Delete": RouteMarkerMacro.self,
    "JSONResponse": RouteMarkerMacro.self,
    "ResponseStatus": RouteMarkerMacro.self,
    "RawRoute": RouteMarkerMacro.self,
    "Middleware": RouteMarkerMacro.self,
]

/// `@Controller` is a **marker**. It expands to nothing: the route-contributor proxy (struct +
/// witness) is generated in the consumer module under plugin orchestration (WireGen emits the struct,
/// `WireMVCRouteGen` the witness — see `WireMVCCodegenTests` for the route codegen). These tests pin that
/// the macro adds no peer and, in particular, no longer diagnoses (route-shape validation moved to the
/// tool, at build time).
final class ControllerMacroTests: XCTestCase {
    func testControllerAddsNoPeer() {
        assertMacroExpansion(
            """
            @Controller("/todos")
            struct Todos {
                @Get("/{id}")
                @JSONResponse
                func get(@Path id: String) async throws -> Todo {
                    fatalError()
                }
            }
            """,
            expandedSource: """
                struct Todos {
                    func get(@Path id: String) async throws -> Todo {
                        fatalError()
                    }
                }
                """,
            macros: macros
        )
    }

    /// Even with middleware and a factory key, the marker emits nothing — the proxy (which would hold the
    /// lifted `_wireFactory_<key>`) is the plugin's to generate.
    func testControllerWithMiddlewareAddsNoPeer() {
        assertMacroExpansion(
            """
            @Controller("/x")
            @Middleware(Keys.session)
            struct C {
                @Get("/y")
                @ResponseStatus(.noContent)
                func f() async throws {
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f() async throws {
                    }
                }
                """,
            macros: macros
        )
    }

    /// A route the tool would reject (unannotated parameter) draws **no** diagnostic from the marker —
    /// route-shape validation is the tool's job now, not the macro's.
    func testMarkerDoesNotDiagnoseRouteShape() {
        assertMacroExpansion(
            """
            @Controller
            struct C {
                @Get("/x")
                @JSONResponse
                func f(id: String) -> Int {
                    0
                }
            }
            """,
            expandedSource: """
                struct C {
                    func f(id: String) -> Int {
                        0
                    }
                }
                """,
            diagnostics: [],
            macros: macros
        )
    }
}
