import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Testing

@testable import WireMVC

// `WireMVCOutcome` is what every typed route sends, so these cover both halves: the value it builds
// (status/fields/body) and what actually reaches the wire through `send(on:)`. The sender below is
// hand-written over the proposal's associated types — the same thing `InProcessTransportTests` does, and
// cheaper than depending on `WireMVCTesting` for one recording sender.

/// Records the head and body a `WireMVCOutcome` sends. A class so the test can read what the `consuming`
/// sender wrote after the sender itself is gone.
final class RecordedResponse: @unchecked Sendable {
    var head: HTTPResponse?
    var body: [UInt8] = []
}

/// Both the writer and the sender append, because which one receives the bytes is not ours to choose:
/// `WireMVCOutcome.send` calls the two-argument `sendAndFinish(_:buffer:)`, and the proposal's *extension*
/// declares that spelling (with a defaulted `trailer:`), so it wins over a conformer's three-argument
/// witness and expands to `send(_:)` + `finish(buffer:)`. Recording in both places keeps the test measuring
/// `WireMVCOutcome` rather than overload resolution.
struct RecordingWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    let record: RecordedResponse

    mutating func write<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer
    ) async throws(Never) where Buffer.Element: ~Copyable {
        record.body += drained(&buffer)
    }

    consuming func finish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        buffer: inout Buffer,
        finalElement: consuming FinalElement
    ) async throws(Never) where Buffer.Element: ~Copyable {
        record.body += drained(&buffer)
    }
}

private func drained<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
    _ buffer: inout Buffer
) -> [UInt8] where Buffer.Element: ~Copyable {
    var bytes: [UInt8] = []
    var consumer = buffer.consumeAll()
    while let byte = consumer.next() { bytes.append(byte) }
    return bytes
}

struct RecordingSender: HTTPResponseSender {
    typealias Writer = RecordingWriter

    let record: RecordedResponse

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> RecordingWriter {
        record.head = response
        return RecordingWriter(record: record)
    }

    consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        record.head = response
        record.body += drained(&buffer)
    }
}

private func sent(_ outcome: WireMVCOutcome) async throws -> RecordedResponse {
    let record = RecordedResponse()
    try await outcome.send(on: RecordingSender(record: record))
    return record
}

private struct Payload: Codable, Equatable {
    let name: String
}

@Suite("WireMVCOutcome")
struct ResponsesTests {
    /// The bug this whole change exists for: a `@JSONResponse` route used to send `HTTPResponse(status:)`
    /// with no fields at all, and nothing downstream (the router, the `ServerTransport` bridge, NIO) adds
    /// one — so every JSON response went out untyped.
    @Test
    func jsonSeedsContentType() async throws {
        let outcome = try WireMVCOutcome.json(Payload(name: "wire"))
        #expect(outcome.headerFields[.contentType] == "application/json")

        let record = try await sent(outcome)
        #expect(record.head?.headerFields[.contentType] == "application/json")
        #expect(record.head?.status == .ok)
    }

    /// An explicit `Content-Type` wins over the seeded default — the caller spelling a `+json` media type
    /// or a charset must not end up with two content types or the wrong one.
    @Test
    func explicitContentTypeOverridesTheDefault() throws {
        let outcome = try WireMVCOutcome.json(
            Payload(name: "wire"),
            headerFields: [.contentType: "application/problem+json"]
        )
        #expect(outcome.headerFields[.contentType] == "application/problem+json")
        #expect(outcome.headerFields[values: .contentType].count == 1)
    }

