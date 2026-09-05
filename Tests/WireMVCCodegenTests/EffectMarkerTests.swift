// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import SwiftParser
import SwiftSyntax
import Testing

@testable import WireMVCCodegen

/// A generated route closure is `async throws` whatever the handler is, so `try await` on the handler call
/// always compiled — it was just untrue for the handlers that declare neither, and the compiler said so
/// once per marker per route. These pin that the call carries exactly what the callee declares.
@Suite("Effect markers")
struct EffectMarkerTests {
    /// One controller, four handlers, one per effect combination — rendered together so the choice is
    /// visibly per-call rather than per-file.
    private var rendered: String {
        generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                (
                    "App.swift",
                    """
                    @Controller("/e")
                    @Singleton
                    struct Effects {
                        @Get("/plain") @JSONResponse func plain() -> Int { 0 }
                        @Get("/throwing") @JSONResponse func throwing() throws -> Int { 0 }
                        @Get("/asynchronous") @JSONResponse func asynchronous() async -> Int { 0 }
                        @Get("/both") @JSONResponse func both() async throws -> Int { 0 }
                    }
                    """
                )
            ]
        ).source
    }

    @Test("A sync, non-throwing handler is called bare")
    func plain() {
        #expect(rendered.contains("self._wireSubject.plain()"))
        #expect(!rendered.contains("try await self._wireSubject.plain()"))
        #expect(!rendered.contains("await self._wireSubject.plain()"))
        #expect(!rendered.contains("try self._wireSubject.plain()"))
    }

    @Test("A throwing handler is called with `try` alone")
    func throwing() {
        #expect(rendered.contains("try self._wireSubject.throwing()"))
        #expect(!rendered.contains("try await self._wireSubject.throwing()"))
    }

    @Test("An async handler is called with `await` alone")
    func asynchronous() {
        #expect(rendered.contains("await self._wireSubject.asynchronous()"))
        #expect(!rendered.contains("try await self._wireSubject.asynchronous()"))
    }

    @Test("An `async throws` handler keeps both")
    func both() {
        #expect(rendered.contains("try await self._wireSubject.both()"))
    }

    /// The raw path builds its call the same way, from the same helper.
    @Test("A `@RawRoute` handler carries only what it declares")
    func rawRoute() {
        let source = generateRouteContributors(
            files: WireMVCBuiltIns.declarationFiles + [
                (
                    "App.swift",
                    """
                    @Controller("/raw")
                    @Singleton
                    struct Raw {
                        @Get("/sync")
                        @RawRoute
                        func syncStream<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
                            responseSender: consuming Sender
                        ) { fatalError() }

                        @Get("/async")
                        @RawRoute
                        func asyncStream<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
                            responseSender: consuming Sender
                        ) async throws { fatalError() }
                    }
                    """
                )
            ]
        ).source
        #expect(source.contains("self._wireSubject.syncStream(responseSender:"))
        #expect(!source.contains("try await self._wireSubject.syncStream(responseSender:"))
        #expect(source.contains("try await self._wireSubject.asyncStream(responseSender:"))
    }

    @Test("The prefix itself is `try ` then `await `, as Swift spells it")
    func markerOrder() {
        #expect(effectMarkers(isAsync: false, isThrowing: false) == "")
        #expect(effectMarkers(isAsync: false, isThrowing: true) == "try ")
        #expect(effectMarkers(isAsync: true, isThrowing: false) == "await ")
        #expect(effectMarkers(isAsync: true, isThrowing: true) == "try await ")
    }

    @Test("The markers are read off the declaration's own effect specifiers")
    func readsTheDeclaration() {
        func markers(_ source: String) -> String {
            let function = Parser.parse(source: source).statements
                .compactMap { $0.item.as(FunctionDeclSyntax.self) }.first!
            return effectMarkers(of: function)
        }
        #expect(markers("func f() {}") == "")
        #expect(markers("func f() throws {}") == "try ")
        #expect(markers("func f() async {}") == "await ")
        #expect(markers("func f() async throws {}") == "try await ")
        #expect(markers("func f() throws(MyError) {}") == "try ")
    }
}
