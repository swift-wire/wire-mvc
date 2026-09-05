// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// The attribute-reading path for response modes — the mirror of `BindingObligationsTests`, and the same
/// narrow claim: **the codegen can learn a mode's (terminal, codec, client body) triple from its declaration,
/// in a different file and a different module from the route that uses it.**
///
/// The one structural difference from the request side is that a response annotation must be a *macro*
/// declaration, because it attaches to a function and a property wrapper cannot. So what is under test is
/// specifically that a `macro` decl carries a custom attribute and that `MacroDeclSyntax.attributes` exposes
/// its labelled arguments intact.
@Suite("Response-mode declarations")
struct ResponseModeScanTests {

    private func scan(_ sources: String...) -> [String: DeclaredResponseMode] {
        scanResponseModes(in: sources.map { Parser.parse(source: $0) })
    }

    // MARK: - The claim

    @Test("a mode's pair is read from its macro declaration in another file")
    func acrossFiles() {
        let found = scan(
            """
            @ResponseMode(.buffered, codec: "YAMLCodec")
            @attached(peer)
            public macro YAMLResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            """,
            """
            @Controller("/report")
            struct ReportController {
                @Get @YAMLResponse
                func report() async throws -> Report { Report() }
            }
            """
        )
        #expect(found["YAMLResponse"] == DeclaredResponseMode(terminal: .buffered, codec: "YAMLCodec"))
    }

    @Test("each field is read, not guessed")
    func readsEachField() {
        let found = scan(
            """
            @ResponseMode(.streaming, codec: "SSEProducer", client: .text)
            @attached(peer)
            public macro EventStream() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

            @ResponseMode(.bodiless)
            @attached(peer)
            public macro NoContent() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            """
        )
        #expect(
            found["EventStream"]
                == DeclaredResponseMode(terminal: .streaming, codec: "SSEProducer", clientBody: .text)
        )
        #expect(found["NoContent"] == DeclaredResponseMode(terminal: .bodiless, codec: nil))
        #expect(found["NoContent"]?.clientBody == .decoded, "the client body defaults rather than being required")
    }

    /// A mode declaration usually comes in overloads — bare and `(status:)` — and both carry the attribute.
    /// They must agree, and reading either one must give the same answer.
    @Test("overloads of one mode collapse to one entry")
    func overloadsAgree() {
        let found = scan(
            """
            @ResponseMode(.buffered, codec: "YAMLCodec")
            @attached(peer)
            public macro YAMLResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            @ResponseMode(.buffered, codec: "YAMLCodec")
            @attached(peer)
            public macro YAMLResponse(status: HTTPResponse.Status) =
                #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            """
        )
        #expect(found.count == 1)
        #expect(found["YAMLResponse"]?.codec == "YAMLCodec")
    }

    @Test("the codec is the string's value, not its literal text")
    func codecIsUnquoted() {
        let found = scan(
            """
            @ResponseMode(.buffered, codec: "YAMLCodec")
            @attached(peer)
            public macro YAMLResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            """
        )
        // A spelling with quotes around it would be emitted as `"YAMLCodec".encodeResponseBody(…)`.
        #expect(found["YAMLResponse"]?.codec == "YAMLCodec")
    }

    @Test("a qualified terminal reads the same as a leading-dot one")
    func qualifiedTerminal() {
        let found = scan(
            """
            @ResponseMode(WireMVCResponseTerminal.streaming, codec: "P", client: WireMVCResponseClientBody.text)
            @attached(peer)
            public macro M() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            """
        )
        #expect(found["M"] == DeclaredResponseMode(terminal: .streaming, codec: "P", clientBody: .text))
    }

    // MARK: - What is not a mode

    @Test("an unannotated macro is not a mode")
    func unannotatedMacroIgnored() {
        let found = scan(
            """
            @attached(peer)
            public macro Get(_ path: String) = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            """
        )
        #expect(found.isEmpty)
    }

    @Test("an unreadable terminal yields no mode rather than a wrong one")
    func unknownTerminalIgnored() {
        let found = scan(
            """
            @ResponseMode(.trailered, codec: "C")
            @attached(peer)
            public macro M() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
            """
        )
        #expect(found.isEmpty, "a mode WireMVC cannot act on must not be half-registered")
    }

}

/// Every mode kind, declared **outside** WireMVC, reaches both the witness and the client.
///
/// The counterpart of `noRouteIsSilentlyDropped`, which pins the same property for the built-ins. It exists
/// because the first cut of the response seam failed it: a `.bodiless` mode declared outside WireMVC emitted
/// an **empty witness and no diagnostic**, because the status read still named `@ResponseStatus` while every
/// other decision had moved to a lookup. A route that disappears reports nothing, so only a test that asserts
/// presence can catch it.
@Suite("User-declared modes reach the generated code")
struct UserDeclaredModeCoverageTests {

