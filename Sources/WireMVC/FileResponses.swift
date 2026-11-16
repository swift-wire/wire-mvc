// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

public import AsyncStreaming
import BasicContainers
import HTTPAPIs
public import HTTPTypes

#if canImport(FoundationEssentials)
public import FoundationEssentials
#else
public import Foundation
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// `@FileResponse`: a typed route that answers with a file's bytes, honouring `Range`.
//
// The handler returns a `WireMVCFile`, built from a path, a content type and the request's `Range` and
// `If-Range` values. Building it opens the file and resolves the request against it — so a missing file is
// a throw, mapped by `@ErrorResponse` like any other, and an unsatisfiable range is a `416` head rather than
// a truncated body. The generated terminal then wraps it in `WireMVCFileProducer`, which states the status
// and framing fields through `WireMVCBodyHead` and streams the bytes in chunks.
//
// File I/O is POSIX (`open`, `fstat`, `pread`) rather than `FileHandle`, which FoundationEssentials does not
// have: the core builds on Linux against FoundationEssentials alone. See
// `Documentation/Notes/StreamingResponseTier.md`, *File bodies*.

/// Why a ``WireMVCFile`` could not be built. Thrown from its initialiser, inside the route's mapped region,
/// so `@ErrorResponse(WireMVCFileError.self, .notFound)` turns it into a status. Unmapped, it is the
/// built-in `500`, as any unmapped throw is.
public enum WireMVCFileError: Error, Equatable, Sendable {
    /// Nothing at the path, or something that is not a regular file — a directory, a socket.
    case notFound(path: String)
    /// The path names a file that could not be opened or read: permissions, an I/O error. `errno` is the
    /// system's code.
    case unreadable(path: String, errno: Int32)
    /// The file ended before the length stated in the head was written — it shrank while being sent. Thrown
    /// mid-body, after the head, so it aborts the response rather than mapping to a status.
    case truncated(path: String)
}

/// A file a `@FileResponse` route answers with, opened and resolved against the request.
///
/// Building one does everything that can fail *before* the head goes out: it opens the file, reads its size
/// and modification time, and decides what the request's `Range` asks of it. So a missing file throws inside
/// the route's mapped region and becomes whatever `@ErrorResponse` says, and an unsatisfiable range is a
/// `416` head. What is left for the body is reading bytes that are known to be there.
///
/// ```swift
/// @Get("/media/{id}")
/// @FileResponse
/// @ErrorResponse(WireMVCFileError.self, .notFound)
/// func media(
///     @Path id: String,
///     @Header("Range") range: String?,
///     @Header("If-Range") ifRange: String?
/// ) throws -> WireMVCFile {
///     try WireMVCFile(path: library.path(of: id), contentType: "video/mp4", range: range, ifRange: ifRange)
/// }
/// ```
///
/// The file stays open from here until the body is written, so a file renamed or unlinked in between is
/// still the one sent. The descriptor is closed when the last copy of this value goes — after the body, or
/// when a response is abandoned before it.
///
/// **Validators.** The head states `ETag` and `Last-Modified`, and `If-Range` is evaluated against them.
/// Conditional requests that answer `304` (`If-None-Match`, `If-Modified-Since`) are not evaluated: the
/// validators are stated so a cache or client can use them, and a route that wants `304` checks the request
/// itself before building this.
public struct WireMVCFile: Sendable {
    /// The path the file was opened from, as given.
    public let path: String
    /// The file's media type, seeded as `Content-Type` unless the route names one.
    public let contentType: String
    /// The file's size in bytes, when it was opened.
    public let size: Int64
    /// What the request's `Range` resolved to, after `If-Range`.
    public let range: WireMVCByteRange
    /// The strong entity tag stated in the head: size and modification time, to the nanosecond.
    public let entityTag: String
    /// The modification time as an HTTP-date (RFC 9110 §5.6.7), stated as `Last-Modified`.
    public let lastModified: String
    /// How many bytes are read from the file and written per chunk.
    public let chunkSize: Int

    let descriptor: WireMVCFileDescriptor

