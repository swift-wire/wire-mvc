import Logging
import NIOHTTPServer
import Wire
import WireMVC
import WireMVCRouter

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// `WireMVCTaskLocalLogging` end to end: the request-scoped `Logger` a handler injects is the one the
// *runtime* bound as a task-local, not one WireMVC minted.
//
// The native proposal server binds no task-local logger — Hummingbird is the runtime that does — so this
// fixture plays that part itself, wrapping the serve in `withLogger`. That is exactly what a Vapor app
// would add as middleware, and what the Hummingbird example gets for free.
//
// Two *different* loggers are bound, and that is the point of the fixture rather than an accident: a
// bootstrap-time one around `Wire.bootstrap()`, and a serve-time one around the serving task group. If the
// request logger were derived from the app-scoped binding (which snapshots the task-local at graph
// construction), the handler would see the bootstrap marker. Seeing the *serve* marker is what proves the
// binding re-reads `Logger.current` per request. Asserting a marker is merely present would pass under
// either behaviour and so prove nothing.

struct ExampleFailed: Error, CustomStringConvertible {
    let failures: [String]
    var description: String {
        "wire-mvc task-local logging example FAILED:\n" + failures.map { "  ✗ \($0)" }.joined(separator: "\n")
    }
}

func send(_ path: String, port: Int, headers: [String: String] = [:]) async throws -> (Int, Data) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = "GET"
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    let (data, response) = try await URLSession.shared.data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
}

/// A logger carrying a distinguishing marker, so the handler can say which scope it came from.
func probeLogger(marker: String) -> Logger {
    var logger = Logger(label: "WireMVCTaskLocalExample")
    logger[metadataKey: ProbeMetadata.marker] = .string(marker)
    return logger
}

// The app-scoped `Logger` binding snapshots the task-local as the graph is built, so this marker is what
// it captures — and what the request logger must NOT show.
let graph = try await withLogger(probeLogger(marker: "bootstrap")) { _ in
    try await Wire.bootstrap()
}

let server = NIOHTTPServer(
    logger: Logger(label: "WireMVCTaskLocalExample"),
    configuration: try .init(
        bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
        supportedHTTPVersions: [.http1_1],
        transportSecurity: .plaintext
    )
)

let wireMVCServer = WireMVCContextServer(server)
var builder = TrieRouteBuilder(for: wireMVCServer)
_ = try WireMVC.apply(graph, to: &builder)
let router = builder.finalize()

// The serve-time binding. Task-locals propagate into child tasks, so every request handled under this
// group sees it — standing in for Hummingbird's per-request `withLogger`.
try await withLogger(probeLogger(marker: "serve")) { _ in
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await wireMVCServer.serve(handler: router) }

        let addresses = try await server.listeningAddresses
        guard let port = addresses.first?.port else {
            throw ExampleFailed(failures: ["server did not bind a listening port"])
        }

        var failed: [String] = []
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  ✓ \(label)" : "  ✗ \(label)")
            if !condition { failed.append(label) }
        }

        let (status, body) = try await send("/probe", port: port)
        let probe = try JSONDecoder().decode(Probe.self, from: body)

        check(
            status == 200 && probe.loggerMarker == "serve",
            "WireMVCTaskLocalLogging  → the request logger adopted the task-local bound at serve time "
                + "(marker=\(probe.loggerMarker)), not the app-scoped snapshot taken at bootstrap"
        )

        // The contributed fields are folded onto the adopted logger, so an app's `@Contributes` log fields
        // keep working across a target switch — and the id binding still injects on its own.
        check(
            !probe.injectedRequestID.isEmpty
                && probe.loggerRequestID == probe.injectedRequestID,
            "WireMVCLogMetadata.stringEntries  → contributed fields fold onto the adopted logger, and "
                + "WireMVCRequest.id still injects directly"
        )

        // An inbound id is honoured identically to WireMVCLogging, so switching targets changes no app code.
        let (_, suppliedBody) = try await send("/probe", port: port, headers: ["X-Request-Id": "abc-123"])
        let supplied = try JSONDecoder().decode(Probe.self, from: suppliedBody)
        check(
            supplied.injectedRequestID == "abc-123" && supplied.loggerRequestID == "abc-123",
            "WireMVCRequest.correlationID  → an inbound X-Request-Id is honoured, as on the minting target"
        )

        group.cancelAll()
        if !failed.isEmpty { throw ExampleFailed(failures: failed) }
        print("wire-mvc task-local logging example OK — the handler's Logger came from the runtime")
    }
}
