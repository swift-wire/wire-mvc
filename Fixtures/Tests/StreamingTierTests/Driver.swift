// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import AsyncStreaming
import HTTPAPIs
import HTTPTypes
import WireMVC

/// Drives WireMVC's *shipped* `wireMVCStreamingTerminal` with the pieces a test wants to vary.
///
/// The generated terminal passes a `building` closure that carries scope entry and bindings, and hands the
/// terminal the response-header registry alongside the sender. A test has none of that, so this assembles
/// the same outcome from a handler plus the response metadata — the terminal under test is the real one
/// either way.
///
/// `responseHeaders` defaults to an empty registry, which is what a route with no contributing middleware
/// has. A test that wants contributions passes one; it cannot be defaulted away, because the terminal owns
/// the drain and there is no overload that skips it — see `Notes/LinearResponseHeaderRegistry.md`,
/// *The sequel*.
func drive<Producer: WireMVCBodyProducer, Sender: HTTPResponseSender & ~Copyable>(
    responseSender: consuming Sender,
    responseHeaders: consuming ResponseHeaderRegistry = ResponseHeaderRegistry(),
    status: HTTPResponse.Status = .ok,
    headerFields: HTTPFields = [:],
    trailer: HTTPFields? = nil,
    handler: () async throws -> Producer,
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable {
    try await wireMVCStreamingTerminal(
        responseSender: responseSender,
        responseHeaders: responseHeaders,
        building: {
            WireMVCStreamingOutcome(
                status: status,
                headerFields: headerFields,
                producer: try await handler(),
                trailer: trailer
            )
        },
        errorMapping: errorMapping
    )
}
