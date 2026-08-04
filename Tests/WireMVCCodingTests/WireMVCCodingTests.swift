import Foundation
import Testing

@testable import WireMVC

/// The coding settings both kinds of route share.
///
/// The date test is the point of the type existing: this framework built `JSONEncoder()` inline and so
/// inherited Foundation's `.deferredToDate`, while swift-openapi-generator's runtime defaults to ISO8601 —
/// so an app serving a `@Get` route and an OpenAPI operation answered with two different date formats.
/// Neither fixture had a date in it, which is why nobody saw it.
@Suite("WireMVCCoding")
struct WireMVCCodingTests {
    struct Sample: Codable, Equatable { let at: Date }

    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the default writes a date as ISO8601, not a number")
    func defaultDateFormat() throws {
        let encoded = String(decoding: try WireMVCCoding.default.encoder().encode(Sample(at: Self.date)), as: UTF8.self)
        #expect(encoded.contains("2023-11-14"), "expected an ISO8601 date, got \(encoded)")
        // What Foundation would have written, and what this exists to stop.
        #expect(!encoded.contains("721692800"))
    }

    @Test("a date survives a round trip")
    func roundTrip() throws {
        let coding = WireMVCCoding.default
        let decoded = try coding.decoder().decode(Sample.self, from: coding.encoder().encode(Sample(at: Self.date)))
        #expect(Int(decoded.at.timeIntervalSince1970) == Int(Self.date.timeIntervalSince1970))
    }

    @Test("a custom transcoder is used for both directions")
    func customTranscoder() throws {
        struct Epoch: DateTranscoding {
            func encode(_ date: Date) throws -> String { String(Int(date.timeIntervalSince1970)) }
            func decode(_ string: String) throws -> Date {
                Date(timeIntervalSince1970: Double(string) ?? 0)
            }
        }
        let coding = WireMVCCoding(dates: Epoch())
        let encoded = String(decoding: try coding.encoder().encode(Sample(at: Self.date)), as: UTF8.self)
        #expect(encoded == #"{"at":"1700000000"}"#)
        #expect(try coding.decoder().decode(Sample.self, from: Data(encoded.utf8)) == Sample(at: Self.date))
    }

    @Test("JSON settings reach the encoder")
    func jsonSettings() throws {
        struct Pair: Encodable {
            let b = "/x"
            let a = 1
        }
        let plain = String(decoding: try WireMVCCoding.default.encoder().encode(Pair()), as: UTF8.self)
        #expect(plain.contains(#"\/x"#), "Foundation escapes slashes by default")
        let configured = WireMVCCoding(json: .init(sortsKeys: true, escapesSlashes: false))
        let tuned = String(decoding: try configured.encoder().encode(Pair()), as: UTF8.self)
        #expect(tuned == #"{"a":1,"b":"/x"}"#)
    }
}
