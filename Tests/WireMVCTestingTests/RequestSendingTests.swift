// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import HTTPTypes
import Testing
import WireMVC

/// The reverse bind: a binding places its own value into an outgoing request, rather than the client
/// knowing where each wrapper's value goes. Pins the built-ins behaving as ordinary instances of that seam.
@Suite("Reverse bind")
struct RequestSendingTests {

    private func send<B: RequestSendable>(
        _ binding: B.Type,
        name: String,
        _ value: B.Value,
        coding: WireMVCCoding = .default
    ) throws -> WireMVCOutgoingRequest {
        var request = WireMVCOutgoingRequest()
        try B.send(name: name, value: value, into: &request, coding: coding)
        return request
    }

    @Test("each built-in writes itself to its own place")
    func builtInsPlaceThemselves() throws {
        #expect(try send(Path<String>.self, name: "id", "42").pathParameters == ["id": "42"])
        let query = try send(Query<String>.self, name: "q", "swift").query
        #expect(query.map(\.name) == ["q"] && query.map(\.value) == ["swift"])
        #expect(try send(Header<String>.self, name: "x-tenant", "acme").headers == ["x-tenant": "acme"])
    }

    /// Optionality is the *generator's* concern on both sides: it calls `bind`/`bindOptional` on the
    /// non-optional underlying type, so a binding is only ever asked to send a value it has. A binding
    /// conforms for `T`, never `T?`.
    @Test("a binding conforms for the underlying type, not the optional")
    func conformanceIsOnTheUnderlyingType() throws {
        #expect(try send(Query<Int>.self, name: "page", 3).query.first?.value == "3")
    }

    @Test("a body binding returns bytes and its own content type")
    func bodyBindingSuppliesBoth() throws {
        struct Payload: Codable, Sendable, Equatable { let name: String }
        var request = WireMVCOutgoingRequest()
        let body = try JSONBody<Payload>.sendBody(
            name: "input",
            value: Payload(name: "ada"),
            into: &request,
            coding: .default
        )
        #expect(body.contentType == "application/json")
        #expect(try JSONDecoder().decode(Payload.self, from: Data(body.bytes)) == Payload(name: "ada"))
        // It wrote nothing else — but it *could* have, which is why the body is returned rather than
        // written into a slot: a second binding cannot overwrite what does not exist.
        #expect(request.headers.isEmpty && request.query.isEmpty && request.pathParameters.isEmpty)
    }
}
