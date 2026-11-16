// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

// The `Range` half of `@FileResponse`: what a request's `Range` field asks of a representation, decided
// before the head goes out. Separate from `FileResponses.swift` because it is pure — no file, no I/O — and is
// the part a reader checking RFC 9110 conformance wants to read alone.

/// What a request's `Range` field asks of a representation `size` bytes long (RFC 9110 §14.1.2).
public enum WireMVCByteRange: Equatable, Sendable {
    /// No range applies: the field is absent, names another unit, is malformed, or asks for several
    /// ranges. Answered `200` with the whole representation.
    case whole
    /// One satisfiable range, both ends inclusive and within the representation. Answered `206`.
    case part(first: Int64, last: Int64)
    /// A well-formed range the representation cannot satisfy. Answered `416`.
    case unsatisfiable

    /// Resolve a `Range` field value against a representation of `size` bytes.
    ///
    /// The cases RFC 9110 leaves to the server are decided as follows, each the conservative reading:
    ///
    /// - **A malformed field is ignored**, not refused (§14.2: a server "MAY ignore" `Range`). That covers
    ///   an unknown unit, a non-digit position, and `last-pos` below `first-pos`, which §14.1.1 calls
    ///   invalid rather than unsatisfiable.
    /// - **Several ranges are ignored** and the whole representation is sent. A `multipart/byteranges`
    ///   response is a different body, and no client WireMVC expects needs one.
    /// - `last-pos` past the end is clamped to it, and a suffix longer than the representation is the
    ///   whole of it, as a `206` (§14.1.2).
    /// - `bytes=-0`, a first position at or past the end, and any range of an empty representation are
    ///   unsatisfiable.
    ///
    /// The unit is matched case-insensitively and optional whitespace around the list is allowed, as the
    /// grammar allows.
    public static func resolve(rangeField: String?, size: Int64) -> WireMVCByteRange {
        guard let rangeField else { return .whole }
        guard let equals = rangeField.firstIndex(of: "=") else { return .whole }
        let unit = rangeField[..<equals].trimmed
        guard unit.lowercased() == "bytes" else { return .whole }
        let specs = rangeField[rangeField.index(after: equals)...]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(\.trimmed)
            // The list rule permits empty elements (`bytes=0-1,`); they carry nothing.
            .filter { !$0.isEmpty }
        guard specs.count == 1, let spec = specs.first, let dash = spec.firstIndex(of: "-") else { return .whole }
        let firstText = spec[..<dash]
        let lastText = spec[spec.index(after: dash)...]
        return firstText.isEmpty
            ? suffix(lastText, size: size)
            : range(from: firstText, through: lastText, size: size)
    }

    /// `suffix-range`: the final `n` bytes.
    private static func suffix(_ lengthText: Substring, size: Int64) -> WireMVCByteRange {
        guard let length = position(lengthText) else { return .whole }
        guard length > 0, size > 0 else { return .unsatisfiable }
        return .part(first: size - min(length, size), last: size - 1)
    }

    /// `int-range`: from `first-pos`, through `last-pos` when one is given.
    private static func range(from firstText: Substring, through lastText: Substring, size: Int64) -> WireMVCByteRange {
        guard let first = position(firstText) else { return .whole }
        var last = size - 1
        if !lastText.isEmpty {
            guard let parsed = position(lastText), parsed >= first else { return .whole }
            last = min(parsed, size - 1)
        }
        guard first < size else { return .unsatisfiable }
        return .part(first: first, last: last)
    }

    /// A position: one or more ASCII digits and nothing else. Saturates at `Int64.max` rather than failing,
    /// because a position too large to represent is past the end of any file, which is what it should mean.
    private static func position(_ text: Substring) -> Int64? {
        guard !text.isEmpty else { return nil }
        var value: Int64 = 0
        for byte in text.utf8 {
            guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
            let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
            let (added, overflowB) = shifted.addingReportingOverflow(Int64(byte - UInt8(ascii: "0")))
            if overflowA || overflowB { value = .max } else { value = added }
        }
        return value
    }
}

extension StringProtocol {
    /// Without leading or trailing spaces and tabs — HTTP's optional whitespace, not Unicode's.
    var trimmed: Substring {
        let view = Substring(self)
        let isOWS: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        guard let start = view.firstIndex(where: { !isOWS($0) }) else { return view[view.endIndex...] }
        let end = view.lastIndex(where: { !isOWS($0) }) ?? start
        return view[start...end]
    }
}