    /// One mode of each terminal, none of them WireMVC's.
    private static let source = """
        @ResponseMode(.buffered, codec: "CSVCodec")
        @attached(peer)
        public macro CSVResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
        @ResponseMode(.buffered, codec: "CSVCodec")
        @attached(peer)
        public macro CSVResponse(status: HTTPResponse.Status) =
            #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

        @ResponseMode(.streaming, codec: "SSEProducer", client: .text)
        @attached(peer)
        public macro EventStream() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

        @ResponseMode(.bodiless)
        @attached(peer)
        public macro NoContent(_ status: HTTPResponse.Status) =
            #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

        @ResponseMode(.bodiless)
        @attached(peer)
        public macro Accepted(status: HTTPResponse.Status) =
            #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

        @Singleton @Controller("/things")
        struct Things {
            @Get("/ledger") @CSVResponse
            func ledger() async throws -> Ledger { Ledger() }
            @Get("/events") @EventStream
            func events() async throws -> EventSource { EventSource() }
            @Delete("/{id}") @NoContent(.noContent)
            func remove(@Path id: String) async throws {}
            @Post("/queue") @Accepted(status: .accepted)
            func queue() async throws {}
        }
        """

    private static func generated() -> (witness: String, client: String, diagnostics: [String]) {
        let parsed = Parser.parse(source: source)
        let modes = WireMVCBuiltIns.modes.merging(scanResponseModes(in: [parsed])) { _, scanned in scanned }
        for statement in parsed.statements {
            guard let declaration = statement.item.as(StructDeclSyntax.self),
                let controller = ControllerDeclaration(declaration)
            else { continue }
            let witness = renderRouteContributorExtension(
                controller: controller,
                pathPrefix: "/things",
                factoryKeys: [],
                discoveredBindings: WireMVCBuiltIns.bindings,
                discoveredModes: modes
            )
            let client = renderControllerClient(
                controller: controller,
                pathPrefix: "/things",
                discoveredBindings: WireMVCBuiltIns.bindings,
                discoveredModes: modes
            ).source
            return (witness.source, client ?? "", witness.diagnostics.map { $0.message.message })
        }
        Issue.record("no controller in the fixture source")
        return ("", "", [])
    }

    @Test("every user-declared mode registers a route")
    func everyModeReachesTheWitness() {
        let generated = Self.generated()
        #expect(generated.diagnostics.isEmpty, "\(generated.diagnostics)")
        for path in ["/things/ledger", "/things/events", "/things/{id}", "/things/queue"] {
            #expect(generated.witness.contains(#"path: "\#(path)""#), "'\(path)' is missing from the witness")
        }
    }

    @Test("every user-declared mode reaches the typed client")
    func everyModeReachesTheClient() {
        let client = Self.generated().client
        for route in ["ledger", "events", "remove", "queue"] {
            #expect(client.contains("func \(route)("), "route '\(route)' is missing from the client")
        }
    }

    /// Each terminal emits its own shape, through the mode's own codec.
    @Test("each terminal emits through the mode's declaration")
    func eachTerminalEmitsItsOwnShape() {
        let generated = Self.generated()
        #expect(generated.witness.contains("try CSVCodec.encodeResponseBody(try await self._wireSubject.ledger()"))
        #expect(generated.witness.contains("producer: SSEProducer(try await self._wireSubject.events())"))
        #expect(generated.witness.contains("return .status(.noContent"))
        #expect(generated.witness.contains("return .status(.accepted"), "the labelled spelling too")

        #expect(generated.client.contains("try CSVCodec<Ledger>.decodeResponseBody("))
        #expect(generated.client.contains("return wireMVCResponse.bodyText"), "a `.text` mode hands back markup")
    }

    /// A bodiless mode that names no status is **diagnosed**, not dropped. The route carrying nothing but a
    /// status has to say which one, and the old behaviour was to emit nothing and report nothing.
    @Test("a bodiless mode with no status is reported")
    func bodilessWithoutStatusIsDiagnosed() {
        let source = """
            @ResponseMode(.bodiless)
            @attached(peer)
            public macro Done() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

            @Singleton @Controller("/things")
            struct Things {
                @Delete("/{id}") @Done
                func remove(@Path id: String) async throws {}
            }
            """
        let parsed = Parser.parse(source: source)
        let modes = WireMVCBuiltIns.modes.merging(scanResponseModes(in: [parsed])) { _, scanned in scanned }
        for statement in parsed.statements {
            guard let declaration = statement.item.as(StructDeclSyntax.self),
                let controller = ControllerDeclaration(declaration)
            else { continue }
            let rendered = renderRouteContributorExtension(
                controller: controller,
                pathPrefix: "/things",
                factoryKeys: [],
                discoveredBindings: WireMVCBuiltIns.bindings,
                discoveredModes: modes
            )
            #expect(rendered.diagnostics.contains { $0.message.message.contains("names no status") })
            return
        }
        Issue.record("no controller in the fixture source")
    }
}
