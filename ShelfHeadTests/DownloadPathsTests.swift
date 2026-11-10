import XCTest
@testable import ShelfHead

/// Pins SEC-1 (REVIEW_2026-08-12.md): `sanitizedPathComponent` previously let `.` and
/// `..` survive unchanged, so a hostile server's `LibraryItem.id` of `".."` resolved
/// `downloadDirectory(for:)` to `downloadsRoot()`'s own *parent* directory —
/// `removeDownload(itemId: "..")` calling `fileManager.removeItem(at:)` on that would
/// have deleted every account's downloads. `"."` resolved to the scope root itself,
/// wiping the current account's entire download folder plus its `.paused` resume state.
/// `@MainActor`: the `DownloadManager` members exercised here are main-actor-isolated.
/// This test target predates that annotation and had never been rebuilt against it.
@MainActor
final class DownloadPathsTests: XCTestCase {

    private var manager: DownloadManager { DownloadManager.shared }

    /// True if `url`'s standardized path is `root` itself or strictly inside it — the
    /// property every sanitized path must have, regardless of what a hostile id
    /// contained.
    private func isContained(_ url: URL, within root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.path
        let resolved = url.standardizedFileURL.path
        return resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/")
    }

    // MARK: - The exact traversal payloads

    func testDotDotDoesNotEscapeDownloadsRoot() {
        let dir = manager.downloadDirectory(for: "..")
        XCTAssertTrue(isContained(dir, within: manager.downloadsRoot()),
                      "\"..\" resolved to \(dir.path), outside \(manager.downloadsRoot().path)")
    }

    func testSingleDotDoesNotResolveToTheRootItself() {
        // "." must not resolve to `downloadsRoot()` exactly — `removeDownload` would
        // then delete the whole scope root, not just one item's subdirectory.
        let dir = manager.downloadDirectory(for: ".")
        XCTAssertNotEqual(dir.standardizedFileURL.path, manager.downloadsRoot().standardizedFileURL.path)
        XCTAssertTrue(isContained(dir, within: manager.downloadsRoot()))
    }

    func testDoubleDotDoubleDotDoesNotEscape() {
        let dir = manager.downloadDirectory(for: "../..")
        XCTAssertTrue(isContained(dir, within: manager.downloadsRoot()))
    }

    func testEmbeddedSlashDoesNotCreateExtraPathSegments() {
        // "a/b" must collapse to one path component, not be readable as a subdirectory
        // traversal into "a"'s folder.
        let dir = manager.downloadDirectory(for: "a/b")
        XCTAssertEqual(dir.deletingLastPathComponent().standardizedFileURL.path,
                       manager.downloadsRoot().standardizedFileURL.path,
                       "\"a/b\" must sanitize to a single path component directly under downloadsRoot()")
        XCTAssertTrue(isContained(dir, within: manager.downloadsRoot()))
    }

    func testPercentEncodedDotDotIsNotDoubleDecodedIntoATraversal() {
        // "%2e%2e" is the literal 7 characters '%','2','e','%','2','e' as a *value*,
        // not something that should ever be interpreted as ".." after encoding — it
        // must still resolve safely regardless.
        let dir = manager.downloadDirectory(for: "%2e%2e")
        XCTAssertTrue(isContained(dir, within: manager.downloadsRoot()))
    }

    func testEmptyIdDoesNotResolveToTheRootItself() {
        let dir = manager.downloadDirectory(for: "")
        XCTAssertNotEqual(dir.standardizedFileURL.path, manager.downloadsRoot().standardizedFileURL.path)
        XCTAssertTrue(isContained(dir, within: manager.downloadsRoot()))
    }

    func testVeryLongIdIsHandledWithoutCrashing() {
        let longId = String(repeating: "a", count: 300)
        let dir = manager.downloadDirectory(for: longId)
        XCTAssertTrue(isContained(dir, within: manager.downloadsRoot()))
    }

    // MARK: - Normal ids are unaffected (no behavior change for the common case)

    func testOrdinaryUUIDStyleIdPassesThroughUnchanged() {
        let id = "3f6a1b2c-4d5e-4f60-8a9b-0c1d2e3f4a5b"
        XCTAssertEqual(manager.sanitizedPathComponent(id), id)
    }

    // MARK: - pausedResumeFile agrees with downloadDirectory on sanitization

    func testPausedResumeFileSanitizesTheSameWayAsDownloadDirectory() {
        for itemId in ["..", ".", "../..", "a/b", ""] {
            let resumeFile = manager.pausedResumeFile(key: "\(itemId)|0")
            let pausedResumeDirParent = resumeFile.deletingLastPathComponent()
            XCTAssertTrue(
                isContained(resumeFile, within: manager.downloadsRoot()),
                "pausedResumeFile for id \(itemId.debugDescription) escaped downloadsRoot(): \(resumeFile.path)"
            )
            // Both helpers should agree the resume file lives under `.paused`.
            XCTAssertEqual(pausedResumeDirParent.lastPathComponent, ".paused")
        }
    }

    func testPausedResumeFileNameEmbedsTheSanitizedItemIdAndTrackIndex() {
        let id = "3f6a1b2c-4d5e-4f60-8a9b-0c1d2e3f4a5b"
        let file = manager.pausedResumeFile(key: "\(id)|3")
        XCTAssertEqual(file.lastPathComponent, "\(id)__3.resume")
    }

    // MARK: - DownloadPaths, directly (§8 decomposition, REVIEW_2026-08-12.md)
    //
    // `DownloadManager.sanitizedPathComponent`/`scopeKey` now forward to `DownloadPaths`
    // — these guard that the delegation actually happened (not silently reverted) and
    // exercise the pure type directly, independent of `DownloadManager.shared`/
    // `FileManager`.

    func testDownloadManagerSanitizationMatchesDownloadPathsDirectly() {
        for itemId in ["..", ".", "../..", "a/b", "", "%2e%2e", "3f6a1b2c-4d5e-4f60-8a9b-0c1d2e3f4a5b"] {
            XCTAssertEqual(manager.sanitizedPathComponent(itemId), DownloadPaths.sanitizedPathComponent(itemId))
        }
    }

    func testDownloadPathsSanitizedPathComponentRejectsDotAndDotDot() {
        XCTAssertNotEqual(DownloadPaths.sanitizedPathComponent("."), ".")
        XCTAssertNotEqual(DownloadPaths.sanitizedPathComponent(".."), "..")
        XCTAssertFalse(DownloadPaths.sanitizedPathComponent("..").isEmpty)
    }

    func testDownloadPathsScopeKeyIsStableAndFilesystemSafe() {
        let key = DownloadPaths.scopeKey(serverURL: "https://abs.example.com", accountId: "user-1")
        XCTAssertFalse(key.contains("/"))
        XCTAssertFalse(key.contains("+"))
        XCTAssertFalse(key.contains("="))
        // Deterministic — the same input always produces the same scope folder.
        XCTAssertEqual(key, DownloadPaths.scopeKey(serverURL: "https://abs.example.com", accountId: "user-1"))
        // Different accounts on the same server must not collide.
        XCTAssertNotEqual(key, DownloadPaths.scopeKey(serverURL: "https://abs.example.com", accountId: "user-2"))
    }
}
