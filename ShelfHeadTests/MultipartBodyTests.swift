import XCTest
@testable import ShelfHead

/// Batch 444: the multipart body and upload form for `POST /api/upload`.
final class MultipartBodyTests: XCTestCase {

    private func tempFile(_ bytes: Data, name: String = "a.m4b") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testEscapeQuotedHandlesQuotesAndLineBreaks() {
        XCTAssertEqual(MultipartBody.escapeQuoted("a\"b"), "a%22b")
        XCTAssertEqual(MultipartBody.escapeQuoted("a\r\nb"), "a%0D%0Ab")
        XCTAssertEqual(MultipartBody.escapeQuoted("Café – 本.m4b"), "Café – 本.m4b")
    }

    func testHeaderForTextAndFileParts() {
        let body = MultipartBody(parts: [], boundary: "B")
        let text = String(decoding: body.header(for: .text("title", "x")), as: UTF8.self)
        XCTAssertEqual(text, "--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\n")
        let file = MultipartBody.Part.file("0", fileURL: URL(fileURLWithPath: "/tmp/a"), filename: "My \"Book\".m4b")
        let header = String(decoding: body.header(for: file), as: UTF8.self)
        XCTAssertTrue(header.contains("name=\"0\"; filename=\"My %22Book%22.m4b\"\r\n"))
        XCTAssertTrue(header.contains("Content-Type: audio/mp4\r\n\r\n"))
    }

    func testWrittenBodyMatchesExpectedBytesAndLength() throws {
        let payload = Data((0..<3000).map { UInt8($0 % 251) })
        let file = try tempFile(payload)
        let body = MultipartBody(parts: [.text("title", "T"), .file("0", fileURL: file, filename: "a.m4b")], boundary: "B")
        let out = file.deletingLastPathComponent().appendingPathComponent("body")
        let written = try body.write(to: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(Int64(data.count), written)
        XCTAssertEqual(written, body.contentLength(fileSizes: [file: Int64(payload.count)]))
        var expected = Data("--B\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nT\r\n".utf8)
        expected.append(Data("--B\r\nContent-Disposition: form-data; name=\"0\"; filename=\"a.m4b\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        expected.append(payload)
        expected.append(Data("\r\n--B--\r\n".utf8))
        XCTAssertEqual(data, expected)
    }

    func testLargeFileStreamsAcrossChunks() throws {
        let payload = Data(repeating: 7, count: 2_500_000)   // > two 1 MB chunks
        let file = try tempFile(payload)
        let body = MultipartBody(parts: [.file("0", fileURL: file, filename: "a.m4b")], boundary: "B")
        let out = file.deletingLastPathComponent().appendingPathComponent("body")
        let written = try body.write(to: out)
        XCTAssertEqual(written, body.contentLength(fileSizes: [file: Int64(payload.count)]))
    }

    func testContentTypeCarriesBoundaryAndBoundariesDiffer() {
        let a = MultipartBody(parts: []), b = MultipartBody(parts: [])
        XCTAssertEqual(a.contentType, "multipart/form-data; boundary=\(a.boundary)")
        XCTAssertNotEqual(a.boundary, b.boundary)
    }

    func testMimeTypes() {
        XCTAssertEqual(MultipartBody.mimeType(forFilename: "x.M4B"), "audio/mp4")
        XCTAssertEqual(MultipartBody.mimeType(forFilename: "x.mp3"), "audio/mpeg")
        XCTAssertEqual(MultipartBody.mimeType(forFilename: "x.epub"), "application/epub+zip")
        XCTAssertEqual(MultipartBody.mimeType(forFilename: "x.unknown"), "application/octet-stream")
    }

    func testUploadFormPartOrderAndOmittedBlanks() {
        let form = UploadForm(title: " Dune ", author: "Frank Herbert", series: "  ", libraryId: "L", folderId: "F",
                              files: [.init(url: URL(fileURLWithPath: "/a.m4b"), filename: "a.m4b"),
                                      .init(url: URL(fileURLWithPath: "/b.m4b"), filename: "b.m4b")])
        let names = form.parts.map(\.name)
        XCTAssertEqual(names, ["title", "author", "library", "folder", "0", "1"])
        XCTAssertEqual(form.parts[0].source, .text("Dune"))
        XCTAssertTrue(form.isValid)
    }

    func testUploadFormInvalidWithoutTitleFolderOrFiles() {
        var form = UploadForm(title: "", author: "", series: "", libraryId: "L", folderId: "F",
                              files: [.init(url: URL(fileURLWithPath: "/a"), filename: "a")])
        XCTAssertFalse(form.isValid)
        form.title = "T"; form.folderId = ""
        XCTAssertFalse(form.isValid)
        form.folderId = "F"; form.files = []
        XCTAssertFalse(form.isValid)
    }

    func testUniqueFilenames() {
        XCTAssertEqual(UploadForm.uniqueFilenames(["a.mp3", "A.mp3", "b.mp3", "a.mp3"]),
                       ["a.mp3", "A 2.mp3", "b.mp3", "a 3.mp3"])
        XCTAssertEqual(UploadForm.uniqueFilenames(["a.mp3", "a.mp3", "a 2.mp3"]),
                       ["a.mp3", "a 2.mp3", "a 2 2.mp3"])
        XCTAssertEqual(UploadForm.uniqueFilenames(["x", "x"]), ["x", "x 2"])
    }
}