    /// `.json` carries caller fields *alongside* the seeded content type, so an `@ErrorResponse` mapping
    /// can answer with both a body and the header its status requires.
    @Test
    func jsonCarriesCallerFieldsBesideTheDefault() async throws {
        let outcome = try WireMVCOutcome.json(
            Payload(name: "wire"),
            status: .unauthorized,
            headerFields: [.wwwAuthenticate: #"Bearer realm="api""#]
        )
        let record = try await sent(outcome)
        #expect(record.head?.status == .unauthorized)
        #expect(record.head?.headerFields[.wwwAuthenticate] == #"Bearer realm="api""#)
        #expect(record.head?.headerFields[.contentType] == "application/json")
    }

    /// A bodiless response can still carry fields — the `401`-with-`WWW-Authenticate` case an
    /// `@ErrorResponse(E.self, .unauthorized)` mapping needs, and the reason `.status` gained the
    /// parameter at all.
    @Test
    func statusCarriesHeaderFields() async throws {
        let outcome = WireMVCOutcome.status(
            .unauthorized,
            headerFields: [.wwwAuthenticate: #"Bearer realm="api""#]
        )
        let record = try await sent(outcome)
        #expect(record.head?.status == .unauthorized)
        #expect(record.head?.headerFields[.wwwAuthenticate] == #"Bearer realm="api""#)
        #expect(record.body.isEmpty)
    }

    /// `.body` seeds nothing — raw bytes carry no inferable media type, so the caller owns it.
    @Test
    func rawBodySeedsNoContentType() async throws {
        let outcome = WireMVCOutcome.body(Array("plain".utf8), .internalServerError)
        #expect(outcome.headerFields.isEmpty)

        let record = try await sent(outcome)
        #expect(record.head?.status == .internalServerError)
        #expect(record.body == Array("plain".utf8))
    }

    /// The factories are the pre-struct spelling: `.status(_)` and `.body(_:_:)` still construct, so no
    /// existing construction site (including the emitted witness) had to change.
    @Test
    func legacyFactorySpellingsStillConstruct() {
        #expect(WireMVCOutcome.status(.noContent).body == nil)
        #expect(WireMVCOutcome.body([1, 2, 3], .ok).body == [1, 2, 3])
    }
}

@Suite("Response header resolution")
struct ResponseHeaderTests {
    /// Tier order is application order: the controller's entry first, the route's after, so a route `.set`
    /// replaces it. This is the whole tiering rule — there is no separate override pass.
    @Test
    func routeSetReplacesControllerSet() {
        let fields = WireMVCResponseHeaders.resolved(statics: [
            .set(.cacheControl, "public, max-age=3600"),  // controller
            .set(.cacheControl, "no-store"),  // route
        ])
        #expect(fields[values: .cacheControl] == ["no-store"])
    }

    /// `.append` adds a **separate field line** and never folds. The invariant the whole design rests on:
    /// folding is forbidden for Set-Cookie (RFC 6265 §3) and required against by HTTP/2 (RFC 9113 §8.2.3),
    /// so nothing here may reach for HTTPFields' single-value setter.
    @Test
    func appendKeepsSeparateFieldLines() {
        let fields = WireMVCResponseHeaders.resolved(statics: [
            .set(.setCookie, "sid=1"),
            .append(.setCookie, "consent=yes"),
        ])
        #expect(fields[values: .setCookie] == ["sid=1", "consent=yes"])
        #expect(fields.filter { $0.name == .setCookie }.count == 2, "two field lines, not one folded value")
    }

    /// `.setIfAbsent` defers when the field is already there, and lands when it isn't.
    @Test
    func setIfAbsentDefersToWhatIsAlreadySet() {
        let taken = WireMVCResponseHeaders.resolved(statics: [
            .set(.cacheControl, "no-store"),
            .setIfAbsent(.cacheControl, "public"),
        ])
        #expect(taken[values: .cacheControl] == ["no-store"])

        let free = WireMVCResponseHeaders.resolved(statics: [.setIfAbsent(.cacheControl, "public")])
        #expect(free[values: .cacheControl] == ["public"])
    }

    /// The handler's returned fields are applied after the constants and replace per *name*.
    @Test
    func returnedFieldsBeatStatics() {
        let fields = WireMVCResponseHeaders.resolved(
            statics: [.set(.cacheControl, "no-store"), .set(.vary, "Accept-Encoding")],
            returned: [.cacheControl: "public"]
        )
        #expect(fields[values: .cacheControl] == ["public"])
        #expect(fields[values: .vary] == ["Accept-Encoding"], "a field the handler didn't name survives")
    }

    /// Replacement from the returned list is per name, not per value — a handler returning two cookies
    /// replaces the inherited set with *both* of its own, rather than only the last surviving.
    @Test
    func returnedRepeatedFieldReplacesAsAWhole() {
        var returned = HTTPFields()
        returned[values: .setCookie] = ["a=1", "b=2"]
        let fields = WireMVCResponseHeaders.resolved(
            statics: [.set(.setCookie, "inherited=1")],
            returned: returned
        )
        #expect(fields[values: .setCookie] == ["a=1", "b=2"])
    }

    /// Nothing in the resolve path may use HTTPFields' single-value subscript, whose *getter* joins with
    /// ", " and does not special-case Set-Cookie — so a folded cookie would read back plausibly while being
    /// wrong on the wire. Asserted on the field count, which folding would collapse to 1.
    @Test
    func resolvingNeverFolds() {
        let fields = WireMVCResponseHeaders.resolved(statics: [
            .set(.vary, "Accept-Encoding"),
            .append(.vary, "Origin"),
        ])
        #expect(fields.filter { $0.name == .vary }.count == 2)
        #expect(fields[.vary] == "Accept-Encoding, Origin", "the joined getter is lossy — read with [values:]")
    }
}
