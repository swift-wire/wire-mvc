// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Testing

@testable import WireMVCCodegen

/// The `@NotFound` fallback, typed: registered through the same terminal a route uses, with no template.
/// These pin the emitted registration and the three diagnostics a fallback can earn. The runtime half —
/// status, body, `Content-Length`, a global header — is pinned by `WireMVCBootstrapExample`'s fallback.
/// The raw fallback is `RouteContributorGenerationTests.notFoundHandlerRegistersAsFallback`.
@Suite("@NotFound generation")
struct NotFoundGenerationTests {

    private func generate(
        _ bootstrapMembers: String,
        attributes: String = ""
    ) -> (
        source: String, diagnostics: [WireMVCDiagnostic]
    ) {
        let source = """
            struct Problem: Codable { var detail: String }
            struct Lost: Error {}

            @Singleton
            @WireMVCBootstrap
            \(attributes)
            struct AppBootstrap {
                func createServer() throws -> NIOHTTPServer { fatalError() }
            \(bootstrapMembers)
            }
            """
        let rendered = generateRouteContributors(files: WireMVCBuiltIns.declarationFiles + [("App.swift", source)])
        return (rendered.source, rendered.diagnostics.map(\.message))
    }

    /// The registration, extracted from the entry: everything from the coding local (or the register call)
    /// to the `registerMethodNotAllowed` that follows it.
    private func registration(in source: String) -> String {
        guard let start = source.range(of: "builder.registerNotFound"),
            let end = source.range(of: "builder.registerMethodNotAllowed", range: start.upperBound..<source.endIndex)
        else { return "" }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test func aJSONFallbackGoesThroughTheTypedTerminal() {
        let rendered = generate(
            """
                @NotFound
                @JSONResponse(status: .notFound)
                func notFound() -> Problem { Problem(detail: "not found") }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        let registration = registration(in: rendered.source)
        // No primitive is taken by hand: the terminal owns the sender and the registry.
        #expect(registration.contains("builder.registerNotFound { _, requestContext, _, _, responseSender in"))
        #expect(registration.contains("try await wireMVCBufferedTerminal("))
        #expect(registration.contains("responseHeaders: wireMVCResponseHeaderDrain,"))
        // Called through the entry's `bootstrap` local, not a proxy's subject field.
        #expect(registration.contains("bootstrap.notFound()"))
        #expect(registration.contains("status: .notFound"))
        // The app's coding, through the local bound ahead of the registration.
        #expect(registration.contains("coding: wireMVCNotFoundCoding"))
        let local = rendered.source.range(of: "let wireMVCNotFoundCoding = WireMVCCoding.default")
        let register = rendered.source.range(of: "builder.registerNotFound")
        #expect(local != nil)
        if let local, let register { #expect(local.upperBound < register.lowerBound) }
        #expect(!rendered.source.contains("wireMVCAppCoding"))
    }

    @Test func aBootstrapCodingIsTheFallbacksCoding() {
        let rendered = generate(
            """
                @NotFound
                @JSONResponse(status: .notFound)
                func notFound() -> Problem { Problem(detail: "not found") }
            """,
            attributes: "@Coding(AppCoding.self)"
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(rendered.source.contains("let wireMVCNotFoundCoding = graph."))
    }

    @Test func aBodilessFallbackBindsNoCodingLocal() {
        let rendered = generate(
            """
                @NotFound
                @ResponseStatus(.gone)
                func notFound() {}
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(registration(in: rendered.source).contains("return .status(.gone"))
        #expect(!rendered.source.contains("wireMVCNotFoundCoding"))
    }

    @Test func aBodilessTupleNeedsNoAnnotation() {
        let rendered = generate(
            """
                @NotFound
                func notFound() -> (status: HTTPResponse.Status, headers: HTTPFields) {
                    (.notFound, [.cacheControl: "no-store"])
                }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(registration(in: rendered.source).contains("bootstrap.notFound()"))
    }

    @Test func queryAndHeaderBindingsBindOffTheRequest() {
        let rendered = generate(
            """
                @NotFound
                @JSONResponse(status: .notFound)
                func notFound(@Query hint: String?, @Header("X-Trace") trace: String?) -> Problem {
                    Problem(detail: hint ?? trace ?? "not found")
                }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        let registration = registration(in: rendered.source)
        #expect(
            registration.contains(
                "builder.registerNotFound { request, requestContext, pathParameters, _, responseSender in"
            )
        )
        #expect(registration.contains("Query<String>.bindOptional(name: \"hint\""))
        #expect(registration.contains("Header<String>.bindOptional(name: \"X-Trace\""))
        #expect(registration.contains("bootstrap.notFound(hint: hint, trace: trace)"))
    }

    @Test func aBodyBindingCollectsTheBody() {
        let rendered = generate(
            """
                @NotFound
                @JSONResponse(status: .notFound)
                func notFound(@JSONBody body: Problem) -> Problem { body }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        let registration = registration(in: rendered.source)
        #expect(registration.contains("collectingBodyFrom: reader,"))
        #expect(registration.contains("building: { requestBody in"))
    }

    /// Route scope first, then the Bootstrap's — the Bootstrap is the global tier, so there is nothing
    /// between them.
    @Test func errorTiersAreTheHandlersThenTheBootstraps() {
        let rendered = generate(
            """
                @NotFound
                @JSONResponse(status: .notFound)
                @ErrorResponse(Lost.self, .gone)
                func notFound() throws -> Problem { throw Lost() }
            """,
            attributes: "@ErrorResponse(Lost.self, .notFound)"
        )
        #expect(rendered.diagnostics.isEmpty)
        let registration = registration(in: rendered.source)
        let route = registration.range(of: "(wireMVCError is Lost ? WireMVCOutcome.status(.gone) : nil)")
        let global = registration.range(of: "(wireMVCError is Lost ? WireMVCOutcome.status(.notFound) : nil)")
        #expect(route != nil)
        #expect(global != nil)
        if let route, let global { #expect(route.lowerBound < global.lowerBound) }
    }

    @Test func aStreamingModeUsesTheStreamingTerminal() {
        let rendered = generate(
            """
                @NotFound
                @HTMLResponse(status: .notFound)
                func notFound() -> some HTML { NotFoundPage() }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        #expect(registration(in: rendered.source).contains("try await wireMVCStreamingTerminal("))
    }

    @Test func aFallbackStatingNoResponseIsDiagnosed() {
        let rendered = generate(
            """
                @NotFound
                func notFound() -> Problem { Problem(detail: "not found") }
            """
        )
        #expect(
            rendered.diagnostics.contains { if case .notFoundWithoutResponse("notFound") = $0 { true } else { false } }
        )
        // Falls back to the synthesised 404, so the entry still builds around the diagnostic.
        let registration = registration(in: rendered.source)
        #expect(registration.contains("try await WireMVCOutcome.status("))
        #expect(!registration.contains("bootstrap.notFound"))
    }

    @Test func aPathBindingIsDiagnosed() {
        let rendered = generate(
            """
                @NotFound
                @JSONResponse(status: .notFound)
                func notFound(@Path id: String) -> Problem { Problem(detail: id) }
            """
        )
        #expect(rendered.diagnostics.count == 1)
        #expect(
            rendered.diagnostics.contains {
                if case .notFoundPathBinding("notFound", parameter: "id") = $0 { true } else { false }
            }
        )
    }

    @Test func aRouteCodingIsDiagnosed() {
        let rendered = generate(
            """
                @NotFound
                @JSONResponse(status: .notFound)
                @Coding(OtherCoding.self)
                func notFound() -> Problem { Problem(detail: "not found") }
            """
        )
        #expect(rendered.diagnostics.contains { if case .notFoundRouteCoding("notFound") = $0 { true } else { false } })
    }

    /// The raw form is unchanged, and still needs no response annotation.
    @Test func aRawFallbackIsStillRaw() {
        let rendered = generate(
            """
                @NotFound
                @RawRoute
                func notFound<Sender: HTTPResponseSender & ~Copyable>(
                    responseSender: consuming sending Sender
                ) async throws where Sender.Writer: ~Copyable { fatalError() }
            """
        )
        #expect(rendered.diagnostics.isEmpty)
        let registration = registration(in: rendered.source)
        #expect(registration.contains("try await bootstrap.notFound(responseSender: ResponseHeaderApplyingSender("))
        #expect(!rendered.source.contains("wireMVCNotFoundCoding"))
    }
}
