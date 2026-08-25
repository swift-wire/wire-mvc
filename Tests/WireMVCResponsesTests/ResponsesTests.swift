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

/// Records **which** of a sender's two write paths was taken, where ``RecordingSender`` deliberately
/// records both so its assertions do not depend on overload resolution. Here overload resolution is the
/// thing under test.
final class PathRecord: @unchecked Sendable {
    var reachedFusedWitness = false
    var wentThroughSend = false
    var body: [UInt8] = []
}

struct PathDistinguishingSender: HTTPResponseSender {
    typealias Writer = PathDistinguishingWriter

    let record: PathRecord

    mutating func sendInformational(_ response: HTTPResponse) async throws {}

    consuming func send(_ response: HTTPResponse) async throws -> PathDistinguishingWriter {
        record.wentThroughSend = true
        return PathDistinguishingWriter(record: record)
    }

    consuming func sendAndFinish<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        _ response: HTTPResponse,
        buffer: inout Buffer,
        trailer: HTTPFields?
    ) async throws where Buffer.Element: ~Copyable {
        record.reachedFusedWitness = true
        record.body += drained(&buffer)
    }
}

struct PathDistinguishingWriter: CallerAsyncWriter {
    typealias WriteElement = UInt8
    typealias WriteFailure = Never
    typealias FinalElement = HTTPFields?

    let record: PathRecord

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

    /// The same shape of bug as `jsonSeedsContentType`, found by measurement rather than by reading: the
    /// outcome holds the encoded body, so it knows the length, and used not to say so. Nothing downstream
    /// infers it — not the router, not the `ServerTransport` bridge, not `NIOHTTPServer`, whose only
    /// `Content-Length` is the one it writes for an aborted request — so every response went out
    /// `Transfer-Encoding: chunked`, on every runtime.
    @Test
    func bodyStatesItsLength() async throws {
        let record = try await sent(WireMVCOutcome.body(Array("plain".utf8), .ok))
        #expect(record.head?.headerFields[.contentLength] == "5")
    }

    /// Bytes, not characters — the one way a hand-written length goes wrong. `"héllo→"` is six characters
    /// and nine bytes.
    @Test
    func lengthCountsBytesNotCharacters() async throws {
        let record = try await sent(WireMVCOutcome.body(Array("héllo→".utf8), .ok))
        #expect(record.head?.headerFields[.contentLength] == "9")
    }

    @Test
    func jsonStatesItsLengthBesideItsType() async throws {
        let outcome = try WireMVCOutcome.json(Payload(name: "wire"))
        let record = try await sent(outcome)
        #expect(record.head?.headerFields[.contentType] == "application/json")
        #expect(record.head?.headerFields[.contentLength] == String(outcome.body?.count ?? -1))
    }

    /// A bodiless response has a known length too. `404` with nothing to say is still `0` bytes, and
    /// leaving it unstated frames it as chunked exactly as a body would be.
    @Test
    func bodilessResponseStatesZero() async throws {
        let record = try await sent(WireMVCOutcome.status(.notFound))
        #expect(record.head?.headerFields[.contentLength] == "0")
    }

    /// RFC 9110 §8.6: a server must not send `Content-Length` on `1xx` or `204`. `304` is excluded for a
    /// different reason — it carries the length the `200` *would* have had, which this outcome never
    /// computed, so `0` would be a lie rather than an omission.
    @Test(arguments: [HTTPResponse.Status.continue, .noContent, .notModified])
    func statusesThatForbidALengthGetNone(_ status: HTTPResponse.Status) async throws {
        let record = try await sent(WireMVCOutcome.status(status))
        #expect(record.head?.headerFields[.contentLength] == nil)
    }

    /// A caller who states a length owns it. Overwriting would break the one case where the stated length
    /// is deliberately not the buffer's — a `HEAD` response, whose length is the `GET` body's.
    @Test
    func explicitLengthIsNotOverwritten() async throws {
        let outcome = WireMVCOutcome(
            status: .ok,
            headerFields: [.contentLength: "99"],
            body: Array("plain".utf8)
        )
        let record = try await sent(outcome)
        #expect(record.head?.headerFields[.contentLength] == "99")
    }

    /// `send(on:)` is non-mutating and is called on a value the terminal may still hold. The length is
    /// added to the response it builds, not written back into the outcome.
    @Test
    func sendingDoesNotMutateTheOutcome() async throws {
        let outcome = WireMVCOutcome.body(Array("plain".utf8), .ok)
        _ = try await sent(outcome)
        #expect(outcome.headerFields[.contentLength] == nil)
    }