    /// Open `path` and resolve the request's `Range` against it.
    ///
    /// - Parameters:
    ///   - path: The file to send. Resolved by the system as given; a route serving files under a root it
    ///     accepts a name for is responsible for confining that name to the root.
    ///   - contentType: The media type to state.
    ///   - range: The request's `Range` field value, or `nil`. Pass it only for `GET` — RFC 9110 §14.2
    ///     defines `Range` for no other method.
    ///   - ifRange: The request's `If-Range` field value, or `nil`. When present and it does not match this
    ///     file — a different or weak entity tag, or a date other than this file's `Last-Modified` — the
    ///     range is ignored and the whole file is sent (§13.1.5).
    ///   - chunkSize: Bytes per read and write. Clamped to at least one.
    /// - Throws: ``WireMVCFileError/notFound(path:)`` when nothing regular is at `path`,
    ///   ``WireMVCFileError/unreadable(path:errno:)`` when it cannot be opened or examined.
    public init(
        path: String,
        contentType: String,
        range: String? = nil,
        ifRange: String? = nil,
        chunkSize: Int = 64 * 1024
    ) throws(WireMVCFileError) {
        let descriptor = try WireMVCFileDescriptor(opening: path)
        let status = try descriptor.status(path: path)
        let entityTag = Self.entityTag(size: status.size, seconds: status.seconds, nanoseconds: status.nanoseconds)
        let lastModified = WireMVCHTTPDate.format(secondsSinceEpoch: status.seconds)
        let rangeApplies = ifRange.map { Self.matches(ifRange: $0, entityTag: entityTag, lastModified: lastModified) }
        self.path = path
        self.contentType = contentType
        self.size = status.size
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.chunkSize = max(1, chunkSize)
        self.descriptor = descriptor
        self.range = rangeApplies ?? true ? WireMVCByteRange.resolve(rangeField: range, size: status.size) : .whole
    }

    /// Open the file a `file:` URL names. See ``init(path:contentType:range:ifRange:chunkSize:)``.
    public init(
        url: URL,
        contentType: String,
        range: String? = nil,
        ifRange: String? = nil,
        chunkSize: Int = 64 * 1024
    ) throws(WireMVCFileError) {
        guard url.isFileURL else { throw .notFound(path: url.absoluteString) }
        try self.init(
            path: url.path(percentEncoded: false),
            contentType: contentType,
            range: range,
            ifRange: ifRange,
            chunkSize: chunkSize
        )
    }

    /// The status and fields this file requires of the head — what ``WireMVCFileProducer`` reports as its
    /// ``WireMVCBodyProducer/head``.
    ///
    /// `200` leaves the status to the route (`nil`); `206` and `416` are stated, because they describe the
    /// bytes. `Content-Length` is always stated, so the body goes out length-delimited rather than chunked.
    public var head: WireMVCBodyHead {
        var fields = HTTPFields()
        fields[.acceptRanges] = "bytes"
        switch range {
        case .whole:
            fields[.eTag] = entityTag
            fields[.lastModified] = lastModified
            fields[.contentLength] = String(size)
            return WireMVCBodyHead(status: nil, headerFields: fields)
        case .part(let first, let last):
            fields[.eTag] = entityTag
            fields[.lastModified] = lastModified
            fields[.contentRange] = "bytes \(first)-\(last)/\(size)"
            fields[.contentLength] = String(last - first + 1)
            return WireMVCBodyHead(status: .partialContent, headerFields: fields)
        case .unsatisfiable:
            fields[.contentRange] = "bytes */\(size)"
            fields[.contentLength] = "0"
            return WireMVCBodyHead(status: .rangeNotSatisfiable, headerFields: fields)
        }
    }

    /// The bytes the body carries, as an offset and a length. Empty for `416` and for an empty file.
    var span: (offset: Int64, length: Int64) {
        switch range {
        case .whole: (0, size)
        case .part(let first, let last): (first, last - first + 1)
        case .unsatisfiable: (0, 0)
        }
    }

    /// Strong, and quoted: size and modification time in hex. The nanoseconds are what make it strong in
    /// practice — a file rewritten within the same second to the same length still changes it on every file
    /// system that records sub-second times.
    static func entityTag(size: Int64, seconds: Int64, nanoseconds: Int64) -> String {
        "\"\(String(size, radix: 16))-\(String(seconds, radix: 16)).\(String(nanoseconds, radix: 16))\""
    }

    /// Whether an `If-Range` value matches this file, so the range applies (RFC 9110 §13.1.5).
    ///
    /// An entity tag matches by **strong** comparison, so a weak tag never does. A date matches only when it
    /// is exactly this file's `Last-Modified`: the RFC's further condition — that the date be strong, at
    /// least a second older than the response — is not checked, which makes this reading the stricter one
    /// only in that a date in another legal HTTP-date form does not match. Not matching costs a whole file,
    /// never a wrong range.
    static func matches(ifRange: String, entityTag: String, lastModified: String) -> Bool {
        let value = ifRange.trimmed
        if value.hasPrefix("\"") { return value == entityTag }
        if value.hasPrefix("W/") { return false }
        return value == lastModified
    }
}

/// The ``WireMVCBodyProducer`` `@FileResponse` resolves against: it streams a ``WireMVCFile``'s span in
/// chunks and terminates the response.
///
/// The generated terminal spells `WireMVCFileProducer(<handler call>)`, as `@HTMLResponse` spells
/// `WireMVCHTMLProducer(…)`. A route never names it.
public struct WireMVCFileProducer: WireMVCBodyProducer {
    public let file: WireMVCFile

    public init(_ file: WireMVCFile) {
        self.file = file
    }

