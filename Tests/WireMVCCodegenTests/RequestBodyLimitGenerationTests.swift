// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireMVCCodegen

/// `@RequestBodyLimit` and `@BytesBody` in the generator: which limit reaches which terminal argument, which
/// scope wins, and the four places the annotation is refused. The fixtures prove the emission compiles and
/// serves; these say what was emitted.
@Suite("Request body limit generation")
struct RequestBodyLimitGenerationTests {

    private static let streamingBinding = """
        @RequestBinding(.readerBody)
        public struct Upload<Value>: RequestBodyReading {}
        """

    private func generate(_ controller: String) -> (source: String, diagnostics: [WireMVCDiagnostic]) {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                ("Upload.swift", Self.streamingBinding), ("Controller.swift", controller),
            ]
        )
        // Whitespace collapsed, so an assertion can name consecutive arguments without restating the
        // generator's indentation.
        let flattened = result.source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (flattened, result.diagnostics.filter { $0.message.severity == .error }.map(\.message))
    }

    // MARK: - Emission

    /// A collecting route always hands the terminal the request, so it can refuse a `Content-Length` over the
    /// default limit before reading — and names no `maximumBodySize:` of its own, leaving the default to the
    /// terminal.
    @Test func aCollectingRouteHandsOverTheRequestAndTakesTheDefault() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Put("/{name}") @JSONResponse
                public func put(@Path name: String, @BytesBody bytes: [UInt8]) async throws -> Int { bytes.count }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(source.contains("collectingBodyFrom: reader, request: request, building:"))
        #expect(!source.contains("maximumBodySize:"))
        #expect(source.contains("BytesBody<[UInt8]>.bind("), "BytesBody is found by its declaration, like JSONBody")
    }

    /// The argument is emitted verbatim, so a limit the app already names is spelled once and the compiler
    /// checks its type where the terminal receives it.
    @Test func aRouteLimitIsEmittedVerbatim() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Put("/{name}") @JSONResponse @RequestBodyLimit(Artwork.maximumSize)
                public func put(@Path name: String, @BytesBody bytes: [UInt8]) async throws -> Int { bytes.count }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(source.contains("maximumBodySize: Artwork.maximumSize,"))
    }

    /// Innermost wins: the route's limit beats the controller's, and a route that says none takes the
    /// controller's.
    @Test func theRoutesLimitBeatsTheControllers() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files") @RequestBodyLimit(4_000_000)
            public struct Files {
                @Put("/big") @JSONResponse
                public func big(@BytesBody bytes: [UInt8]) async throws -> Int { bytes.count }
                @Put("/small") @JSONResponse @RequestBodyLimit(64)
                public func small(@BytesBody bytes: [UInt8]) async throws -> Int { bytes.count }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(source.contains("maximumBodySize: 4_000_000,"))
        #expect(source.contains("maximumBodySize: 64,"))
    }

    /// A controller's limit is a policy for the routes it can reach. A route with no body and a raw route are
    /// skipped, not failed — otherwise neither could share a controller with an upload.
    @Test func aControllerLimitSkipsRoutesWithoutABodyAndRawRoutes() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files") @RequestBodyLimit(4_000_000)
            public struct Files {
                @Get("/count") @JSONResponse
                public func count() async throws -> Int { 0 }
                @Get("/raw") @RawRoute
                public func raw<S: HTTPResponseSender & ~Copyable>(responseSender: consuming S) async throws
                where S.Writer: ~Copyable {}
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(!source.contains("maximumBodySize:"))
    }

    /// A streamed binding's route takes the bounded overload only when it names a limit: the request and the
    /// limit together select the terminal that wraps the reader.
    @Test func aStreamedRouteWithALimitSelectsTheBoundedOverload() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @JSONResponse @RequestBodyLimit(1024)
                public func receive(@Upload file: Receipt) async throws -> Receipt { file }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(source.contains("lendingBodyFrom: reader, request: request, maximumBodySize: 1024,"))
    }

    /// Without a limit a streamed route is emitted exactly as before: the binding sees the reader unwrapped,
    /// and the terminal is handed no request it would not use.
    @Test func aStreamedRouteWithoutALimitIsUnchanged() {
        let (source, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Post @JSONResponse
                public func receive(@Upload file: Receipt) async throws -> Receipt { file }
            }
            """
        )
        #expect(diagnostics.isEmpty, "\(diagnostics)")
        #expect(source.contains("lendingBodyFrom: reader, building:"))
        #expect(!source.contains("maximumBodySize:"))
    }

    // MARK: - Diagnostics

    @Test func aLimitThatIsNotPositiveIsDiagnosed() {
        for literal in ["0", "-1"] {
            let (_, diagnostics) = generate(
                """
                @Singleton @Controller("/files")
                public struct Files {
                    @Put @JSONResponse @RequestBodyLimit(\(literal))
                    public func put(@BytesBody bytes: [UInt8]) async throws -> Int { bytes.count }
                }
                """
            )
            #expect(
                diagnostics.contains {
                    if case .requestBodyLimitNotPositive(literal, scope: "route") = $0 { true } else { false }
                },
                "\(literal): \(diagnostics)"
            )
        }
    }

    @Test func aSecondLimitAtOneScopeIsDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Singleton @Controller("/files") @RequestBodyLimit(10) @RequestBodyLimit(20)
            public struct Files {
                @Put @JSONResponse
                public func put(@BytesBody bytes: [UInt8]) async throws -> Int { bytes.count }
            }
            """
        )
        #expect(
            diagnostics.contains {
                if case .requestBodyLimitDuplicate(scope: "controller") = $0 { true } else { false }
            },
            "\(diagnostics)"
        )
    }

    /// On a route that reads no body the annotation would limit nothing, which is more likely a mistake — a
    /// forgotten binding, or the annotation on the wrong route — than a choice.
    @Test func aRouteLimitWithoutABodyIsDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Get @JSONResponse @RequestBodyLimit(1024)
                public func count() async throws -> Int { 0 }
            }
            """
        )
        #expect(
            diagnostics.contains { if case .requestBodyLimitWithoutBody("count") = $0 { true } else { false } },
            "\(diagnostics)"
        )
    }

    @Test func aRouteLimitOnARawRouteIsDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Singleton @Controller("/files")
            public struct Files {
                @Put("/raw") @RawRoute @RequestBodyLimit(1024)
                public func raw<S: HTTPResponseSender & ~Copyable>(responseSender: consuming S) async throws
                where S.Writer: ~Copyable {}
            }
            """
        )
        #expect(
            diagnostics.contains { if case .requestBodyLimitOnRawRoute("raw") = $0 { true } else { false } },
            "\(diagnostics)"
        )
    }
}
