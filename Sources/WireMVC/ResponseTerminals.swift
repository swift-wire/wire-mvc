import HTTPTypes

// The generated terminals' shared shape: **the terminal owns the response-header registry, and drains it
// exactly once.**
//
// A typed route needs the middleware's contributions on two paths that are not exclusive — the outcome it
// built, and the `@ErrorResponse` mapping of a throw. Draining at both sites is what let a *deferred*
// contribution run twice: the success drain gets part-way through the `onSend` closures, one throws, and the
// mapped-error drain re-runs the ones that already succeeded (#176). Generated code cannot close
// that itself. `drain()` is `consuming`, and the two sites are neither exclusive (the buffered `do`/`catch`)
// nor even reachable (the streaming pair, since a noncopyable value captured by a closure cannot be consumed
// at all, once or twice).
//
// So the registry is handed *in*, and the drain happens here: once, after `building` has run the handler,
// before either branch reaches the wire. It is the same move the response sender already made for the same
// reason — see `wireMVCStreamingTerminal`'s note on consuming the sender once, outside the `do`/`catch`.

/// Everything one drain produced: the contributions, and the error if evaluating them failed part-way.
///
/// Reported rather than thrown, because the terminal must still write a response — a throw escaping with the
/// sender unconsumed turns a mapped `403` into a dropped connection, which is the failure the whole tier
/// exists to prevent.
struct WireMVCDrainedHeaders {
    var contributions: [ResponseHeaderContribution] = []
    var failure: (any Error)?
}

/// Drain `registry` exactly once.
///
/// An `onSend` closure that throws part-way discards **every** contribution rather than applying the prefix
/// that already computed — the documented answer for a contribution that fails to compute, and now the only
/// one, since there is no second drain whose prefix could run again.
func wireMVCDrainedHeaders(from registry: consuming ResponseHeaderRegistry) async -> WireMVCDrainedHeaders {
    do {
        return WireMVCDrainedHeaders(contributions: try await registry.drain())
    } catch {
        return WireMVCDrainedHeaders(failure: error)
    }
}

/// Fold `contributions` onto fields a route has already resolved.
///
/// Applying the drain *after* the outcome exists is equivalent to passing it to the same
/// ``WireMVCResponseHeaders/resolved(statics:returned:middleware:)`` call that built those fields: middleware
/// contributions apply last, over whatever `statics` and `returned` composed, so re-entering with the composed
/// result as `returned` and no statics reproduces it exactly. The mapped-error path has always relied on that
/// equivalence; this is the same step, moved to where one drain can reach both branches.
func wireMVCResolved(
    _ fields: consuming HTTPFields,
    applying contributions: [ResponseHeaderContribution]
) -> HTTPFields {
    WireMVCResponseHeaders.resolved(returned: fields, middleware: contributions)
}

