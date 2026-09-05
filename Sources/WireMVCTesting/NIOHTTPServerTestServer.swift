// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

#if NIOHTTPServer
public import NIOHTTPServer

// The NIO half of WireMVC's test support, behind the off-by-default `NIOHTTPServer` trait. With the trait
// off this file compiles to nothing, `swift-http-server` is pruned from the package graph entirely, and
// `WireMVCTesting` names only the proposal's abstract `HTTPServer` — so a framework-agnostic consumer of
// `WireMVC`/`WireMVCTesting` neither links nor *resolves* the NIO stack. A consumer that wants the live
// `.swiftHttpServer` mode enables the trait on its wire-mvc dependency.

extension NIOHTTPServer: WireMVCTestServer {
    /// The port `NIOHTTPServer` bound, read off its `listeningAddresses` — the bound-port read-back the
    /// ephemeral suite modes need. Suspends until the first address binds.
    public var wireMVCBoundPort: Int {
        get async throws {
            guard let port = try await listeningAddresses.first?.port else {
                throw WireMVCTestingError.noListeningPort
            }
            return port
        }
    }
}
#endif
