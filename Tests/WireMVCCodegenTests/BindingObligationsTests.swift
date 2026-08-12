import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// The attribute-reading path for user-defined request bindings.
///
/// This is the prototype the design note asks for before anything is built on it
/// (`Documentation/Notes/ExtensibleBindingsAndResponses.md`). The claim under test is narrow and specific:
/// **the codegen can learn a binding's obligations from its declaration, in a different file and a different
/// module from the use site.** Everything else in that design rests on it, and it had been asserted twice
/// and checked never.
@Suite("Request-binding obligations")
struct BindingObligationsTests {

    private func scan(_ sources: String...) -> [String: BindingObligations] {
        scanRequestBindings(in: sources.map { Parser.parse(source: $0) })
    }

    // MARK: - The claim

    @Test("a binding's obligations are read from its declaration in another file")
    func acrossFiles() {
        // Two files, as the plugin passes them: the dependency declaring the binding, and the consumer
        // using it. Nothing links them but the name.
        let found = scan(
            """
            @RequestBinding(.body)
            public struct FormBody<Value: Decodable & Sendable>: RequestBound {}
            """,
            """
            @Controller("/session")
            struct SessionController {
                @Post @HTMLResponse
                func create(@FormBody input: Login) async throws -> some HTML { Page() }
            }
            """
        )
        #expect(found["FormBody"] == .body)
    }

    @Test("the obligations are read, not guessed")
    func readsEachObligation() {
        let found = scan(
            """
            @RequestBinding(.body)
            public struct FormBody<V>: RequestBound {}
            @RequestBinding(.path)
            public struct Slug<V>: RequestBound {}
            @RequestBinding(.body, .path)
            public struct Odd<V>: RequestBound {}
            @RequestBinding
            public struct Plain<V>: RequestBound {}
            """
        )
        #expect(found["FormBody"] == .body)
        #expect(found["Slug"] == .path)
        #expect(found["Odd"] == [.body, .path])
        #expect(found["Plain"] == [], "a bare marker states no obligation — recognition needs no flag")
    }

    /// Recognition is "the declaration exists", so an unannotated type is not a binding and the use site
    /// keeps today's clear diagnostic rather than degrading into a type error further from the cause.
    @Test("a type without the attribute is not a binding")
    func unannotatedIsNotABinding() {
        let found = scan("public struct NotABinding<V>: RequestBound {}")
        #expect(found["NotABinding"] == nil)
    }

    // MARK: - Shapes the scan must survive

    @Test("the built-ins can be declared the same way")
    func builtInsNeedNoSpecialCase() {
        // `@Path` stops being privileged: its placeholder validation is just the `.path` obligation.
        let found = scan(
            """
            @RequestBinding(.path) public struct Path<Value>: RequestBound {}
            @RequestBinding public struct Query<Value>: RequestBound {}
            @RequestBinding public struct Header<Value>: RequestBound {}
            @RequestBinding(.body) public struct JSONBody<Value>: RequestBound {}
            """
        )
        #expect(found["Path"] == .path)
        #expect(found["Query"] == [])
        #expect(found["Header"] == [])
        #expect(found["JSONBody"] == .body)
    }

    @Test("a binding nested in a namespace is still found")
    func nestedDeclaration() {
        let found = scan(
            """
            public enum Bindings {
                @RequestBinding(.body)
                public struct Yaml<Value>: RequestBound {}
            }
            """
        )
        #expect(found["Yaml"] == .body, "the scan walks; it does not depend on where the author put it")
    }

    @Test("classes and actors declare bindings too")
    func nonStructDeclarations() {
        let found = scan(
            """
            @RequestBinding(.body) public final class BoxedBody<V>: RequestBound {}
            @RequestBinding public actor Session<V>: RequestBound {}
            """
        )
        #expect(found["BoxedBody"] == .body)
        #expect(found["Session"] == [])
    }

    @Test("a fully qualified obligation is read the same as a shorthand one")
    func qualifiedArgument() {
        let found = scan("@RequestBinding(BindingObligations.body) public struct Q<V>: RequestBound {}")
        #expect(found["Q"] == .body)
    }

    /// A known limit, pinned so it is a decision rather than a surprise. The attribute must sit on the type
    /// declaration; on an extension it is not seen. That fails *safely* — the binding is simply unrecognised,
    /// so the use site gets today's clear "needs a binding annotation" diagnostic rather than misbehaving.
    /// Worth a targeted diagnostic later if anyone trips over it.
    @Test("the attribute is not read from an extension")
    func attributeOnExtensionIsNotSeen() {
        let found = scan(
            """
            public struct FormBody<V>: RequestBound {}
            @RequestBinding(.body)
            extension FormBody {}
            """
        )
        #expect(found["FormBody"] == nil)
    }

    // MARK: - The decision it enables

