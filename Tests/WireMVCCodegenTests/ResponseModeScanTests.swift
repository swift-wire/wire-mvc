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

    // MARK: - The floor and the declarations cannot drift

    /// `builtInResponseModes` restates what `Macros.swift` declares, because the `@Controller` macro path has
    /// not parsed that file. Two statements of one fact drift, so this reads the real file and compares.
    @Test("the built-in floor matches the declarations in Macros.swift")
    func builtInFloorMatchesTheDeclarations() throws {
        let macros = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WireMVCCodegenTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
            .appendingPathComponent("Sources/WireMVC/Macros.swift")
        let declared = scanResponseModes(in: [Parser.parse(source: try String(contentsOf: macros, encoding: .utf8))])

        #expect(!declared.isEmpty, "the declarations are annotated at all")
        #expect(declared == builtInResponseModes)
    }
}
