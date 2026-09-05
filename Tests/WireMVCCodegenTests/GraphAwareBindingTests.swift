// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// Graph-aware request bindings — a binding that is **also** a `@Scoped(seed:)` graph binding, resolved
/// from the request scope rather than constructed by the witness.
///
/// The seam is what makes this worth having. Binding happens *after* scope entry in every generated route,
/// so the instance the scope built is already in the terminal's frame when the binds run — no reordering,
/// no lazy handle, no assisted parameter. What it buys is that a route taking a `Document` cannot skip the
/// authorisation check, because the check is how a `Document` comes into existence.
@Suite("Graph-aware bindings")
struct GraphAwareBindingTests {
    // MARK: - Harness

    private func controller(_ source: String) -> ControllerDeclaration {
        let file = Parser.parse(source: source)
        for statement in file.statements {
            if let declaration: any DeclSyntaxProtocol = statement.item.asProtocol(DeclGroupSyntax.self),
                let controller = ControllerDeclaration(declaration)
            {
                return controller
            }
        }
        fatalError("no controller in the test source")
    }

    /// `@RequestBinding(DocumentAuthorizer.self)` on the wrapper `AuthorizedDocument` — two types, as the
    /// seam requires. The wrapper is the shape a parameter attribute has to be; the worker is the
    /// `@Scoped(seed:)` binding whose `bind` reads a store and consults a policy engine, so it needs
    /// `@Inject` members a static method could not reach.
    /// No `.path` obligation, deliberately. That obligation means "the binding's *name* is a `{name}`
    /// placeholder", and a graph-aware binding's name is its **action** — `@AuthorizedDocument("read")`.
    /// It still reads a path parameter, by the key its own `bind` names (`pathParameters["id"]`), which is
    /// a thing the binding knows and the route template does not have to agree with.
    private func bindings(
        seed: String = "HTTPRequest",
        obligations: BindingObligations = []
    ) -> [String: DeclaredRequestBinding] {
        var declared = WireMVCBuiltIns.bindings
        declared["AuthorizedDocument"] = DeclaredRequestBinding(
            obligations: obligations,
            transform: "DocumentAuthorizer",
            transformSeed: seed
        )
        return declared
    }

    private let documentsController = """
        @Scoped(seed: HTTPRequest.self)
        @Controller("/documents")
        struct Documents {
            @Get("/{id}")
            @JSONResponse
            func read(@AuthorizedDocument("read") document: Document) -> Document {
                fatalError()
            }
        }
        """

    private func render(
        _ source: String,
        bindings declared: [String: DeclaredRequestBinding]
    ) -> (source: String, diagnostics: [RouteCodegenDiagnostic]) {
        renderRouteContributorExtension(
            controller: controller(source),
            pathPrefix: "/documents",
            factoryKeys: [],
            discoveredBindings: declared,
            discoveredModes: WireMVCBuiltIns.modes
        )
    }

    // MARK: - Emission

