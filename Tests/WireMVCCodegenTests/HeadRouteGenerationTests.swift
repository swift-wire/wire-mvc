// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// `@Head`: an explicit `HEAD` route. The router already answers `HEAD` from a `@Get` route, so the verb is for
/// a route whose `HEAD` should differ — and since a response to `HEAD` carries no body, it is refused a
/// body-carrying response mode rather than left to compute a body that would be dropped.
@Suite("@Head route generation")
struct HeadRouteGenerationTests {
    private func controller(_ source: String) -> ControllerDeclaration {
        let file = Parser.parse(source: source)
        for statement in file.statements {
            if let structDecl = statement.item.as(StructDeclSyntax.self),
                let declaration = ControllerDeclaration(structDecl)
            {
                return declaration
            }
        }
        fatalError("no controller in fixture")
    }

    private func witness(_ source: String) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
        let rendered = renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/files",
            factoryKeys: [],
            discoveredBindings: WireMVCBuiltIns.bindings,
            discoveredModes: WireMVCBuiltIns.modes
        )
        return (rendered.source, rendered.diagnostics)
    }

    @Test func aHeadRouteRegistersTheHeadMethod() {
        let rendered = witness(
            """
            @Controller("/files")
            struct Files {
                @Head("/{name}")
                func probe(@Path name: String) async throws -> (status: HTTPResponse.Status, headers: HTTPFields) {
                    fatalError()
                }
            }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("method: .head"))
        #expect(rendered.source.contains(#"path: "/files/{name}""#))
    }

    @Test func aBareHeadTakesTheControllerPath() {
        let rendered = witness(
            """
            @Controller("/files")
            struct Files {
                @Head
                @ResponseStatus(.noContent)
                func probe() async throws {}
            }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("method: .head"))
        #expect(rendered.source.contains(#"path: "/files""#))
    }

    @Test func aHeadRouteDeclaringABodyIsDiagnosed() {
        let rendered = witness(
            """
            @Controller("/files")
            struct Files {
                @Head("/{name}")
                @JSONResponse
                func probe(@Path name: String) async throws -> Listing { fatalError() }
            }
            """
        )
        #expect(
            rendered.diagnostics.contains {
                if case .headRouteWithBody("probe", "JSONResponse") = $0.message { return true } else { return false }
            }
        )
        #expect(!rendered.source.contains("method: .head"))
    }

    @Test func aHeadRouteStreamingABodyIsDiagnosed() {
        let rendered = witness(
            """
            @Controller("/files")
            struct Files {
                @Head("/page")
                @HTMLResponse
                func page() async throws -> some HTML { fatalError() }
            }
            """
        )
        #expect(
            rendered.diagnostics.contains {
                if case .headRouteWithBody("page", "HTMLResponse") = $0.message { return true } else { return false }
            }
        )
    }

    @Test func aRawHeadRouteIsAllowed() {
        let rendered = witness(
            """
            @Controller("/files")
            struct Files {
                @Head("/{name}")
                @RawRoute
                func probe<Sender: HTTPResponseSender & ~Copyable>(
                    responseSender: consuming sending Sender
                ) async throws where Sender.Writer: ~Copyable {}
            }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("method: .head"))
    }

    @Test func theTypedClientSendsHead() {
        let source =
            renderControllerClient(
                controller: controller(
                    """
                    @Controller("/files")
                    struct Files {
                        @Head("/{name}")
                        @ResponseStatus(.noContent)
                        func probe(@Path name: String) async throws {}
                    }
                    """
                ),
                pathPrefix: "/files",
                discoveredBindings: WireMVCBuiltIns.bindings,
                discoveredModes: WireMVCBuiltIns.modes
            ).source ?? ""
        #expect(source.contains(#"method: "HEAD""#))
        #expect(source.contains("/// `HEAD /files/{name}`"))
    }
}
