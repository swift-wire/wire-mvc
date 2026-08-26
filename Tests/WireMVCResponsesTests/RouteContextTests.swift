import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import Testing

@testable import WireMVC

// `RouteContext` on the box is what tells a route-scope middleware *which route it is folded onto* — the
// one thing the fold could not previously ask, since the match happens in the router and the generated
// register closure kept both halves to itself. These cover the carrying rather than the codegen: that the
// route survives every way the box can be taken apart and rebuilt, and that "no route" and "a route with
// no parameters" stay two different answers all the way through.

private struct BoxRequestContext: HTTPServerCapability.RequestContext {
    init() {}
}

/// A reader that is immediately at end of stream. Nothing here reads a body; the box just needs one.
private struct EmptyReader: AsyncReader {
    typealias ReadElement = UInt8
    typealias ReadFailure = Never
    typealias FinalElement = HTTPFields?
    typealias Buffer = UniqueArray<UInt8>

    mutating func read<Return: ~Copyable, Failure: Error>(
        body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
    ) async throws(EitherError<ReadFailure, Failure>) -> Return {
        var buffer = UniqueArray<UInt8>()
        do {
            return try await body(&buffer, .some(nil))
        } catch {
            throw EitherError.second(error)
        }
    }
}

private typealias Box = RequestResponseMiddlewareBox<BoxRequestContext, EmptyReader, RecordingSender>

private let request = HTTPRequest(method: .get, scheme: "http", authority: "test", path: "/documents/notes")

private func pendingBox(route: RouteContext?, record: RecordedResponse = RecordedResponse()) -> Box {
    .pending(
        request: request,
        requestContext: BoxRequestContext(),
        route: route,
        reader: EmptyReader(),
        responseSender: RecordingSender(record: record),
        responseHeaders: ResponseHeaderRegistry()
    )
}

private let matched = RouteContext(template: "/documents/{id}", pathParameters: ["id": "notes"])

@Suite("Route identity on the box")
struct RouteContextTests {
    /// The template is the *registration* text, not the request path. `/documents/notes` and
    /// `/things/notes` produce identical parameters, so the values alone cannot name the route — which is
    /// the whole reason the template rides along.
    @Test func aMatchedRouteCarriesItsTemplateAndParameters() {
        let box = pendingBox(route: matched)
        #expect(box.peekedRoute?.template == "/documents/{id}")
        #expect(box.peekedRoute?.pathParameters["id"] == "notes")
        #expect(box.peekedRoute?["id"] == "notes")
        #expect(box.peekedRoute?["missing"] == nil)
    }

    /// `nil` and empty are two different answers, and this is the pair that says so. The global tier folds
    /// around `handle`, so its box has no route at all; a matched route that declares no `@Path` has a
    /// route whose parameters are empty. Collapsing them into an empty dictionary would make "outside the
    /// router" indistinguishable from "matched, and takes nothing".
    @Test func noRouteIsNotTheSameAsARouteWithNoParameters() {
        #expect(pendingBox(route: nil).peekedRoute == nil)

        let parameterless = pendingBox(route: RouteContext(template: "/ping", pathParameters: [:]))
        let route = parameterless.peekedRoute
        #expect(route != nil)
        #expect(route?.template == "/ping")
        #expect(route?.pathParameters.isEmpty == true)
    }

    /// Contributing rebuilds the box, so it has to carry the route across — a contributing middleware is
    /// the commonest shape there is, and one that silently unnamed the route would leave everything
    /// further in unable to tell what it was folded onto.
    @Test func contributingCarriesTheRouteIntoTheRebuiltBox() async throws {
        let box = pendingBox(route: matched)
        let seen = try await box.contributing { headers in
            headers.add(.set(.init("x-test")!, "1"))
        } then: { rebuilt in
            rebuilt.peekedRoute
        }
        #expect(seen == matched)
    }

    /// The `responded` case keeps the route for the reason it keeps the request: an always-run observer
    /// runs *after* a gate answered, and wants to log which route was refused as much as it wants the
    /// request that asked for it.
    @Test func aGatesOwnResponseKeepsTheRoute() async throws {
        let record = RecordedResponse()
        let responded = try await pendingBox(route: matched, record: record)
            .respondingWith(.status(.unauthorized))
        #expect(responded.isPending == false)
        #expect(responded.peekedRoute == matched)
        #expect(record.head?.status == .unauthorized)
    }

    /// The same for the raw `responding(_:)` spelling, which hands the sender over instead of draining.
    @Test func aRawResponseKeepsTheRoute() async throws {
        let record = RecordedResponse()
        let responded = try await pendingBox(route: matched, record: record).responding { sender in
            try await WireMVCOutcome.status(.ok).send(on: sender)
        }
        #expect(responded.peekedRoute == matched)
        #expect(record.head?.status == .ok)
    }

    /// `withContents` is the primitive a *transforming* middleware rebuilds through, so both of its
    /// branches yield the route. `pending` is checked here; `responded` below.
    @Test func withContentsYieldsTheRouteOnThePendingBranch() async throws {
        let seen = try await pendingBox(route: matched).withContents(
            pending: { _, _, route, _, _, _ in route },
            responded: { _, route in route }
        )
        #expect(seen == matched)
    }

    @Test func withContentsYieldsTheRouteOnTheRespondedBranch() async throws {
        let responded = try await pendingBox(route: matched)
            .respondingWith(.status(.forbidden))
        let seen = try await responded.withContents(
            pending: { _, _, route, _, _, _ in route },
            responded: { _, route in route }
        )
        #expect(seen == matched)
    }

    /// The terminal's destructure sees the route off the *final* box, not off the register closure — which
    /// is what would make an upstream rewrite visible to it, the same property the request already has.
    @Test func withPendingContentsYieldsTheRoute() async throws {
        let box = pendingBox(route: matched)
        var seen: RouteContext?
        try await box.withPendingContents { _, _, route, _, sender, headers in
            seen = route
            _ = consume headers
            try await WireMVCOutcome.status(.ok).send(on: sender)
        }
        #expect(seen == matched)
    }
}
