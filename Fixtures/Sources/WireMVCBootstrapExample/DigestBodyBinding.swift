// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import AsyncStreaming
import BasicContainers
package import HTTPTypes
package import WireMVC

// A **streaming** request binding declared outside WireMVC — the request-side counterpart of `@CSVResponse`,
// and the first binding in this repo that never holds the request body.
//
// `@TextBody` next door takes `body: [UInt8]?`: the terminal collects the whole request before the binding
// runs. This one is handed the reader and walks it, keeping a running digest and a byte count. Its peak
// memory is one chunk regardless of the request's size, which is the only observable difference between the
// two tiers and therefore the thing the tests have to pin.

/// What a streamed body reduces to: how long it was, and a checksum over it.
///
/// Deliberately not the bytes. A binding that returned `[UInt8]` would have buffered the request to build
/// it, which is exactly what this tier exists to avoid — the value it produces has to be *smaller* than the
/// body or streaming bought nothing.
package struct BodyDigest: Sendable, Codable, Equatable {
    package let byteCount: Int
    /// FNV-1a, chosen because it is a fold over bytes with no block alignment: it can be advanced one chunk
    /// at a time without buffering, which a block-based hash would need care to do.
    package let checksum: UInt64

    package init(byteCount: Int, checksum: UInt64) {
        self.byteCount = byteCount
        self.checksum = checksum
    }
}

package enum DigestError: Error {
    /// The body exceeded what this route accepts. Thrown *during* the walk, which is the point: a collecting
    /// binding can only reject an oversized body after receiving it.
    case tooLarge(afterBytes: Int)
}

/// `@DigestBody digest: BodyDigest` — reduces the request body without holding it.
@RequestBinding(.readerBody)
@propertyWrapper
package struct DigestBody<Value> {
    package var wrappedValue: Value
    package init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    package init(wrappedValue: Value, _ name: String) { self.wrappedValue = wrappedValue }
}

extension DigestBody: RequestBodyReading where Value == BodyDigest {
    package static func bindReader<Reader: AsyncReader & ~Copyable>(
        name: String,
        request: HTTPRequest,
        pathParameters: [String: Substring],
        reader: consuming Reader,
        coding: WireMVCCoding
    ) async throws -> BodyDigest
    where Reader.ReadElement == UInt8, Reader.FinalElement == HTTPFields? {
        var state = (count: 0, hash: UInt64(14_695_981_039_346_656_037))
        try await WireMVCRequest.streamBody(reader, into: &state) { state, span in
            for index in 0..<span.count {
                state.hash = (state.hash ^ UInt64(span[index])) &* 1_099_511_628_211
                state.count += 1
            }
            // Rejected mid-stream, before the rest of the body has even been read. A `@RequestBinding(.body)`
            // binding cannot do this — by the time it is called, the bytes are already in memory.
            if state.count > 4096 { throw DigestError.tooLarge(afterBytes: state.count) }
        }
        return BodyDigest(byteCount: state.count, checksum: state.hash)
    }
}

/// The client half. A streaming binding sends an ordinary buffered body — there is no streaming *client*
/// tier, and none is needed: the asymmetry is real, because a server must survive a body it did not choose
/// the size of and a client already holds whatever it is sending.
extension DigestBody: RequestBodySendable where Value == BodyDigest {
    package static func sendBody(
        name: String,
        value: BodyDigest,
        into request: inout WireMVCOutgoingRequest,
        coding: WireMVCCoding
    ) throws -> (bytes: [UInt8], contentType: String) {
        // The client cannot reconstruct a body from its digest, so it sends one that *has* that digest only
        // in the trivial case. This exists so the route is reachable from the generated typed client at all;
        // `DigestRouteTests` drives the interesting cases over the untyped client with real bodies.
        ([UInt8](repeating: UInt8(ascii: "x"), count: value.byteCount), "application/octet-stream")
    }
}
