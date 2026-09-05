// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the wire-mvc project authors

#if NIOHTTPServer
import Logging
public import NIOHTTPServer

// The batteries-included live mode for the proposal-native stack: a `NIOHTTPServer` the **test framework**
// owns and configures, not the app's. `.swiftHttpServer` is `.server(NIOHTTPServer(…))` with the server
// pre-filled — the app's `createServer()` is never involved, so a suite gets a plain loopback HTTP/1.1
// server whether or not production runs TLS, HTTP/2, or a tuned connection budget.

extension WireMVCTestMode where Server == NIOHTTPServer {
    /// Serve on a framework-owned `NIOHTTPServer` bound to an **ephemeral** loopback port, reading back the
    /// port the OS assigned. The default live mode: nothing has to pick a free port, and parallel suites
    /// cannot collide on one.
    public static var swiftHttpServer: WireMVCTestMode<NIOHTTPServer> {
        .server(makeTestServer(port: 0))
    }

    /// Serve on a framework-owned `NIOHTTPServer` bound to `port`. The client already knows where to reach
    /// it, so no bound-port read-back happens. Use when something outside the suite needs a predictable
    /// address; prefer ``swiftHttpServer`` otherwise.
    public static func swiftHttpServer(on port: Int) -> WireMVCTestMode<NIOHTTPServer> {
        .server(makeTestServer(port: port), on: port)
    }

    /// A plaintext HTTP/1.1 loopback server — the test-appropriate configuration, fixed here rather than
    /// taken from the app. `NIOHTTPServerConfiguration.init` rejects only an empty bind-target list, an
    /// empty HTTP-version set, and HTTP/2-over-plaintext; this configuration is none of those, so a throw
    /// means the upstream contract changed rather than anything a caller did.
    private static func makeTestServer(port: Int) -> NIOHTTPServer {
        let configuration: NIOHTTPServerConfiguration
        do {
            configuration = try NIOHTTPServerConfiguration(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: port),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        } catch {
            preconditionFailure("plaintext HTTP/1.1 loopback is not a valid NIOHTTPServer configuration: \(error)")
        }
        return NIOHTTPServer(logger: Logger(label: "WireMVCTesting"), configuration: configuration)
    }
}
#endif
