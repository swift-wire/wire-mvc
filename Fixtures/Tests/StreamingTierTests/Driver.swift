import AsyncStreaming
import HTTPAPIs
import HTTPTypes
import WireMVC

/// Drives WireMVC's *shipped* `wireMVCStreamingTerminal` with the pieces a test wants to vary.
///
/// The generated terminal passes a `building` closure that carries scope entry, bindings and the header
/// drain. A test has none of that, so this assembles the same outcome from a handler plus the response
/// metadata — the terminal under test is the real one either way.
func drive<Producer: WireMVCBodyProducer, Sender: HTTPResponseSender & ~Copyable>(
    responseSender: consuming Sender,
    status: HTTPResponse.Status = .ok,
    headerFields: HTTPFields = [:],
    trailer: HTTPFields? = nil,
    handler: () async throws -> Producer,
    errorMapping: (any Error) async throws -> WireMVCOutcome
) async throws where Sender.Writer: ~Copyable {
    try await wireMVCStreamingTerminal(
        responseSender: responseSender,
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