/// Which outcome a terminal will send, given what `building` produced and what the drain did.
///
/// A drain that failed maps like a route error — but a route error that *also* happened wins, because it is
/// the one that says why the response is not the one the handler asked for.
func wireMVCSettled(
    _ produced: consuming Result<WireMVCOutcome, any Error>,
    drained: WireMVCDrainedHeaders,
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws -> WireMVCOutcome {
    switch produced {
    case .success(let built):
        guard let failure = drained.failure else { return built }
        return try await errorMapping(failure)
    case .failure(let wireMVCError):
        return try await errorMapping(wireMVCError)
    }
}

/// The streaming sibling of ``wireMVCSettled(_:drained:errorMapping:)`` — same rule, but a produced value
/// that survives stays a stream rather than collapsing to a buffered outcome.
func wireMVCSettled<Producer: WireMVCBodyProducer>(
    _ produced: consuming Result<WireMVCStreamingOutcome<Producer>, any Error>,
    drained: WireMVCDrainedHeaders,
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws -> WireMVCTerminalOutcome<Producer> {
    switch produced {
    case .success(let streaming):
        guard let failure = drained.failure else { return .stream(streaming) }
        return .buffered(try await errorMapping(failure))
    case .failure(let wireMVCError):
        return .buffered(try await errorMapping(wireMVCError))
    }
}

// MARK: - The buffered terminal

// Three overloads, exactly as `wireMVCStreamingTerminal` has three, and for the reason its own notes give:
// a closure only **borrows** what it captures, so a route body that has moved inside `building` can no
// longer collect from the reader (`collectBody` consumes) or lend it to a `.bodyStream` binding. The reader
// is therefore owned here and handed to `building` as a consuming parameter — which is a move, not a
// capture — keeping the read inside the same region `errorMapping` maps.

/// The generated terminal for a **buffered** route.
///
/// The sibling of ``wireMVCStreamingTerminal(responseSender:responseHeaders:building:errorMapping:)``, and
/// shaped like it deliberately: `building` carries everything that can fail before the head goes out — scope
/// entry, parameter binding, the handler call, the encode — so all of it maps through `errorMapping`, and the
/// sender is consumed once, after the discriminant, which is what the ownership checker requires.
///
/// **The drain sits between them.** After `building`, so a deferred contribution still reads what the handler
/// did. Before anything reaches the wire, so a throw *from* the drain maps through `@ErrorResponse` exactly as
/// a route error does. On every path, so a handler that throws still keeps the contributions a mapped `401`
/// needs for its `WWW-Authenticate`. And once, because the registry is owned here rather than captured.
public func wireMVCBufferedTerminal<Sender: HTTPResponseSender & ~Copyable>(
    responseSender: consuming Sender,
    responseHeaders: consuming ResponseHeaderRegistry,
    building: () async throws -> WireMVCOutcome,
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable {
    let wireMVCProduced: Result<WireMVCOutcome, any Error>
    do {
        wireMVCProduced = .success(try await building())
    } catch let wireMVCError {
        wireMVCProduced = .failure(wireMVCError)
    }
    let wireMVCDrained = await wireMVCDrainedHeaders(from: responseHeaders)
    var wireMVCOutcome = try await wireMVCSettled(
        wireMVCProduced,
        drained: wireMVCDrained,
        errorMapping: errorMapping
    )
    wireMVCOutcome.headerFields = wireMVCResolved(
        wireMVCOutcome.headerFields,
        applying: wireMVCDrained.contributions
    )
    try await wireMVCOutcome.send(on: responseSender)
}

/// The buffered terminal for a route that **collects** its request body.
public func wireMVCBufferedTerminal<
    Sender: HTTPResponseSender & ~Copyable,
    Reader: AsyncReader & ~Copyable
>(
    responseSender: consuming Sender,
    responseHeaders: consuming ResponseHeaderRegistry,
    collectingBodyFrom reader: consuming sending Reader,
    building: ([UInt8]) async throws -> WireMVCOutcome,
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable, Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
    let wireMVCProduced: Result<WireMVCOutcome, any Error>
    do {
        let requestBody = try await WireMVCRequest.collectBody(reader)
        wireMVCProduced = .success(try await building(requestBody))
    } catch let wireMVCError {
        wireMVCProduced = .failure(wireMVCError)
    }
    let wireMVCDrained = await wireMVCDrainedHeaders(from: responseHeaders)
    var wireMVCOutcome = try await wireMVCSettled(
        wireMVCProduced,
        drained: wireMVCDrained,
        errorMapping: errorMapping
    )
    wireMVCOutcome.headerFields = wireMVCResolved(
        wireMVCOutcome.headerFields,
        applying: wireMVCDrained.contributions
    )
    try await wireMVCOutcome.send(on: responseSender)
}

/// The buffered terminal for a route whose binding **reads the request body incrementally** — a
/// `@RequestBinding(.readerBody)` or `.bodyStream` parameter on a route whose *response* is buffered.
public func wireMVCBufferedTerminal<
    Sender: HTTPResponseSender & ~Copyable,
    Reader: AsyncReader & ~Copyable
>(
    responseSender: consuming Sender,
    responseHeaders: consuming ResponseHeaderRegistry,
    lendingBodyFrom reader: consuming sending Reader,
    building: (consuming Reader) async throws -> WireMVCOutcome,
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable, Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
    let wireMVCProduced: Result<WireMVCOutcome, any Error>
    do {
        wireMVCProduced = .success(try await building(reader))
    } catch let wireMVCError {
        wireMVCProduced = .failure(wireMVCError)
    }
    let wireMVCDrained = await wireMVCDrainedHeaders(from: responseHeaders)
    var wireMVCOutcome = try await wireMVCSettled(
        wireMVCProduced,
        drained: wireMVCDrained,
        errorMapping: errorMapping
    )
    wireMVCOutcome.headerFields = wireMVCResolved(
        wireMVCOutcome.headerFields,
        applying: wireMVCDrained.contributions
    )
    try await wireMVCOutcome.send(on: responseSender)
}
