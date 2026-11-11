import XCTest
@testable import ShelfHead

/// Batch 490 (REVIEW 2026-11-11 N3, D3, D7, A2): pins the Settings quick wins — the export
/// key lists, the search index's coverage and live-state filtering, the avatar names, the
/// cover-cache size sum and the What's New version rule.
///
/// Two tests read Swift source (via `#filePath`) because Swift can't enumerate a type's
/// `static let`s at runtime. This is new for this test target; each skips, rather than
/// fails, when the source folder can't be read.
final class QuickWinsSettingsTests: XCTestCase {

    // MARK: - Source scanning helpers

    /// The app's source folder, next to this test folder.
    private var appSourceFolder: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ShelfHead", isDirectory: true)
    }

    /// The bodies of every `enum <name>` / `extension <name>` block in `source`.
    private func blocks(named name: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(enum|extension)\\s+\(name)\\b[^{]*\\{") else { return [] }
        let ns = source as NSString
        var out: [String] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            let start = match.range.location + match.range.length
            var depth = 1
            var index = start
            while depth > 0, index < ns.length {
                let ch = ns.character(at: index)
                if ch == 123 { depth += 1 }       // {
                else if ch == 125 { depth -= 1 }  // }
                index += 1
            }
            out.append(ns.substring(with: NSRange(location: start, length: max(0, index - start - 1))))
        }
        return out
    }

    /// `static let name = "value"` pairs in `text`.
    private func stringConstants(in text: String) -> [(name: String, value: String)] {
        guard let regex = try? NSRegularExpression(pattern: "static let (\\w+)\\s*=\\s*\"([^\"]+)\"") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), ns.substring(with: $0.range(at: 2)))
        }
    }

    private func swiftSources() throws -> [String] {
        let folder = appSourceFolder
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            throw XCTSkip("App source folder not readable at \(folder.path)")
        }
        var sources: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) { sources.append(text) }
        }
        if sources.isEmpty { throw XCTSkip("No Swift sources found at \(folder.path)") }
        return sources
    }

    // MARK: - D7: every settings key is on exactly one export list

    func testEverySettingsKeyIsExportedOrExcludedExactlyOnce() throws {
        var keys: [String: String] = [:]
        for source in try swiftSources() {
            for block in blocks(named: "SettingsKeys", in: source) {
                for constant in stringConstants(in: block) { keys[constant.name] = constant.value }
            }
        }
        XCTAssertGreaterThan(keys.count, 50, "SettingsKeys scan found too few keys; the scanner is probably broken.")
        let exported = Set(SettingsExport.exportedKeys)
        for (name, value) in keys.sorted(by: { $0.key < $1.key }) {
            let count = (exported.contains(value) ? 1 : 0) + (SettingsExport.excludedKeys.contains(value) ? 1 : 0)
            XCTAssertEqual(count, 1, "SettingsKeys.\(name) (\(value)) must be on exactly one of exportedKeys / excludedKeys.")
        }
    }

    func testExportedKeysHaveNoDuplicates() {
        XCTAssertEqual(SettingsExport.exportedKeys.count, Set(SettingsExport.exportedKeys).count)
    }

    /// Nothing that starts or changes sound may come in on an import.
    func testSoundKeysAreNeverImported() {
        for key in [SettingsKeys.ambientBed, SettingsKeys.ambientLevel, SettingsKeys.deckButtonSounds] {
            XCTAssertTrue(SettingsExport.excludedKeys.contains(key), key)
            XCTAssertFalse(SettingsExport.exportedKeys.contains(key), key)
        }
        XCTAssertTrue(SettingsExport.excludedKeys.contains(WhatsNew.lastSeenVersionKey))
    }

    // MARK: - D7: [String: Bool] round trip (seriesAutoDownload)

    func testSeriesAutoDownloadRoundTrips() throws {
        let suite = "QuickWinsSettingsTests.series"
        let source = try XCTUnwrap(UserDefaults(suiteName: suite))
        source.removePersistentDomain(forName: suite)
        defer { source.removePersistentDomain(forName: suite) }
        source.set(["Discworld": true, "Expanse": false], forKey: SettingsKeys.seriesAutoDownload)

        let file = SettingsExport.snapshot(defaults: source, appVersion: "test")
        XCTAssertEqual(file.settings[SettingsKeys.seriesAutoDownload],
                       .boolDictionary(["Discworld": true, "Expanse": false]))

        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(SettingsExportFile.self, from: data)
        XCTAssertEqual(decoded.settings[SettingsKeys.seriesAutoDownload],
                       .boolDictionary(["Discworld": true, "Expanse": false]))

        let targetSuite = "QuickWinsSettingsTests.seriesTarget"
        let target = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        target.removePersistentDomain(forName: targetSuite)
        defer { target.removePersistentDomain(forName: targetSuite) }
        SettingsExport.apply(decoded, to: target)
        let stored = target.dictionary(forKey: SettingsKeys.seriesAutoDownload) as? [String: Bool]
        XCTAssertEqual(stored, ["Discworld": true, "Expanse": false])
    }

    func testDictionaryWithNonBoolValuesIsNotExportable() {
        XCTAssertNil(SettingsExportValue(any: ["a": 1] as [String: Any]))
        XCTAssertNil(SettingsExportValue(any: ["a": "yes"] as [String: Any]))
        XCTAssertEqual(SettingsExportValue(any: ["a": true] as [String: Any]), .boolDictionary(["a": true]))
    }

    func testSanitizedRulesForNewKeys() {
        XCTAssertNil(SettingsExport.sanitized(.bool(true), forKey: SettingsKeys.seriesAutoDownload))
        XCTAssertEqual(SettingsExport.sanitized(.boolDictionary(["x": true]), forKey: SettingsKeys.seriesAutoDownload),
                       .boolDictionary(["x": true]))
        XCTAssertEqual(SettingsExport.sanitized(.int(1000), forKey: SettingsKeys.targetWPM),
                       .int(NarratorPace.targetRange.upperBound))
        XCTAssertEqual(SettingsExport.sanitized(.int(10), forKey: SettingsKeys.targetWPM),
                       .int(NarratorPace.targetRange.lowerBound))
        XCTAssertEqual(SettingsExport.sanitized(.string("wpm"), forKey: SettingsKeys.speedMode), .string("wpm"))
        XCTAssertNil(SettingsExport.sanitized(.string("turbo"), forKey: SettingsKeys.speedMode))
        XCTAssertNil(SettingsExport.sanitized(.string("yes"), forKey: SettingsKeys.spatialAudioEnabled))
        XCTAssertEqual(SettingsExport.sanitized(.double(9), forKey: "epubReader.fontScale"), .double(2.5))
    }

    // MARK: - N3: every SettingsRow is searchable or deliberately exempt

    /// Rows with no search entry, on purpose. Add a reason with any new one.
    private let unindexedRows: Set<String> = [
        SettingsRow.accentColour,          // covered by "Theme & accent colour" (lands on `theme`)
        SettingsRow.securityLink,          // a link row to Account & Security, which has its own entries
        SettingsRow.featureSleepShake,     // "Shake to reset or extend" on Sleep Timer is the setting; a second "shake" hit breaks the one-page rule
        SettingsRow.featureDeckSkins,      // the Appearance "Deck skin" entry is the setting
        SettingsRow.featureLiveActivities, // the System & Privacy "Live Activities" entry is the setting
        SettingsRow.featureHousehold,      // the Household page entries are the setting
    ]

    func testEverySettingsRowIsIndexedOrExempt() throws {
        let url = appSourceFolder.appendingPathComponent("Views/Settings/SettingsSearchIndex.swift")
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("SettingsSearchIndex.swift not readable at \(url.path)")
        }
        let rows = blocks(named: "SettingsRow", in: source).flatMap { stringConstants(in: $0) }.map(\.value)
        XCTAssertGreaterThan(rows.count, 40, "SettingsRow scan found too few rows; the scanner is probably broken.")
        var allState = SettingsSearchEntry.LiveState()
        allState.savedServerCount = 2
        let indexed = Set(SettingsSearchIndex.entries(includesClassicLockScreen: true, state: allState).compactMap(\.row))
        for row in rows {
            XCTAssertTrue(indexed.contains(row) || unindexedRows.contains(row),
                          "SettingsRow \(row) has no search entry and isn't on the exempt list.")
        }
        for row in unindexedRows {
            XCTAssertFalse(indexed.contains(row), "\(row) is indexed now; take it off the exempt list.")
        }
    }

    // MARK: - N3: live-state conditions

    private func rows(_ state: SettingsSearchEntry.LiveState) -> Set<String> {
        Set(SettingsSearchIndex.entries(includesClassicLockScreen: true, state: state).compactMap(\.row))
    }

    func testUploadNeedsUploadPermission() {
        XCTAssertTrue(rows(.init()).contains(SettingsRow.upload))
        XCTAssertFalse(rows(.init(canUpload: false)).contains(SettingsRow.upload))
    }

    func testLibraryDoctorNeedsUpdatePermission() {
        XCTAssertTrue(rows(.init()).contains(SettingsRow.libraryDoctor))
        XCTAssertFalse(rows(.init(canUpdateLibrary: false)).contains(SettingsRow.libraryDoctor))
    }

    func testHouseholdSharingNeedsAHousehold() {
        XCTAssertTrue(rows(.init()).contains(SettingsRow.householdSharing))
        XCTAssertFalse(rows(.init(isInHousehold: false)).contains(SettingsRow.householdSharing))
        // The Household page itself is always reachable.
        XCTAssertTrue(rows(.init(isInHousehold: false)).contains(SettingsRow.household))
    }

    func testTranscriptRowsNeedSupportedOS() {
        let gated = [SettingsRow.transcribeWhileCharging, SettingsRow.recapSpokenLinks, SettingsRow.recapAutoPlay,
                     SettingsRow.transcriptLanguage, SettingsRow.transcriptTranslation]
        let supported = rows(.init())
        let unsupported = rows(.init(transcriptsSupported: false))
        for row in gated {
            XCTAssertTrue(supported.contains(row), row)
            XCTAssertFalse(unsupported.contains(row), row)
        }
    }

    func testOldSavedServerCountOverloadMatchesDefaultState() {
        XCTAssertEqual(SettingsSearchIndex.results(for: "upload").map(\.title),
                       SettingsSearchIndex.results(for: "upload", state: .init()).map(\.title))
    }

    func testNewSearchEntriesLand() {
        XCTAssertTrue(SettingsSearchIndex.results(for: "charger").contains { $0.row == SettingsRow.chargingOnly })
        XCTAssertTrue(SettingsSearchIndex.results(for: "translate").contains { $0.row == SettingsRow.transcriptTranslation })
        XCTAssertTrue(SettingsSearchIndex.results(for: "x-ray").contains { $0.page == .featuresTips })
        XCTAssertTrue(SettingsSearchIndex.results(for: "cover cache").contains { $0.row == SettingsRow.imageCache })
    }

    // MARK: - A2: every avatar picture and colour has a spoken name

    func testKidAvatarNamesCoverEverySymbolAndColour() {
        for symbol in KidAvatar.symbols {
            XCTAssertNotNil(KidAvatar.symbolNames[symbol], "No name for \(symbol)")
        }
        XCTAssertEqual(KidAvatar.colorNames.count, KidAvatar.colorHexes.count)
    }

    func testHouseholdAvatarNamesCoverEverySymbolAndColour() {
        for symbol in HouseholdAvatar.symbols {
            XCTAssertNotNil(HouseholdAvatar.symbolNames[symbol], "No name for \(symbol)")
        }
        XCTAssertEqual(HouseholdAvatar.colorNames.count, HouseholdAvatar.colorCount)
    }

    // MARK: - D3: cover cache size

    func testCoverCacheSizeSumsReadableSizes() {
        XCTAssertEqual(DiskCoverCache.totalBytes(ofFileSizes: []), 0)
        XCTAssertEqual(DiskCoverCache.totalBytes(ofFileSizes: [100, nil, 50]), 150)
        XCTAssertEqual(DiskCoverCache.totalBytes(ofFileSizes: [-5, 10]), 10)
    }

    // MARK: - N3: What's New once per version

    func testWhatsNewVersionRule() {
        XCTAssertFalse(WhatsNew.shouldPresent(current: "7.5", lastSeen: nil), "fresh install")
        XCTAssertFalse(WhatsNew.shouldPresent(current: "7.5", lastSeen: "7.5"), "same version")
        XCTAssertTrue(WhatsNew.shouldPresent(current: "7.6", lastSeen: "7.5"), "update")
        XCTAssertTrue(WhatsNew.shouldPresent(current: "7.10", lastSeen: "7.9"), "numeric, not lexical")
        XCTAssertFalse(WhatsNew.shouldPresent(current: "7.4", lastSeen: "7.5"), "downgrade")
        XCTAssertFalse(WhatsNew.shouldPresent(current: "", lastSeen: "7.5"), "no bundle version")
    }
}
