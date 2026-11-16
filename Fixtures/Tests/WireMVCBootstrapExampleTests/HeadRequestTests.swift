// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Foundation
import HTTPTypes
import Testing
import WireMVCTesting

@testable import WireMVCBootstrapExample

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// `HEAD` (RFC 9110 §9.3.2), served for real. Before the router implied it, a `HEAD` to a `@Get` path was a
// 405 with `Allow: GET` on NIOHTTPServer — measured with curl against this fixture before the change.
//
// Two layers of evidence. `TestClient` checks status and fields in both modes; in-process, it also sees every
// byte the route wrote, so an empty body there is the sender wrapper's doing. `URLSession` cannot show
// whether body bytes followed a `HEAD` response on the wire — it discards them — so the live suite also speaks
// HTTP/1.1 over a raw socket, pipelining a `GET` behind each `HEAD`: if anything followed the `HEAD`'s head,
// the second response would not start where it must.

private func expectAnsweredAsGetWouldBe(_ head: TestResponse, _ get: TestResponse) {
    #expect(head.status == get.status)
    #expect(head.head?.headerFields[.contentType] == get.head?.headerFields[.contentType])
    #expect(head.head?.headerFields[.contentLength] == get.head?.headerFields[.contentLength])
    #expect(head.body.isEmpty)
}

/// The assertions that hold whichever transport carries them.
private func headIsAnsweredFromGet() async throws {
    try await withClient { client in
        let get = try await client.get("/hello/ci")
        let head = try await client.send("HEAD", "/hello/ci")
        #expect(get.status == 200)
        #expect(get.head?.headerFields[.contentLength] == String(get.body.count))
        expectAnsweredAsGetWouldBe(head, get)
    }
}

private func headOnAStreamingRouteSendsTheHeadOnly() async throws {
    try await withClient { client in
        let get = try await client.get("/pages/home")
        let head = try await client.send("HEAD", "/pages/home")
        #expect(get.status == 200)
        #expect(!get.body.isEmpty)
        #expect(head.status == 200)
        #expect(head.head?.headerFields[.contentType] == get.head?.headerFields[.contentType])
        #expect(head.body.isEmpty)
    }
}

private func headOnARawRouteSendsTheHeadOnly() async throws {
    try await withClient { client in
        let get = try await client.get("/hello/raw/ci")
        let head = try await client.send("HEAD", "/hello/raw/ci")
        #expect(get.bodyText.hasPrefix("raw:"))
        expectAnsweredAsGetWouldBe(head, get)
    }
}

private func anExplicitHeadRouteBeatsTheImpliedOne() async throws {
    try await withClient { client in
        let head = try await client.send("HEAD", "/hello/bulk")
        #expect(head.status == 200)
        #expect(head.head?.headerFields[.init("x-answered-by")!] == "bulkProbe")
        #expect(head.head?.headerFields[.contentLength] == String(HelloController<RealGreeter>.bulkSize))
        #expect(head.body.isEmpty)
    }
}

private func aMappedRefusalToHeadCarriesNoBody() async throws {
    try await withClient { client in
        let get = try await client.get("/hello/explained")
        let head = try await client.send("HEAD", "/hello/explained")
        #expect(get.status == 422)
        #expect(get.bodyText.contains("no tenant"))
        expectAnsweredAsGetWouldBe(head, get)
    }
}

private func theFallbackAnswersHeadWithoutItsBody() async throws {
    try await withClient { client in
        let head = try await client.send("HEAD", "/no/such/route")
        #expect(head.status == 404)
        #expect(head.body.isEmpty)
    }
}

private func allowListsHead() async throws {
    try await withClient { client in
        let response = try await client.delete("/hello/ci")
        #expect(response.status == 405)
        #expect(response.head?.headerFields[.allow] == "GET, HEAD")
    }
}

