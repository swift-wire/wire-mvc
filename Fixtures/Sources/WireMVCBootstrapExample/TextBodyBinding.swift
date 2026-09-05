// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import HTTPTypes
package import WireMVC

@RequestBinding(.body)
@propertyWrapper
package struct TextBody<Value> {
    package var wrappedValue: Value
    package init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    package init(wrappedValue: Value, _ name: String) { self.wrappedValue = wrappedValue }
}

extension TextBody: RequestBound where Value == String {
    package static func bind(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        body: [UInt8]?
    ) async throws -> String {
        guard let body else { throw WireMVCBindingError.malformedBody }
        return String(decoding: body, as: UTF8.self)
    }
}

/// The client half. `@RequestBinding(.body)` tells the generator this parameter *is* the request body; this
/// conformance is what lets the generated typed client actually send one. Declaring the obligation without
/// it produces `type 'TextBody<String>' has no member 'sendBody'` in generated code — which is why the
/// codegen diagnoses the mismatch rather than leaving it to the compiler.
extension TextBody: RequestBodySendable where Value == String {
    package static func sendBody(
        name: String,
        value: String,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        ([UInt8](value.utf8), "text/plain; charset=utf-8")
    }
}
