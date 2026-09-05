// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import HTTPTypes
package import WireMVC

// A response mode declared **entirely outside WireMVC** — the response-side counterpart of `TextBody`, and
// the thing the seam exists for. Nothing in the framework names CSV, and nothing here is registered with it:
// the generator learns what `@CSVResponse` is by reading the `@ResponseMode` attribute on its declaration.
//
// Deliberately a codec WireMVC could not have anticipated. `Content-Type: text/csv`, a header row, and a
// decode that is not JSON — so a client that fell back to `TestResponse.json` would fail loudly rather than
// coincidentally work, which is what makes the fixture a proof rather than a demonstration.

/// A value that can be written as a CSV document.
package protocol CSVRepresentable {
    static var csvHeader: String { get }
    var csvRows: [String] { get }
}

/// A value that can be read back from one.
package protocol CSVReadable {
    init(csvRows: [String]) throws
}

package enum CSVError: Error {
    case empty
    case badField(String)
}

/// The codec: generic over the value, conforming **conditionally** in each direction. The same shape
/// `FormBody<Value>` has on the request side, and the reason one type can serve both halves without
/// requiring a value that only travels one way to implement the other.
package enum CSVCodec<Value> {}

extension CSVCodec: WireMVCResponseEncoding where Value: CSVRepresentable {
    package static func encodeResponseBody(
        _ value: Value,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        let document = ([Value.csvHeader] + value.csvRows).joined(separator: "\n") + "\n"
        return ([UInt8](document.utf8), "text/csv; charset=utf-8")
    }
}

extension CSVCodec: WireMVCResponseDecoding where Value: CSVReadable {
    package static func decodeResponseBody(_ bytes: [UInt8], coding: WireMVCCoding) throws -> Value {
        let lines = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else { throw CSVError.empty }
        // Drop the header row: it names the columns, it is not data.
        return try Value(csvRows: Array(lines.dropFirst()))
    }
}

// The mode itself. Two overloads, bare and `(status:)`, matching how WireMVC's own modes are declared —
// `@CSVResponse(status: .created)` reads its status through the same generic path `@JSONResponse` does,
// because the generator reads `status:` off whichever attribute the route wrote.
//
// `#externalMacro` names WireMVC's plugin, reachable because it is exported as the `WireMVCMacrosPlugin`
// product. That export is what makes a response mode declarable outside this package at all: a macro
// declaration must name the plugin implementing it, and `RouteMarkerMacro` expands to nothing — a marker's
// job is to be *readable*.

@ResponseMode(.buffered, codec: "CSVCodec")
@attached(peer)
package macro CSVResponse() = #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")

@ResponseMode(.buffered, codec: "CSVCodec")
@attached(peer)
package macro CSVResponse(status: HTTPResponse.Status) =
    #externalMacro(module: "WireMVCMacros", type: "RouteMarkerMacro")