    /// The file's media type — except on a `416`, whose empty body has none.
    public var contentType: String? {
        file.range == .unsatisfiable ? nil : file.contentType
    }

    public var head: WireMVCBodyHead { file.head }

    public consuming func writeBody<W: CallerAsyncWriter & ~Copyable & ~Escapable>(
        into writer: consuming W,
        terminatedBy trailer: HTTPFields?
    ) async throws where W.WriteElement == UInt8, W.FinalElement == HTTPFields? {
        var (offset, remaining) = file.span
        while remaining > 0 {
            let wanted = Int(min(Int64(file.chunkSize), remaining))
            var chunk = try file.descriptor.read(upTo: wanted, at: offset, path: file.path)
            let count = chunk.count
            // The head promised `remaining` more bytes. A file that ends early cannot keep that promise, and
            // finishing would send a response shorter than its `Content-Length` — so the writer is dropped
            // unfinished instead, which the proposal defines as aborting it.
            guard count > 0 else { throw WireMVCFileError.truncated(path: file.path) }
            try await writer.write(buffer: &chunk)
            offset += Int64(count)
            remaining -= Int64(count)
        }
        var end = UniqueArray<UInt8>()
        try await writer.finish(buffer: &end, finalElement: trailer)
    }
}

/// What `fstat` said about an open file: its size, and its modification time since the epoch.
struct WireMVCFileStatus {
    var size: Int64
    var seconds: Int64
    var nanoseconds: Int64
}

/// An open, read-only file descriptor, closed when the last reference goes.
///
/// A class so that ``WireMVCFile`` can be an ordinary copyable value — returned from a handler, captured in
/// a tuple — while the descriptor it holds is closed exactly once. `@unchecked Sendable` because nothing
/// mutates it after `init`, and `pread` takes its offset as an argument, so concurrent reads do not share a
/// file position.
final class WireMVCFileDescriptor: @unchecked Sendable {
    let raw: Int32

    init(opening path: String) throws(WireMVCFileError) {
        var opened: Int32
        repeat {
            opened = unsafe open(path, O_RDONLY | O_CLOEXEC)
        } while opened < 0 && errno == EINTR
        guard opened >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw .notFound(path: path) }
            throw .unreadable(path: path, errno: code)
        }
        raw = opened
    }

    deinit {
        _ = close(raw)
    }

    /// Size and modification time, refusing anything that is not a regular file.
    func status(path: String) throws(WireMVCFileError) -> WireMVCFileStatus {
        var info = stat()
        guard unsafe fstat(raw, &info) == 0 else { throw .unreadable(path: path, errno: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw .notFound(path: path) }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        #else
        let modified = info.st_mtim
        #endif
        return WireMVCFileStatus(
            size: Int64(info.st_size),
            seconds: Int64(modified.tv_sec),
            nanoseconds: Int64(modified.tv_nsec)
        )
    }

    /// Up to `count` bytes at `offset`. Empty only at end of file.
    func read(upTo count: Int, at offset: Int64, path: String) throws(WireMVCFileError) -> UniqueArray<UInt8> {
        var bytes = [UInt8](repeating: 0, count: count)
        var got: Int
        repeat {
            got = bytes.withUnsafeMutableBytes { buffer in
                unsafe pread(raw, buffer.baseAddress, count, off_t(offset))
            }
        } while got < 0 && errno == EINTR
        guard got >= 0 else { throw .unreadable(path: path, errno: errno) }
        return UniqueArray<UInt8>(copying: bytes[0..<got])
    }
}

/// HTTP-date formatting (RFC 9110 §5.6.7, IMF-fixdate), done by hand so the core needs no date formatter.
enum WireMVCHTTPDate {
    private static let days = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// `Sun, 06 Nov 1994 08:49:37 GMT` for a count of seconds since 1970-01-01T00:00:00Z.
    static func format(secondsSinceEpoch seconds: Int64) -> String {
        let (day, second) = seconds.quotientAndRemainder(dividingBy: 86_400)
        let dayNumber = second < 0 ? day - 1 : day
        let secondOfDay = second < 0 ? second + 86_400 : second
        let date = civil(fromDays: dayNumber)
        let weekday = days[Int(((dayNumber % 7) + 7) % 7)]
        return "\(weekday), \(pad(date.day)) \(months[Int(date.month) - 1]) \(date.year) "
            + "\(pad(secondOfDay / 3600)):\(pad(secondOfDay % 3600 / 60)):\(pad(secondOfDay % 60)) GMT"
    }

    /// Howard Hinnant's `civil_from_days`: the proleptic Gregorian date `days` after 1970-01-01.
    struct CivilDate: Equatable {
        var year: Int64
        var month: Int64
        var day: Int64
    }

    static func civil(fromDays days: Int64) -> CivilDate {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return CivilDate(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    private static func pad(_ value: Int64) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
