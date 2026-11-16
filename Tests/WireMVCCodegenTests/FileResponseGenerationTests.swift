// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// `@FileResponse` — a streaming mode declared like any other, read off WireMVC's own `Macros.swift`. These
/// pin that the generator needs nothing new for it: the producer spelling from the declaration, the usual
/// streaming terminal, and a typed client that hands back the whole response.
@Suite("@FileResponse generation")
struct FileResponseGenerationTests {

    private func controller(_ source: String) -> ControllerDeclaration {
        let file = Parser.parse(source: source)
        for statement in file.statements {
            if let declaration: any DeclSyntaxProtocol = statement.item.asProtocol(DeclGroupSyntax.self),
                let controller = ControllerDeclaration(declaration)
            {
                return controller
            }
        }
        fatalError("fixture has no controller")
    }

    private func rendered(_ source: String) -> (witness: String, diagnostics: [String]) {
        let result = renderRegisterWireRoutesWitness(
            access: "",
            controller: controller(source),
            pathPrefix: "/media",
            subjectAccessor: "_wireSubject",
            factoryKeys: [],
            discoveredBindings: WireMVCBuiltIns.bindings,
            discoveredModes: WireMVCBuiltIns.modes
        )
        return (result.witness, result.diagnostics.map(\.message.message))
    }

    private let mediaController = """
        @Controller("/media")
        struct MediaController {
            @Get("/{id}")
            @FileResponse
            @ErrorResponse(WireMVCFileError.self, .notFound)
            func media(@Path id: String, @Header("Range") range: String?) throws -> WireMVCFile {
                try WireMVCFile(path: id, contentType: "video/mp4", range: range)
            }
        }
        """

    @Test("WireMVC declares @FileResponse as a streaming mode handing back the whole response")
    func theModeIsDeclared() {
        #expect(
            WireMVCBuiltIns.modes["FileResponse"]
                == DeclaredResponseMode(terminal: .streaming, codec: "WireMVCFileProducer", clientBody: .response)
        )
    }

    @Test("a file route streams its return through WireMVCFileProducer")
    func emitsTheStreamingTerminal() {
        let (witness, diagnostics) = rendered(mediaController)
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(witness.contains("try await wireMVCStreamingTerminal("))
        #expect(witness.contains("producer: WireMVCFileProducer(try self._wireSubject.media(id: id, range: range))"))
        // The route's status is the default; the file states its own `206`/`416` at send time.
        #expect(witness.contains("status: .ok"))
        // The file's error maps like any other, inside the terminal's error chain.
        #expect(witness.contains("WireMVCFileError"))
    }

    @Test("a response tuple's status and headers fold in under the file's head")
    func responseTuple() {
        let (witness, diagnostics) = rendered(
            """
            @Controller("/media")
            struct MediaController {
                @Get("/{id}")
                @FileResponse
                func media(@Path id: String) throws -> (headers: HTTPFields, body: WireMVCFile) {
                    ([.cacheControl: "no-store"], try WireMVCFile(path: id, contentType: "video/mp4"))
                }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(witness.contains("producer: WireMVCFileProducer(wireMVCReturn.body)"))
        #expect(witness.contains("wireMVCReturn.headers"))
    }

    @Test("a Void file route is diagnosed like any body-carrying mode on Void")
    func voidIsDiagnosed() {
        let (_, diagnostics) = rendered(
            """
            @Controller("/media")
            struct MediaController {
                @Get("/{id}")
                @FileResponse
                func media(@Path id: String) throws {}
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("FileResponse") }, "\(diagnostics)")
    }

    @Test("the typed client hands back the whole response")
    func clientReturnsTestResponse() throws {
        let rendered = renderControllerClient(
            controller: controller(mediaController),
            pathPrefix: "/media",
            discoveredBindings: WireMVCBuiltIns.bindings,
            discoveredModes: WireMVCBuiltIns.modes
        ).source
        let source = try #require(rendered)
        #expect(
            source.contains(
                "func media(id: String, range: String?, headers: [String: String] = [:]) async throws -> TestResponse {"
            ),
            "\(source)"
        )
        #expect(source.contains("return try await client.routeResponse(method: \"GET\", path: \"/media/{id}\""))
        // Nothing decodes the bytes: the client is handed them with the head.
        #expect(!source.contains("decodeResponseBody"))
        #expect(!source.contains("bodyText"))
    }
}
