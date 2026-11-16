// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import Wire
package import WireMVC

// Request bodies held to a limit: `@BytesBody` for a body that *is* the payload, and `@RequestBodyLimit` at
// both scopes. The controller raises its routes' limit past the 1 MB default, one route lowers it again, and
// one route reads no body at all — which the controller's limit has to skip rather than fail.

/// What an upload reduced to: its name and how many bytes arrived.
package struct Upload: Codable, Sendable, Equatable {
    package let name: String
    package let byteCount: Int

    package init(name: String, byteCount: Int) {
        self.name = name
        self.byteCount = byteCount
    }
}

/// A JSON document to echo, for the limit as it applies to `@JSONBody`.
package struct Memo: Codable, Sendable, Equatable {
    package let text: String

    package init(text: String) { self.text = text }
}

/// The upload limit, named once for the annotation and the tests.
///
/// Its own type rather than a member of `UploadsController`: an attribute on a type cannot name that type's
/// own members — the compiler resolves the attribute while resolving the type, and reports a circular
/// reference.
package enum UploadLimits {
    /// Two mebibytes: past the default, so a body between the two is accepted only because of the annotation.
    package static let maximumUpload = 2 * 1024 * 1024
}

@Singleton
@Controller("/uploads")
@RequestBodyLimit(UploadLimits.maximumUpload)
package struct UploadsController {
    /// The route a client uploads to, under the controller's limit.
    @Put("/{name}")
    @JSONResponse
    package func put(@Path name: String, @BytesBody bytes: [UInt8]) -> Upload {
        Upload(name: name, byteCount: bytes.count)
    }

    /// The route's own limit beats the controller's, in either direction — here it lowers it.
    @Post("/memo")
    @JSONResponse
    @RequestBodyLimit(64)
    package func memo(@JSONBody memo: Memo) -> Memo {
        memo
    }

    /// A streamed body under a route limit smaller than the binding's own. `@DigestBody` refuses past 4 KiB
    /// by itself; the route's 1 KiB is enforced by the reader the terminal hands it, so a body between the two
    /// is refused although the binding alone would have taken it.
    @Post("/digest")
    @JSONResponse
    @RequestBodyLimit(1024)
    @ErrorResponse(DigestError.self, .contentTooLarge)
    package func digest(@DigestBody digest: BodyDigest) -> BodyDigest {
        digest
    }

    /// No body, so the controller's limit does not apply — and is not an error.
    @Get("/limit")
    @JSONResponse
    package func limit() -> Int {
        UploadLimits.maximumUpload
    }
}