    /// The whole point: the two hardcodes this replaces. `routeHasBody` currently tests
    /// `binding.wrapper == "JSONBody"` (`RouteCodegen.swift:638`); with obligations it becomes a lookup, and
    /// a user's `@FormBody` route collects its body without WireMVC knowing the name.
    @Test("a discovered body binding answers what the JSONBody hardcode answers")
    func replacesTheBodyHardcode() {
        let found = scan(
            """
            @RequestBinding(.body) public struct JSONBody<V>: RequestBound {}
            @RequestBinding(.body) public struct FormBody<V>: RequestBound {}
            @RequestBinding public struct Header<V>: RequestBound {}
            """
        )
        func routeReadsBody(_ wrappers: [String]) -> Bool {
            wrappers.contains { found[$0, default: []].contains(.body) }
        }
        #expect(routeReadsBody(["Path", "JSONBody"]))
        #expect(routeReadsBody(["FormBody"]), "the case the hardcode cannot answer today")
        #expect(!routeReadsBody(["Path", "Header"]))
    }

    /// And the diagnostic that falls out for free — a request has one body.
    @Test("two body bindings on one route are countable at compile time")
    func twoBodyBindingsAreCountable() {
        let found = scan(
            """
            @RequestBinding(.body) public struct JSONBody<V>: RequestBound {}
            @RequestBinding(.body) public struct FormBody<V>: RequestBound {}
            """
        )
        let bodies = ["JSONBody", "FormBody"].filter { found[$0, default: []].contains(.body) }
        #expect(bodies.count == 2, "countable, so diagnosable — nothing says this today")
    }
}

/// The seam, exercised through `generateRouteContributors` — the entry point `WireMVCRouteGen` calls.
///
/// The two hardcodes this replaces are `routeBindingWrappers` (recognition) and `== "JSONBody"` (body
/// collection). Both are answered here by a binding WireMVC has never heard of, declared in a *different
/// file* — which is how the plugin passes a dependency's sources.
@Suite("User-declared bindings, end to end")
struct UserBindingIntegrationTests {

    private func generate(_ sources: String...) -> (source: String, diagnostics: [String]) {
        let result = generateRouteContributors(
            files: sources.enumerated().map { (path: "File\($0.offset).swift", source: $0.element) },
            testEntry: false,
            extraImports: [],
            sourceModules: [:],
            consumerModule: nil
        )
        return (result.source, result.diagnostics.map(\.message.message))
    }

    private static let formBodyDeclaration = """
        @RequestBinding(.body)
        public struct FormBody<Value: Decodable & Sendable>: RequestBound {}
        """

    @Test("a user binding is recognised, so its parameter is not diagnosed")
    func recognised() {
        let (source, diagnostics) = generate(
            Self.formBodyDeclaration,
            """
            @Controller("/session")
            public struct SessionController {
                @Post
                @JSONResponse
                public func create(@FormBody input: Login) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
        // Emission was already generic — the binding is called exactly like a built-in.
        #expect(source.contains("FormBody<Login>.bind("))
    }

    @Test("a user body binding makes the terminal collect the request body")
    func collectsTheBody() {
        let (source, _) = generate(
            Self.formBodyDeclaration,
            """
            @Controller("/session")
            public struct SessionController {
                @Post
                @JSONResponse
                public func create(@FormBody input: Login) async throws -> Token { Token() }
            }
            """
        )
        #expect(source.contains("WireMVCRequest.collectBody(reader)"), "the == \"JSONBody\" hardcode's job")
        #expect(source.contains("body: requestBody"))
    }

    @Test("a user binding with no body obligation collects nothing")
    func noObligationNoCollection() {
        let (source, diagnostics) = generate(
            """
            @RequestBinding
            public struct Locale<Value: Sendable>: RequestBound {}
            """,
            """
            @Controller("/pages")
            public struct PagesController {
                @Get
                @JSONResponse
                public func page(@Locale locale: String) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
        #expect(source.contains("Locale<String>.bind("))
        #expect(!source.contains("collectBody"), "no obligation, no read")
    }

    /// The exact combination the `/pages/echo` fixture serves: a body binding WireMVC has never heard of, on
    /// a **streaming** route. Both halves were separately broken at some point — the binding unrecognised,
    /// and the collection emitted where the reader cannot be consumed — so the pair is worth pinning here as
    /// well as in the fixture, which only a plugin-run build exercises.
    @Test("a user body binding on a streaming route uses the collecting terminal")
    func userBodyBindingOnAStreamingRoute() {
        let (source, diagnostics) = generate(
            Self.formBodyDeclaration,
            """
            @Controller("/session")
            public struct SessionController {
                @Post("/echo")
                @HTMLResponse
                public func echo(@FormBody input: Login) async throws -> some HTML { Page(input) }
            }
            """
        )
        #expect(diagnostics.isEmpty, "got: \(diagnostics)")
        #expect(source.contains("collectingBodyFrom: reader"))
        #expect(source.contains("building: { requestBody in"))
        #expect(source.contains("FormBody<Login>.bind("))
        #expect(source.contains("body: requestBody"))
    }

    @Test("an unknown attribute is still diagnosed, not silently bound")
    func unknownIsStillDiagnosed() {
        let (_, diagnostics) = generate(
            """
            @Controller("/pages")
            public struct PagesController {
                @Get
                @JSONResponse
                public func page(@Pth id: String) async throws -> Token { Token() }
            }
            """
        )
        #expect(diagnostics.contains { $0.contains("needs a binding annotation") })
    }
}
