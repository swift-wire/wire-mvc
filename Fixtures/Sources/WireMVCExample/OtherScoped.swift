import HTTPTypes
import Synchronization
import Wire
import WireMVC

// Per-root reachability validation (M5.4.6): a SECOND `@Scoped(seed: HTTPRequest.self)` controller sharing
// the seed with WhoAmIController, each reaching its OWN request-scoped resource. Each controller's
// scope-entry thunk constructs (and tears down) only *its* reachable subgraph, so a request routed to
// /whoami never builds or tears down OtherResource, and a /other request never touches RequestResource —
// asserted via the two teardown probes in main.swift.

let otherTeardownProbe = Atomic<Int>(0)

@Scoped(seed: HTTPRequest.self)
struct OtherResource: Sendable {
    @Inject init(request: HTTPRequest) {}
    @Teardown func close() { otherTeardownProbe.add(1, ordering: .relaxed) }
}

@Scoped(seed: HTTPRequest.self)
@Controller("/other")
struct OtherController: Sendable {
    @Inject var resource: OtherResource  // request-scoped — reached only from OtherController

    @Get
    @JSONResponse
    func get() async throws -> Bool { true }
}
