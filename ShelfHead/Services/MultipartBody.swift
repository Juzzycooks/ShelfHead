import Foundation

/// Batch 444: a pure multipart/form-data builder for `POST /api/upload`. It never holds a file in
/// memory: the body is written to a temp file in 1 MB chunks (`write(to:)`), and that file is
/// handed to `URLSession.upload(for:fromFile:delegate:)`, so a 500 MB audiobook costs 1 MB of RAM.
nonisolated struct MultipartBody: Sendable {

    nonisolated enum Source: Sendable, Equatable {
        case text(String)
        case file(URL)
    }

    nonisolated struct Part: Sendable, Equatable {
        let name: String
        /// Set for file parts; the server stores the upload under this name.
        let filename: String?
        let contentType: String?
        let source: Source

        static func text(_ name: String, _ value: String) -> Part {
            Part(name: name, filename: nil, contentType: nil, source: .text(value))
        }

        static func file(_ name: String, fileURL: URL, filename: String, contentType: String? = nil) -> Part {
            Part(name: name, filename: filename,
                 contentType: contentType ?? MultipartBody.mimeType(forFilename: filename),
                 source: .file(fileURL))
        }
    }

    let boundary: String
    let parts: [Part]

    init(parts: [Part], boundary: String = MultipartBody.makeBoundary()) {
        self.parts = parts
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    // MARK: Pure pieces

    static func makeBoundary() -> String {
        "ShelfHead-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// Escapes a value placed inside a quoted `Content-Disposition` parameter, the way the HTML
    /// form-data spec does: `"` -> `%22`, CR -> `%0D`, LF -> `%0A`. A backslash is left alone
    /// (browsers do the same; escaping it would corrupt Windows-style names the server never sees).
    static func escapeQuoted(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "%22"
            case "\r": out += "%0D"
            case "\n": out += "%0A"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The bytes before a part's content: `--boundary`, its headers and the blank line.
    func header(for part: Part) -> Data {
        var s = "--\(boundary)\r\n"
        s += "Content-Disposition: form-data; name=\"\(Self.escapeQuoted(part.name))\""
        if let filename = part.filename { s += "; filename=\"\(Self.escapeQuoted(filename))\"" }
        s += "\r\n"
        if let type = part.contentType { s += "Content-Type: \(type)\r\n" }
        s += "\r\n"
        return Data(s.utf8)
    }

    var closing: Data { Data("--\(boundary)--\r\n".utf8) }

    /// Exact body length for the given on-disk file sizes (`sizes[url]`), so the length is known
    /// before writing. Missing sizes count as 0.
    func contentLength(fileSizes: [URL: Int64]) -> Int64 {
        var total: Int64 = 0
        for part in parts {
            total += Int64(header(for: part).count)
            switch part.source {
            case .text(let value): total += Int64(value.utf8.count)
            case .file(let url): total += fileSizes[url] ?? 0
            }
            total += 2 // trailing CRLF
        }
        return total + Int64(closing.count)
    }

    static func mimeType(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "m4b", "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "oga", "opus": return "audio/ogg"
        case "wav": return "audio/wav"
        case "wma": return "audio/x-ms-wma"
        case "epub": return "application/epub+zip"
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "cue": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    // MARK: I/O

    /// Writes the whole body to `destination` (replacing it) and returns its length in bytes.
    /// Throws `CancellationError` between chunks when the surrounding task is cancelled.
    @discardableResult
    func write(to destination: URL) throws -> Int64 {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        fm.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var written: Int64 = 0
        func emit(_ data: Data) throws { try out.write(contentsOf: data); written += Int64(data.count) }
        let crlf = Data("\r\n".utf8)

        for part in parts {
            try emit(header(for: part))
            switch part.source {
            case .text(let value):
                try emit(Data(value.utf8))
            case .file(let url):
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while true {
                    try Task.checkCancellation()
                    guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
                    try emit(chunk)
                }
            }
            try emit(crlf)
        }
        try emit(closing)
        return written
    }
}

/// Batch 444: the form `POST /api/upload` expects. Field names confirmed against the server source
/// (`MiscController.handleUpload`, master, 28 Oct 2026) and a real upload to the local test server:
/// `title`, `library`, `folder` required; `author` and `series` optional; every file is its own part
/// (this app names them `0`, `1`, ...); the server reads the part's filename, sanitises it and
/// writes it to `<folder>/<author>/<series>/<title>/`.
nonisolated struct UploadForm: Sendable, Equatable {
    struct File: Sendable, Equatable {
        let url: URL
        let filename: String
    }

    var title: String
    var author: String
    var series: String
    var libraryId: String
    var folderId: String
    var files: [File]

    /// Multipart parts in the order the server documents them. Blank author/series are omitted
    /// (the server would skip an empty path segment anyway).
    var parts: [MultipartBody.Part] {
        var out: [MultipartBody.Part] = [
            .text("title", title.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { out.append(.text("author", a)) }
        let s = series.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(.text("series", s)) }
        out.append(.text("library", libraryId))
        out.append(.text("folder", folderId))
        let names = Self.uniqueFilenames(files.map(\.filename))
        for (index, file) in files.enumerated() {
            out.append(.file("\(index)", fileURL: file.url, filename: names[index]))
        }
        return out
    }

    /// Same-named files would overwrite each other on the server, so later duplicates become
    /// `name 2.ext`, `name 3.ext`. Comparison is case-insensitive (the server's disk may be).
    static func uniqueFilenames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { name in
            var candidate = name
            var n = 1
            let ns = name as NSString
            let ext = ns.pathExtension
            let base = ns.deletingPathExtension
            while used.contains(candidate.lowercased()) {
                n += 1
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !libraryId.isEmpty && !folderId.isEmpty && !files.isEmpty
    }
}