@Suite(.wiremvc(.inProcess))
struct HeadRequestInProcessTests {
    @Test func aHeadIsAnsweredFromTheGetRoute() async throws { try await headIsAnsweredFromGet() }
    @Test func aStreamingRouteSendsTheHeadOnly() async throws { try await headOnAStreamingRouteSendsTheHeadOnly() }
    @Test func aRawRouteSendsTheHeadOnly() async throws { try await headOnARawRouteSendsTheHeadOnly() }
    @Test func anExplicitHeadRouteWins() async throws { try await anExplicitHeadRouteBeatsTheImpliedOne() }
    @Test func aMappedRefusalCarriesNoBody() async throws { try await aMappedRefusalToHeadCarriesNoBody() }
    @Test func theFallbackCarriesNoBody() async throws { try await theFallbackAnswersHeadWithoutItsBody() }
    @Test func allowListsHeadBesideGet() async throws { try await allowListsHead() }
}

@Suite(.wiremvc(.swiftHttpServer))
struct HeadRequestOverTheWireTests {
    @Test func aHeadIsAnsweredFromTheGetRoute() async throws { try await headIsAnsweredFromGet() }
    @Test func aStreamingRouteSendsTheHeadOnly() async throws { try await headOnAStreamingRouteSendsTheHeadOnly() }
    @Test func aRawRouteSendsTheHeadOnly() async throws { try await headOnARawRouteSendsTheHeadOnly() }
    @Test func anExplicitHeadRouteWins() async throws { try await anExplicitHeadRouteBeatsTheImpliedOne() }
    @Test func aMappedRefusalCarriesNoBody() async throws { try await aMappedRefusalToHeadCarriesNoBody() }
    @Test func theFallbackCarriesNoBody() async throws { try await theFallbackAnswersHeadWithoutItsBody() }
    @Test func allowListsHeadBesideGet() async throws { try await allowListsHead() }

    /// Each `HEAD` is pipelined ahead of a `GET` on one connection. The server has to have written nothing
    /// after the `HEAD`'s head — no body, no chunk terminator — for the `GET`'s status line to come next, and
    /// the connection has to have survived the `HEAD` for the `GET` to be answered at all.
    @Test(arguments: ["/hello/ci", "/pages/home", "/hello/raw/ci", "/hello/explained", "/hello/bulk", "/nope"])
    func nothingFollowsTheHeadOnTheWire(_ path: String) async throws {
        try await withClient { client in
            let address = try #require(client.loopbackAddress)
            let exchange = try rawExchange(
                host: address.host,
                port: address.port,
                "HEAD \(path) HTTP/1.1\r\nHost: test\r\n\r\n"
                    + "GET /hello/wire HTTP/1.1\r\nHost: test\r\n\r\n",
                until: #"{"message":"Hello, wire!"}"#
            )
            // The first response is a head alone: its blank line is followed directly by the next status line.
            let firstHeadEnd = try #require(exchange.range(of: "\r\n\r\n"))
            let afterFirst = exchange[firstHeadEnd.upperBound...]
            #expect(afterFirst.hasPrefix("HTTP/1.1 200"), "bytes followed the HEAD response: \(afterFirst.prefix(80))")
            #expect(afterFirst.hasSuffix(#"{"message":"Hello, wire!"}"#))
        }
    }
}

/// Write `request` to a fresh TCP connection and read until what has arrived ends with `terminator`.
///
/// Read to a terminator rather than to the server's close: the connection is kept alive after the last
/// response, which is what lets the pipelined `GET` be answered at all, so a close may never come.
private func rawExchange(host: String, port: Int, _ request: String, until terminator: String) throws -> String {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { throw RawExchangeError.socket }
    defer { close(fd) }
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { throw RawExchangeError.address(host) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw RawExchangeError.connect(errno) }
    // A bounded wait, so a server that kept the connection open fails the test instead of hanging it.
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let bytes = Array(request.utf8)
    var sent = 0
    while sent < bytes.count {
        let wrote = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote > 0 else { throw RawExchangeError.write(errno) }
        sent += wrote
    }
    var received: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count == 0 { break }
        guard count > 0 else { throw RawExchangeError.read(errno, String(decoding: received, as: UTF8.self)) }
        received += chunk[..<count]
        if received.count >= terminator.utf8.count,
            received.suffix(terminator.utf8.count).elementsEqual(terminator.utf8)
        {
            break
        }
    }
    return String(decoding: received, as: UTF8.self)
}

private enum RawExchangeError: Error {
    case socket
    case address(String)
    case connect(Int32)
    case write(Int32)
    case read(Int32, String)
}
