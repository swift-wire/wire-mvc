public import Foundation
public import HTTPTypes

// How a route encodes and decodes values — the settings both a `@JSONBody` and a `@JSONResponse` need,
// and which an OpenAPI operation needs too.
//
// They live here rather than in an adapter because both kinds of route encode the same things and an app
// serving both should not answer with two date formats. Today it does: this framework builds
// `JSONEncoder()` inline and so gets Foundation's `.deferredToDate` — a number — while
// swift-openapi-generator's runtime defaults to ISO8601. Nobody has noticed only because neither
// fixture has a date in it.

/// Converting a date to and from its wire form.
///
/// A transcoder rather than a `JSONEncoder.DateEncodingStrategy`, because a date is not only a JSON
/// concern: it appears in a `@Header` and a `@Query` too, where there is no encoder to configure. The
/// shape deliberately matches OpenAPIRuntime's `DateTranscoder`, so an adapter bridging the two writes a
/// conformance and nothing else.
public protocol DateTranscoding: Sendable {
    /// The wire form of a date.
    func encode(_ date: Date) throws -> String
    /// A date from its wire form.
    func decode(_ string: String) throws -> Date
}

/// ISO8601 with fractional seconds — what an HTTP API almost always means, and what the OpenAPI runtime
/// defaults to. Foundation's own default is a `Double` since the reference date, which nothing on the
/// wire expects.
public struct ISO8601DateTranscoder: DateTranscoding {
    public init() {}

    public func encode(_ date: Date) throws -> String { date.formatted(.iso8601) }

    public func decode(_ string: String) throws -> Date {
        try Date(string, strategy: .iso8601)
    }
}

/// JSON-specific settings. Separate from the date transcoder above, which spans formats and locations.
public struct JSONCoding: Sendable {
    /// Keys in a stable order. Off by default, as Foundation has it; worth turning on for responses a
    /// test compares literally.
    public var sortsKeys: Bool
    /// Whether `/` is written as `\/`. Foundation escapes it by default, which surprises people reading
    /// a URL out of a response body.
    public var escapesSlashes: Bool

    public init(sortsKeys: Bool = false, escapesSlashes: Bool = true) {
        self.sortsKeys = sortsKeys
        self.escapesSlashes = escapesSlashes
    }
}

/// The coding settings a route uses.
public struct WireMVCCoding: Sendable {
    public var dates: any DateTranscoding
    public var json: JSONCoding

    public init(dates: any DateTranscoding = ISO8601DateTranscoder(), json: JSONCoding = .init()) {
        self.dates = dates
        self.json = json
    }

    /// What a route uses when nothing supplies one.
    ///
    /// ISO8601 dates — *not* Foundation's default. That is a deliberate change of behaviour rather than
    /// an oversight preserved: a number-since-2001 is not something an API client can read, and matching
    /// the OpenAPI runtime is what lets one app serve both kinds of route consistently.
    public static let `default` = WireMVCCoding()
}

extension WireMVCCoding {
    /// A `JSONEncoder` configured from these settings.
    public func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = []
        if json.sortsKeys { formatting.insert(.sortedKeys) }
        if !json.escapesSlashes { formatting.insert(.withoutEscapingSlashes) }
        encoder.outputFormatting = formatting
        let dates = dates
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dates.encode(date))
        }
        return encoder
    }

    /// A `JSONDecoder` configured from these settings.
    public func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let dates = dates
        decoder.dateDecodingStrategy = .custom { decoder in
            try dates.decode(decoder.singleValueContainer().decode(String.self))
        }
        return decoder
    }
}

/// A binding that supplies coding settings.
///
/// The annotation names a *binding*, not a literal, for the same reason `@Middleware` does: settings that
/// come from configuration or differ per environment are graph concerns, and an attribute argument cannot
/// hold a date transcoder anyway.
public protocol CodingSource: Sendable {
    var wireMVCCoding: WireMVCCoding { get }
}
