//
//  HTTPRange.swift
//  Bluebox
//
//  Range requests for the localhost stream server. Written for Bluebox from
//  RFC 9110 §14 (Range, Content-Range, 206 and 416 responses).
//

import Foundation

/// What to send for one request's Range header.
public enum HTTPRangeResult: Sendable, Equatable {
    /// No (usable) Range header: 200 with the whole file.
    case whole
    /// 206 with these bytes (inclusive bounds, as Content-Range writes them).
    case partial(ClosedRange<Int64>)
    /// 416: the range starts past the end of the file.
    case unsatisfiable

    /// Parses a Range header value against a file of `length` bytes.
    ///
    /// Supports `bytes=a-b`, `bytes=a-` and suffix ranges `bytes=-n`. Players
    /// only ever ask for one range; when several are listed, the first is
    /// served (allowed: a server may ignore Range or answer a subset).
    /// A header that doesn't parse is ignored, per RFC 9110.
    public static func resolve(_ header: String?, length: Int64) -> HTTPRangeResult {
        guard let header else { return .whole }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .whole }
        let spec = trimmed.dropFirst(6).split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .whole }
        let first = parts[0].trimmingCharacters(in: .whitespaces)
        let last = parts[1].trimmingCharacters(in: .whitespaces)

        if first.isEmpty {
            // Suffix: the last n bytes.
            guard let n = Int64(last), n >= 0 else { return .whole }
            guard n > 0, length > 0 else { return .unsatisfiable }
            return .partial(max(0, length - n)...(length - 1))
        }
        guard let start = Int64(first), start >= 0 else { return .whole }
        guard start < length else { return .unsatisfiable }
        if last.isEmpty { return .partial(start...(length - 1)) }
        guard let end = Int64(last), end >= start else { return .whole }
        return .partial(start...min(end, length - 1))
    }
}

/// The parts of an HTTP/1.1 request the stream server uses.
struct HTTPRequestHead: Sendable, Equatable {
    var method: String
    var path: String
    var headers: [String: String]  // lowercased names

    var range: String? { headers["range"] }
    var wantsClose: Bool { headers["connection"]?.lowercased().contains("close") ?? false }

    /// Parses the request line and headers (everything before the blank line).
    init?(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        method = String(requestLine[0]).uppercased()
        path = String(requestLine[1])
        headers = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
    }
}

enum MediaContentType {
    /// The Content-Type for a video file name, by extension.
    static func forFile(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "avi": "video/x-msvideo"
        case "mov": "video/quicktime"
        case "ts", "m2ts": "video/mp2t"
        case "mpg", "mpeg": "video/mpeg"
        case "wmv": "video/x-ms-wmv"
        case "flv": "video/x-flv"
        case "ogv": "video/ogg"
        default: "application/octet-stream"
        }
    }
}
