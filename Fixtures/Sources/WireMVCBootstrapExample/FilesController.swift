// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

package import Foundation
package import HTTPTypes
package import Wire
package import WireMVC

// `@FileResponse`, served for real: the one place the generated file terminal runs. The routes serve from a
// directory each route writes on first use, so the suite needs no fixture files on disk and
// knows every byte the routes can send.

/// The bytes the fixture file holds: 1000 bytes of a repeating, position-revealing pattern, so a test can
/// tell which range it was sent rather than only how long it was.
package enum FileFixture {
    package static let name = "sample.txt"
    package static let size = 1000
    package static let bytes: [UInt8] = (0..<size).map { UInt8(ascii: "a") + UInt8($0 % 26) }

    /// Where the fixture lives: one directory per process, so concurrent suites do not race on a file.
    package static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wire-mvc-file-fixture-\(ProcessInfo.processInfo.processIdentifier)")

    package static var path: String { directory.appendingPathComponent(name).path }

    static func write() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        guard (try? Data(contentsOf: url)) != Data(bytes) else { return }
        try? Data(bytes).write(to: url, options: .atomic)
    }
}

@Singleton
@Controller("/files")
package struct FilesController {

    /// The whole shape: a file by name, with `Range` and `If-Range` bound as headers and a missing file
    /// mapped to `404`. The name is confined to the fixture directory — a route that accepts a name for a
    /// file under a root has to do that itself.
    @Get("/{name}")
    @FileResponse
    @ErrorResponse(WireMVCFileError.self, .notFound)
    package func file(
        @Path name: String,
        @Header("Range") range: String?,
        @Header("If-Range") ifRange: String?
    ) throws -> WireMVCFile {
        FileFixture.write()
        guard !name.contains("/"), !name.hasPrefix(".") else { throw WireMVCFileError.notFound(path: name) }
        return try WireMVCFile(
            path: FileFixture.directory.appendingPathComponent(name).path,
            contentType: "text/plain; charset=utf-8",
            range: range,
            ifRange: ifRange,
            chunkSize: 128
        )
    }

    /// A route header beside the file's own. `Cache-Control` is the route's to say and survives; the file
    /// states framing, and a route constant naming `Content-Type` still beats the file's seeded one.
    @Get("/cached/{name}")
    @FileResponse
    @ResponseHeader(.cacheControl, "max-age=60")
    @ResponseHeader(.contentType, "application/octet-stream")
    @ErrorResponse(WireMVCFileError.self, .notFound)
    package func cached(@Path name: String) throws -> WireMVCFile {
        FileFixture.write()
        guard name == FileFixture.name else { throw WireMVCFileError.notFound(path: name) }
        return try WireMVCFile(path: FileFixture.path, contentType: "text/plain")
    }

    /// The response tuple: the handler's returned fields fold in under the file's head, and a returned
    /// status is what a whole file answers with.
    @Get("/tagged/{name}")
    @FileResponse
    @ErrorResponse(WireMVCFileError.self, .notFound)
    package func tagged(
        @Path name: String,
        @Header("Range") range: String?
    ) throws -> (status: HTTPResponse.Status, headers: HTTPFields, body: WireMVCFile) {
        FileFixture.write()
        guard name == FileFixture.name else { throw WireMVCFileError.notFound(path: name) }
        let file = try WireMVCFile(path: FileFixture.path, contentType: "text/plain", range: range)
        // `Content-Length` here is a lie the file's head replaces; `x-file` is the handler's to say.
        return (.nonAuthoritativeInformation, [.init("x-file")!: name, .contentLength: "1"], file)
    }
}
