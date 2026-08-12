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
