public import NIOHTTPServer
public import WireMVCTesting

// The opt-in NIO half of WireMVC's test support. Core `WireMVCTesting` declares the abstract
// ``WireMVCTestServer`` seam and references only the proposal's `HTTPServer`; the concrete
// `NIOHTTPServer` conformance lives here, so `swift-http-server` enters a consumer's package graph
// only through *this* product. A test target serving on `NIOHTTPServer` depends on it; a
// framework-agnostic consumer of `WireMVC`/`WireMVCTesting` never resolves the NIO stack.

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