    /// A buffered outcome must reach the sender's **own** `sendAndFinish`, not the proposal's extension.
    ///
    /// The requirement takes three parameters and carries no default — Swift forbids defaults on protocol
    /// requirements — so a two-argument call cannot match it and binds to the same-signature extension
    /// method instead, which expands to `send` + `finish` and never dispatches through the witness. An
    /// outcome has no trailer, so the two spellings mean the same thing; only the dispatch differs.
    ///
    /// It differs enough to matter. `BridgeResponseSender` fuses head and body into a known-length
    /// response in its witness and hands back a *streaming* writer from `send`, so under the two-argument
    /// spelling every buffered response took the streaming rendezvous — 5 allocations per request through
    /// the Hummingbird bridge, whose `contentLength:` fast path only a known-length body can reach.
    @Test
    func bufferedOutcomeReachesTheSendersOwnWitness() async throws {
        let record = PathRecord()
        try await WireMVCOutcome.body(Array("plain".utf8), .ok)
            .send(on: PathDistinguishingSender(record: record))

        #expect(record.reachedFusedWitness, "the two-argument spelling would expand to send + finish")
        #expect(!record.wentThroughSend)
        #expect(record.body == Array("plain".utf8))
    }

    /// The bodiless path goes through the one-argument convenience, which forwards with three explicit
    /// arguments and so already reached the witness. Pinned so it stays that way.
    @Test
    func bodilessOutcomeReachesTheSendersOwnWitness() async throws {
        let record = PathRecord()
        try await WireMVCOutcome.status(.noContent).send(on: PathDistinguishingSender(record: record))

        #expect(record.reachedFusedWitness)
        #expect(!record.wentThroughSend)
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

    /// With no statics, the returned fields are the starting point rather than something replayed into an
    /// empty set — the two are equivalent only if the replay preserved everything, so this pins that it
    /// did: repeated fields, their order, and fields the middleware never mentions.
    @Test
    func returnedFieldsSurviveWithNoStatics() {
        var returned = HTTPFields()
        returned[.contentType] = "text/plain"
        returned.append(HTTPField(name: .setCookie, value: "a=1"))
        returned.append(HTTPField(name: .setCookie, value: "b=2"))

        let fields = WireMVCResponseHeaders.resolved(returned: returned)
        #expect(fields[.contentType] == "text/plain")
        #expect(fields[values: .setCookie] == ["a=1", "b=2"])
    }

    /// The same, with middleware applying over the top — the precedence that makes the shortcut safe is
    /// that nothing comes *before* returned when there are no statics.
    @Test
    func middlewareAppliesOverReturnedWithNoStatics() {
        let fields = WireMVCResponseHeaders.resolved(
            returned: [.contentType: "text/plain", .cacheControl: "no-store"],
            middleware: [.set(.cacheControl, "public"), .setIfAbsent(.contentType, "application/json")]
        )
        #expect(fields[.cacheControl] == "public", "middleware overrides what the handler returned")
        #expect(fields[.contentType] == "text/plain", "setIfAbsent defers to it")
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

    /// `.set` must clear **every** value a name already has, not just the first. Untested until `apply`
    /// moved from the array-valued subscript to the scalar one — the old spelling got this from assigning
    /// a whole array, the new one from `HTTPFields` replacing all fields for a name.
    @Test
    func setReplacesEveryExistingValue() {
        let fields = WireMVCResponseHeaders.resolved(statics: [
            .set(.vary, "Accept-Encoding"),
            .append(.vary, "Origin"),
            .set(.vary, "Accept"),
        ])
        #expect(fields[values: .vary] == ["Accept"])
        #expect(fields.filter { $0.name == .vary }.count == 1)
    }

    /// The one behaviour the scalar spelling changed, pinned so it is known rather than discovered.
    ///
    /// `HTTPFields`' scalar setter special-cases `Cookie`: it splits on `"; "` into separate fields, where
    /// assigning `[value]` through the array-valued subscript stored one field containing the separator.
    /// It only matters for a contribution that sets `Cookie` on a *response*, which is a request header
    /// and malformed there anyway — and `Set-Cookie`, the response one, is not special-cased at all.
    @Test
    func setOnCookieSplitsOnItsSeparator() {
        let fields = WireMVCResponseHeaders.resolved(statics: [.set(.cookie, "a=1; b=2")])
        #expect(fields[values: .cookie] == ["a=1", "b=2"])

        let setCookie = WireMVCResponseHeaders.resolved(statics: [
            .set(.setCookie, "a=1"),
            .append(.setCookie, "b=2"),
        ])
        #expect(setCookie[values: .setCookie] == ["a=1", "b=2"], "Set-Cookie is unaffected")
    }
}

/// A *raw* route: generic over its sender, exactly as generated raw-route code is. The genericity is the
/// point — inside it, `sendAndFinish` resolves against the protocol, not against whatever concrete sender
/// was passed in.
private func rawRoute<Sender: HTTPResponseSender & ~Copyable>(
    sending sender: consuming Sender,
    body: [UInt8]
) async throws where Sender.Writer: ~Copyable {
    var buffer = UniqueArray<UInt8>(copying: body)
    try await sender.sendAndFinish(HTTPResponse(status: .ok), buffer: &buffer)
}

/// A raw route spelled with **three** arguments, which reaches a conformer's own `sendAndFinish` where
/// the two-argument spelling binds to the proposal's extension instead.
private func rawRouteStatingTrailer<Sender: HTTPResponseSender & ~Copyable>(
    sending sender: consuming Sender,
    body: [UInt8]
) async throws where Sender.Writer: ~Copyable {
    var buffer = UniqueArray<UInt8>(copying: body)
    try await sender.sendAndFinish(HTTPResponse(status: .ok), buffer: &buffer, trailer: nil)
}

/// A raw route that *streams*: asks for a writer, then writes. Generic for the same reason.
private func rawStreamingRoute<Sender: HTTPResponseSender & ~Copyable>(
    sending sender: consuming Sender,
    chunks: [[UInt8]]
) async throws where Sender.Writer: ~Copyable {
    var writer = try await sender.send(HTTPResponse(status: .ok))
    for chunk in chunks.dropLast() {
        var buffer = UniqueArray<UInt8>(copying: chunk)
        try await writer.write(buffer: &buffer)
    }
    var last = UniqueArray<UInt8>(copying: chunks.last ?? [])
    try await writer.finish(buffer: &last, finalElement: nil)
}

private func applying(to record: RecordedResponse) -> ResponseHeaderApplyingSender<RecordingSender> {
    ResponseHeaderApplyingSender(wrapping: RecordingSender(record: record), registry: ResponseHeaderRegistry())
}

/// A raw route that writes **its own header fields** alongside its body — what a real one does, and the
/// case that distinguishes applying contributions onto the written head from rebuilding the head around
/// them.
private func rawRoute<Sender: HTTPResponseSender & ~Copyable>(
    sending sender: consuming Sender,
    fields: HTTPFields,
    body: [UInt8]
) async throws where Sender.Writer: ~Copyable {
    var buffer = UniqueArray<UInt8>(copying: body)
    try await sender.sendAndFinish(HTTPResponse(status: .ok, headerFields: fields), buffer: &buffer)
}

@Suite("ResponseHeaderRegistry")
struct ResponseHeaderRegistryTests {
    private func name(_ index: Int) -> HTTPField.Name { HTTPField.Name("x-h\(index)")! }

    /// Registrations past the inline capacity spill to the heap, and the spill must be invisible: same
    /// order, same drain, same result. Nothing else exercises more than a couple of registrations, so
    /// without this the overflow branch is dead code that happens to compile.
    @Test(arguments: [1, 4, 5, 9])
    func everyRegistrationSurvivesRegardlessOfCount(_ count: Int) async throws {
        var registry = ResponseHeaderRegistry()
        for index in 0..<count { registry.add(.set(name(index), "\(index)")) }

        var fields = HTTPFields()
        try await registry.drain(into: &fields)
        for index in 0..<count {
            #expect(fields[name(index)] == "\(index)", "field \(index) of \(count)")
        }
    }

    /// Drain applies registration calls **in reverse**, so the outermost middleware — which registers
    /// first, on the way in — applies last and wins. That ordering has to hold across the inline/overflow
    /// boundary, which is exactly where an off-by-one in the backwards walk would hide.
    @Test(arguments: [2, 4, 5, 7])
    func theFirstRegistrationWinsAcrossTheOverflowBoundary(_ count: Int) async throws {
        var registry = ResponseHeaderRegistry()
        let contested = HTTPField.Name("x-contested")!
        for index in 0..<count { registry.add(.set(contested, "\(index)")) }

        var fields = HTTPFields()
        try await registry.drain(into: &fields)
        #expect(fields[contested] == "0", "the earliest registration applies last and wins")
        #expect(fields[values: contested].count == 1)
    }

    /// `drain(into:)` and `drain()` are two spellings of one traversal and must not disagree — including
    /// past the inline capacity, and including a deferred contribution among the immediate ones.
    @Test
    func bothDrainSpellingsAgree() async throws {
        func populate(_ registry: inout ResponseHeaderRegistry) {
            for index in 0..<6 { registry.add(.set(name(index), "\(index)")) }
            registry.onSend { [.set(HTTPField.Name("x-deferred")!, "late")] }
        }

        var viaInto = ResponseHeaderRegistry()
        populate(&viaInto)
        var fields = HTTPFields()
        try await viaInto.drain(into: &fields)

        var viaArray = ResponseHeaderRegistry()
        populate(&viaArray)
        var expected = HTTPFields()
        for contribution in try await viaArray.drain() {
            WireMVCResponseHeaders.apply(contribution, to: &expected)
        }

        #expect(fields == expected)
        #expect(fields[HTTPField.Name("x-deferred")!] == "late")
    }
}

@Suite("Raw route framing")
struct RawRouteFramingTests {
    /// A raw route that reaches the wrapper's own `sendAndFinish` gets its length stated, because that is
    /// the one place holding both the head and the whole body.
    @Test
    func threeArgumentRawRouteStatesALength() async throws {
        let record = RecordedResponse()
        try await rawRouteStatingTrailer(sending: applying(to: record), body: Array("plain".utf8))
        #expect(record.head?.headerFields[.contentLength] == "5")
        #expect(record.body == Array("plain".utf8))
    }

    /// The two-argument spelling does **not**, and this pins that limitation rather than hiding it.
    ///
    /// A two-argument call cannot match the three-parameter requirement — Swift forbids defaults on
    /// protocol requirements, so the proposal's same-signature extension carries them and wins the
    /// overload — and that extension expands to `send` + `finish`, arriving at the wrapper before the body
    /// is known. The head is written without a length and the response frames as chunked.
    ///
    /// This was previously worked around by holding the head inside a writer until `finish`. That was
    /// removed in favour of fixing the shadowing upstream, where it belongs.
    ///
    /// > Note: **this test is expected to fail once that lands.** When it does, a two-argument call will
    /// > forward to the requirement and reach the witness, and the assertion below should be inverted to
    /// > match `threeArgumentRawRouteStatesALength`.
    @Test
    func twoArgumentRawRouteDoesNotYetStateALength() async throws {
        let record = RecordedResponse()
        try await rawRoute(sending: applying(to: record), body: Array("plain".utf8))
        #expect(record.head?.headerFields[.contentLength] == nil)
        #expect(record.body == Array("plain".utf8), "the response is still sent, just chunked")
    }

    /// A streamed body has no length to state, and must not acquire a wrong one.
    @Test
    func streamedRawRouteStatesNoLength() async throws {
        let record = RecordedResponse()
        try await rawStreamingRoute(
            sending: applying(to: record),
            chunks: [Array("one".utf8), Array("two".utf8)]
        )
        #expect(record.head?.headerFields[.contentLength] == nil)
        #expect(record.body == Array("onetwo".utf8))
    }

    /// Deferring the head must not lose it: a streamed route still writes a head, and still writes it
    /// before the body it belongs to.
    @Test
    func streamedRawRouteStillSendsItsHead() async throws {
        let record = RecordedResponse()
        try await rawStreamingRoute(sending: applying(to: record), chunks: [Array("one".utf8)])
        #expect(record.head?.status == .ok)
        #expect(record.body == Array("one".utf8))
    }

    /// The handler's own fields survive a contribution, unreordered and unduplicated.
    ///
    /// `applying(to:)` used to rebuild the head: start from an empty `HTTPFields`, replay every field the
    /// handler wrote into it, then apply the contributions. It now applies contributions straight onto the
    /// head instead, which is only equivalent if the replay was a no-op — so these pin that it was.
    @Test
    func handlerFieldsSurviveAContribution() async throws {
        let record = RecordedResponse()
        var registry = ResponseHeaderRegistry()
        registry.add(.set(.init("x-trace")!, "abc"))
        let sender = ResponseHeaderApplyingSender(
            wrapping: RecordingSender(record: record),
            registry: registry
        )
        try await rawRoute(
            sending: sender,
            fields: [.contentType: "text/plain", .cacheControl: "no-store"],
            body: Array("plain".utf8)
        )
        #expect(record.head?.headerFields[.contentType] == "text/plain")
        #expect(record.head?.headerFields[.cacheControl] == "no-store")
        #expect(record.head?.headerFields[.init("x-trace")!] == "abc")
    }

    /// A handler writing the *same name twice* — `Set-Cookie` is the case that cannot be folded — must
    /// keep both lines. The replay preserved repeated fields; applying onto the head has to as well.
    @Test
    func repeatedHandlerFieldsSurviveAContribution() async throws {
        let record = RecordedResponse()
        var registry = ResponseHeaderRegistry()
        registry.add(.set(.init("x-trace")!, "abc"))
        var fields = HTTPFields()
        fields.append(HTTPField(name: .setCookie, value: "a=1"))
        fields.append(HTTPField(name: .setCookie, value: "b=2"))
        let sender = ResponseHeaderApplyingSender(
            wrapping: RecordingSender(record: record),
            registry: registry
        )
        try await rawRoute(sending: sender, fields: fields, body: Array("plain".utf8))
        #expect(record.head?.headerFields[values: .setCookie] == ["a=1", "b=2"])
        #expect(record.head?.headerFields[.init("x-trace")!] == "abc")
    }

    /// `.setIfAbsent` must defer to what the *handler* wrote, which only works if the handler's fields are
    /// already in place when contributions are applied.
    @Test
    func setIfAbsentDefersToAHandlerWrittenField() async throws {
        let record = RecordedResponse()
        var registry = ResponseHeaderRegistry()
        registry.add(.setIfAbsent(.contentType, "application/json"))
        registry.add(.setIfAbsent(.cacheControl, "no-store"))
        let sender = ResponseHeaderApplyingSender(
            wrapping: RecordingSender(record: record),
            registry: registry
        )
        try await rawRoute(
            sending: sender,
            fields: [.contentType: "text/plain"],
            body: Array("plain".utf8)
        )
        #expect(record.head?.headerFields[.contentType] == "text/plain", "the handler's own wins")
        #expect(record.head?.headerFields[.cacheControl] == "no-store", "the absent one is filled in")
    }

    /// A contribution replacing a field the handler wrote — `.set` beats the handler, `.setIfAbsent` does
    /// not, and that ordering is what the middleware-last tier means.
    @Test
    func setOverridesAHandlerWrittenField() async throws {
        let record = RecordedResponse()
        var registry = ResponseHeaderRegistry()
        registry.add(.set(.cacheControl, "public"))
        let sender = ResponseHeaderApplyingSender(
            wrapping: RecordingSender(record: record),
            registry: registry
        )
        try await rawRoute(
            sending: sender,
            fields: [.cacheControl: "no-store"],
            body: Array("plain".utf8)
        )
        #expect(record.head?.headerFields[.cacheControl] == "public")
        #expect(record.head?.headerFields[values: .cacheControl].count == 1)
    }

    /// Nothing contributed: the head must arrive exactly as written. The empty-contribution guard returns
    /// the response untouched, so this pins that "untouched" really is untouched.
    @Test
    func headIsUnchangedWhenNothingContributes() async throws {
        let record = RecordedResponse()
        try await rawRoute(
            sending: applying(to: record),
            fields: [.contentType: "text/plain", .cacheControl: "no-store"],
            body: Array("plain".utf8)
        )
        #expect(record.head?.headerFields[.contentType] == "text/plain")
        #expect(record.head?.headerFields[.cacheControl] == "no-store")
    }

    /// Contributed headers still reach a raw route's head — the reason the wrapper exists at all, which
    /// the deferral must not regress.
    @Test
    func contributedHeadersStillReachARawHead() async throws {
        let record = RecordedResponse()
        var registry = ResponseHeaderRegistry()
        registry.add(.set(.init("x-trace")!, "abc"))
        let sender = ResponseHeaderApplyingSender(
            wrapping: RecordingSender(record: record),
            registry: registry
        )
        try await rawRoute(sending: sender, body: Array("plain".utf8))
        #expect(record.head?.headerFields[.init("x-trace")!] == "abc")
    }
}