    @Test func theBindingIsReadOffTheScopeEntryRatherThanConstructed() {
        // The whole difference. An ordinary binding is a property wrapper generic over the parameter type
        // and `bind` is static — `Path<String>.bind(…)` — because there is nothing to hold. A graph-aware
        // one is an instance the scope constructed, so it is *read* from the entry the terminal already
        // bound, and it is not generic over the parameter type: it declares its own `Value`, which is what
        // lets `bind` return something the request does not contain.
        let rendered = render(documentsController, bindings: bindings())
        #expect(rendered.diagnostics.filter { $0.message.severity == .error }.isEmpty)
        #expect(
            rendered.source.contains(
                "let document = try await wireMVCScopeEntry.documentAuthorizer.bind("
                    + "name: \"read\", request: request, pathParameters: pathParameters, body: nil, "
            )
        )
        #expect(!rendered.source.contains("AuthorizedDocument<Document>"))
        #expect(!rendered.source.contains("wireMVCScopeEntry.authorizedDocument"), "the worker, not the wrapper")
    }

    @Test func theBindComesAfterTheScopeEntryThatProducesIt() {
        // Order is the property, not an accident of emission: the instance does not exist until the entry
        // has run. It holds by construction — binds are emitted into the terminal, which the scope-entry
        // prologue opens — and asserting it is what would catch a reordering.
        let rendered = render(documentsController, bindings: bindings())
        let entry = rendered.source.range(of: "let wireMVCScopeEntry = try await self._wireEnterScope(request)")
        let bind = rendered.source.range(of: "wireMVCScopeEntry.documentAuthorizer.bind(")
        #expect(entry != nil && bind != nil)
        #expect(entry!.upperBound < bind!.lowerBound)
    }

    @Test func anOrdinaryBindingIsUnchanged() {
        // The regression guard. Every binding that is not a graph binding keeps the static, generic form,
        // including on a scoped controller — where both kinds now appear in one terminal.
        let source = """
            @Scoped(seed: HTTPRequest.self)
            @Controller("/documents")
            struct Documents {
                @Get("/{id}")
                @JSONResponse
                func read(@Path id: String, @AuthorizedDocument("read") document: Document) -> Document {
                    fatalError()
                }
            }
            """
        let rendered = render(source, bindings: bindings())
        #expect(rendered.source.contains("let id = try await Path<String>.bind("))
        #expect(rendered.source.contains("let document = try await wireMVCScopeEntry.documentAuthorizer.bind("))
    }

    @Test func anOptionalParameterUsesTheInstancesOptionalForm() {
        let source = """
            @Scoped(seed: HTTPRequest.self)
            @Controller("/documents")
            struct Documents {
                @Get("/{id}")
                @JSONResponse
                func read(@AuthorizedDocument("read") document: Document?) -> Document {
                    fatalError()
                }
            }
            """
        let rendered = render(source, bindings: bindings())
        #expect(rendered.source.contains("wireMVCScopeEntry.documentAuthorizer.bindOptional("))
    }

    // MARK: - The two ways it cannot work

    @Test func aScopedBindingOnAnUnscopedControllerIsRefused() {
        // A `@Singleton @Controller` holds its subject and enters no scope, so there is no entry to read
        // the instance off. Diagnosed at the *parameter*, which is where the mistake is written — the
        // binding is fine, and so is the controller; it is the pairing that is not.
        let source = """
            @Controller("/documents")
            struct Documents {
                @Get("/{id}")
                @JSONResponse
                func read(@AuthorizedDocument("read") document: Document) -> Document {
                    fatalError()
                }
            }
            """
        let rendered = render(source, bindings: bindings())
        let message = rendered.diagnostics.compactMap { diagnostic -> String? in
            if case .scopedBindingOnUnscopedController = diagnostic.message { return diagnostic.message.message }
            return nil
        }.first
        #expect(message?.contains("resolves through 'DocumentAuthorizer'") == true)
        #expect(message?.contains("this controller is not scoped") == true)
        #expect(message?.contains("Mark the controller @Scoped(seed: HTTPRequest.self)") == true)
    }

    @Test func aBindingFromASiblingSeedIsRefused() {
        // Sibling seeded scopes are isolated by design, so the controller's entry constructs only its own.
        // Without this the witness would name a field the entry does not have.
        let rendered = render(documentsController, bindings: bindings(seed: "OtherSeed"))
        let message = rendered.diagnostics.compactMap { diagnostic -> String? in
            if case .scopedBindingSeedMismatch = diagnostic.message { return diagnostic.message.message }
            return nil
        }.first
        #expect(message?.contains("resolves through 'DocumentAuthorizer'") == true)
        #expect(message?.contains("sibling seeded scopes are isolated by design") == true)
    }

    // MARK: - The typed client

    @Test func theRouteIsOmittedFromTheClientAndSaidSo() {
        // A caller holds no `Document` — the handler's parameter type is what the *scope* produced, and
        // what a client would send is an id only the binding's declaration could name. So the route is
        // omitted, and reported: a route that vanishes from a client while reporting nothing is #87.
        let rendered = renderControllerClient(
            controller: controller(documentsController),
            pathPrefix: "/documents",
            discoveredBindings: bindings(),
            discoveredModes: WireMVCBuiltIns.modes
        )
        let (client, diagnostics) = (rendered.source, rendered.diagnostics)
        #expect(client == nil, "the only route is unsendable, so there is no client at all")
        let omission = diagnostics.compactMap { diagnostic -> WireMVCDiagnostic? in
            if case .routeOmittedFromClient = diagnostic.message { return diagnostic.message }
            return nil
        }.first
        #expect(omission != nil)
        // A warning, not an error: the route serves correctly and stays drivable untyped. Failing the
        // build over a client nobody may want would be the wrong trade.
        #expect(omission?.severity == .warning)
        #expect(omission?.message.contains("stays drivable through the untyped client") == true)
    }

    @Test func theControllersOtherRoutesStillGetAClient() {
        // The omission is per route, not per controller — a sibling route with ordinary bindings is still
        // worth a typed method, and dropping the whole client would be a far larger silence.
        let source = """
            @Scoped(seed: HTTPRequest.self)
            @Controller("/documents")
            struct Documents {
                @Get("/{id}")
                @JSONResponse
                func read(@AuthorizedDocument("read") document: Document) -> Document {
                    fatalError()
                }
                @Get
                @JSONResponse
                func list() -> [Document] {
                    fatalError()
                }
            }
            """
        let rendered = renderControllerClient(
            controller: controller(source),
            pathPrefix: "/documents",
            discoveredBindings: bindings(),
            discoveredModes: WireMVCBuiltIns.modes
        )
        let (client, diagnostics) = (rendered.source, rendered.diagnostics)
        #expect(client?.contains("func list(") == true)
        #expect(client?.contains("func read(") == false)
        #expect(
            diagnostics.contains { if case .routeOmittedFromClient = $0.message { return true } else { return false } }
        )
    }

    /// **And having omitted the route, the generator must not then nag about sending it.** The
    /// send-conformance warning tells an author to add `RequestSendable` "or the client's call will fail to
    /// compile" — but there is no call, for exactly the reason the test above asserts.
    ///
    /// Worse advice here than for a lent stream, which is the other exempt kind: `Document` is a plausible
    /// thing to make `RequestSendable`, so an author can follow the advice, get no error, and still have no
    /// generated call. The warning has to know the difference, and what it knows it by is
    /// ``DeclaredRequestBinding/isScopeResolved``.
    ///
    /// Driven through `generateRouteContributors` rather than the renderer above, because the warning is
    /// raised by the scan that feeds it and not by emission.
    @Test func theOmittedRouteIsNotAlsoNaggedAboutRequestSendable() {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                (
                    "AuthorizedDocument.swift",
                    """
                    @RequestBinding(DocumentAuthorizer.self)
                    @propertyWrapper
                    public struct AuthorizedDocument {
                        public var wrappedValue: Document
                        public init(wrappedValue: Document) { self.wrappedValue = wrappedValue }
                        public init(wrappedValue: Document, _ name: String) { self.wrappedValue = wrappedValue }
                    }

                    @Scoped(seed: HTTPRequest.self)
                    public struct DocumentAuthorizer: ScopedRequestBound {
                        public typealias Value = Document
                    }
                    """
                ),
                ("Controller.swift", documentsController),
            ],
            testEntry: true
        )
        let messages = result.diagnostics.map(\.message.message)
        #expect(!messages.contains { $0.contains("does not conform to RequestSendable") }, "\(messages)")
    }

    /// The negative control the test above needs: the same scan, on a binding that is *not* graph-aware,
    /// still warns. Without this, deleting the whole check would leave both tests green.
    @Test func anOrdinaryBindingIsStillNaggedAboutRequestSendable() {
        let result = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                (
                    "Ticket.swift",
                    """
                    @RequestBinding
                    @propertyWrapper
                    public struct Ticket<Value>: RequestBound {
                        public var wrappedValue: Value
                        public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
                    }
                    """
                ),
                (
                    "Controller.swift",
                    """
                    @Singleton
                    @Controller("/documents")
                    struct Documents {
                        @Get("/{id}")
                        @JSONResponse
                        func read(@Ticket ticket: String) -> Document {
                            fatalError()
                        }
                    }
                    """
                ),
            ],
            testEntry: true
        )
        let messages = result.diagnostics.map(\.message.message)
        #expect(messages.contains { $0.contains("does not conform to RequestSendable") }, "\(messages)")
    }
}
