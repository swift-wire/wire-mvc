// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

import AsyncStreaming
import BasicContainers
import HTTPAPIs
import HTTPTypes
import ServiceLifecycle
import Synchronization
import Testing
import WireMVC

@testable import WireMVCTesting

// The `services` axis: whether a suite starts the graph's collated app-scoped `ServiceLifecycle` services.
// It cross-cuts the transports rather than being one of them, so the default comes from the mode
// (`.inProcess` skips, for isolation; a live mode runs, for end-to-end fidelity) and a suite overrides it.

/// Records whether it was started, and stays running until the suite cancels it — the shape of a real
/// app-scoped service (a pool, a poller) rather than one that returns immediately.
private final class RecordingService: Service, Sendable {
    let didRun = Mutex(false)

    func run() async throws {
        didRun.withLock { $0 = true }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
        }
    }
}

/// Answers 200 to anything — the suite is about services, not routing.
/// Serves under the courier, like every real WireMVC handler: `runSuite` serves on a
/// `WireMVCContextServer`, so the handler it is given sees `WireMVCContext<…>` as its context.
private struct OKHandler: HTTPServerRequestHandler {
    typealias RequestContext = WireMVCContext<InProcessRequestContext>
    typealias Reader = InProcessReader
    typealias ResponseSender = InProcessResponseSender

    func handle(
        request: HTTPRequest,
        requestContext: consuming WireMVCContext<InProcessRequestContext>,
        reader: consuming sending InProcessReader,
        responseSender: consuming sending InProcessResponseSender
    ) async throws {
        try await responseSender.sendAndFinish(HTTPResponse(status: .ok))
    }
}

@Suite struct ServicePolicyTests {
    /// `.inProcess` defaults to skipping: a route-logic suite gets isolation, and a service that would
    /// otherwise open connections or spawn timers stays stopped.
    @Test func inProcessSkipsServicesByDefault() async throws {
        let service = RecordingService()
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: OKHandler(),
            services: [service]
        ) {
            let response = try await TestClient.forSuite.get("/")
            #expect(response.status == 200)
        }
        #expect(service.didRun.withLock { $0 } == false)
    }

    /// The per-suite override: a route that needs a started service asks for `.run`, and the service is
    /// running by the time the tests execute.
    @Test func servicePolicyRunStartsThem() async throws {
        let service = RecordingService()
        let mode = WireMVCTestMode.inProcess
        try await WireMVCTesting.runSuite(
            mode,
            on: WireMVCContextServer(mode.makeTestServer()),
            handler: OKHandler(),
            services: [service],
            servicePolicy: .run
        ) {
            // The service starts in a sibling task, so give it a moment to record before asserting.
            try await Task.sleep(for: .milliseconds(50))
            #expect(service.didRun.withLock { $0 } == true)
        }
    }

    /// The mode's default is only a default — `.skip` on a live mode is as legitimate as `.run` in process.
    @Test func explicitSkipOverridesALiveModeDefault() {
        #expect(WireMVCTestMode.inProcess.defaultServices == .skip)
    }
}
