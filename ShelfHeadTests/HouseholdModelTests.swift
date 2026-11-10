import XCTest
import CloudKit
@testable import ShelfHead

/// Batch 453: Household pure layer: server fingerprint, CKRecord mapping for every record type, and the
/// newest-wins merge rule.
final class HouseholdModelTests: XCTestCase {
    private let zone = CKRecordZone.ID(zoneName: HouseholdRecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Fingerprint

    func testFingerprintIgnoresSchemeCaseSlashAndDefaultPort() {
        let variants = ["https://Books.Example.com", "http://books.example.com/", "books.example.com",
                        "https://books.example.com:443/", "http://BOOKS.example.com:80", "  https://books.example.com  "]
        let expected = ServerFingerprint.fingerprint(forServerURL: "https://books.example.com")
        XCTAssertEqual(expected.count, 16)
        for variant in variants {
            XCTAssertEqual(ServerFingerprint.fingerprint(forServerURL: variant), expected, variant)
        }
    }

    func testFingerprintKeepsNonDefaultPortAndDistinguishesHosts() {
        let base = ServerFingerprint.fingerprint(forServerURL: "https://books.example.com")
        XCTAssertNotEqual(ServerFingerprint.fingerprint(forServerURL: "https://books.example.com:13378"), base)
        XCTAssertNotEqual(ServerFingerprint.fingerprint(forServerURL: "https://other.example.com"), base)
        XCTAssertEqual(ServerFingerprint.normalizedHost("http://Abs.local:13378/audiobookshelf/"), "abs.local:13378")
    }

    func testFingerprintOfEmptyIsEmpty() {
        XCTAssertEqual(ServerFingerprint.fingerprint(forServerURL: "  "), "")
    }

    // MARK: Ids

    func testMemberIdAndClubId() {
        XCTAssertEqual(HouseholdMember.makeId(userRecordName: "_abc123"), "member-abc123")
        XCTAssertEqual(HouseholdClub.makeId(serverFingerprint: "ff", libraryItemId: "li_1", title: "T", author: "A"), "club-ff-li_1")
        let byName = HouseholdClub.makeId(serverFingerprint: "ff", libraryItemId: nil, title: "Dune", author: "Herbert")
        XCTAssertEqual(byName, HouseholdClub.makeId(serverFingerprint: "aa", libraryItemId: nil, title: "DUNE", author: "herbert"))
        XCTAssertTrue(byName.hasPrefix("club-t-"))
    }

    // MARK: Mapper round trips

    private func roundTrip(_ item: HouseholdRecord, file: StaticString = #filePath, line: UInt = #line) {
        let record = HouseholdRecordMapper.ckRecord(for: item, zoneID: zone)
        XCTAssertEqual(record.recordType, HouseholdRecordMapper.recordType(for: item), file: file, line: line)
        XCTAssertEqual(record.recordID.recordName, item.recordName, file: file, line: line)
        XCTAssertEqual(record.recordID.zoneID, zone, file: file, line: line)
        XCTAssertEqual(HouseholdRecordMapper.item(from: record), item, file: file, line: line)
    }

    func testMemberRoundTrip() {
        roundTrip(.member(HouseholdMember(id: "member-1", displayName: "Sam", avatarSymbol: "book.fill",
                                          avatarColorIndex: 3, serverFingerprint: "abcd", updatedAt: t0)))
    }

    func testNowListeningRoundTrip() {
        let n = HouseholdNowListening(memberId: "member-1", libraryItemId: "li_9", serverFingerprint: "abcd",
                                      title: "Dune", author: "Frank Herbert", progress: 0.42, updatedAt: t0)
        roundTrip(.nowListening(n))
        XCTAssertEqual(HouseholdRecord.nowListening(n).recordName, "nl-member-1")
    }

    func testRecommendationRoundTrip() {
        roundTrip(.recommendation(HouseholdRecommendation(id: "rec-1", fromMemberId: "member-1",
                                                          toMemberIds: ["member-2", "member-3"], libraryItemId: "li_2",
                                                          serverFingerprint: "abcd", title: "Emma", author: "Austen",
                                                          note: "You'll love it", createdAt: t0)))
    }

    func testClubRoundTripWithAndWithoutGoal() {
        roundTrip(.club(HouseholdClub(id: "club-abcd-li_2", libraryItemId: "li_2", title: "Emma", author: "Austen",
                                      serverFingerprint: "abcd", goalText: "Chapter 12 by Friday", goalSeconds: 5400,
                                      goalDate: t0.addingTimeInterval(86_400), createdBy: "member-1", updatedAt: t0)))
        roundTrip(.club(HouseholdClub(id: "club-t-1", libraryItemId: nil, title: "Emma", author: "",
                                      serverFingerprint: "", goalText: nil, goalSeconds: nil, goalDate: nil,
                                      createdBy: "member-1", updatedAt: t0)))
    }

    func testClubClearsGoalOnUpdate() {
        var club = HouseholdClub(id: "club-1", libraryItemId: nil, title: "T", author: "A", serverFingerprint: "",
                                 goalText: "Soon", goalSeconds: 10, goalDate: t0, createdBy: "m", updatedAt: t0)
        let record = HouseholdRecordMapper.ckRecord(for: .club(club), zoneID: zone)
        club.goalText = nil; club.goalSeconds = nil; club.goalDate = nil
        let updated = HouseholdRecordMapper.ckRecord(for: .club(club), zoneID: zone, base: record)
        XCTAssertNil(updated[HouseholdRecordMapper.Key.goalText])
        XCTAssertEqual(HouseholdRecordMapper.item(from: updated), .club(club))
    }

    func testClubPostRoundTrip() {
        roundTrip(.clubPost(HouseholdClubPost(id: "post-1", clubId: "club-1", memberId: "member-2",
                                              positionSeconds: 1234.5, text: "No spoilers!", createdAt: t0)))
    }

    func testForeignOrIncompleteRecordsAreSkipped() {
        let share = CKRecord(recordType: "cloudkit.share", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        XCTAssertNil(HouseholdRecordMapper.item(from: share))
        let partial = CKRecord(recordType: HouseholdRecordMapper.RecordType.member,
                               recordID: CKRecord.ID(recordName: "member-1", zoneID: zone))
        XCTAssertNil(HouseholdRecordMapper.item(from: partial))
    }

    func testSystemFieldsRoundTripKeepsRecordId() {
        let record = CKRecord(recordType: HouseholdRecordMapper.RecordType.member,
                              recordID: CKRecord.ID(recordName: "member-1", zoneID: zone))
        let data = HouseholdRecordMapper.encodeSystemFields(of: record)
        XCTAssertEqual(HouseholdRecordMapper.record(fromSystemFields: data)?.recordID, record.recordID)
    }

    // MARK: Merge

    private func member(_ name: String, at date: Date) -> HouseholdRecord {
        .member(HouseholdMember(id: "member-1", displayName: name, avatarSymbol: "book.fill", avatarColorIndex: 0,
                                serverFingerprint: "", updatedAt: date))
    }

    func testNewestStampWins() {
        var snapshot = HouseholdSnapshot()
        XCTAssertTrue(snapshot.apply(member("Old", at: t0)))
        XCTAssertTrue(snapshot.apply(member("New", at: t0.addingTimeInterval(10))))
        XCTAssertFalse(snapshot.apply(member("Stale", at: t0.addingTimeInterval(5))))
        XCTAssertEqual(snapshot.members["member-1"]?.displayName, "New")
    }

    func testEqualStampKeepsExistingAndApplyIsIdempotent() {
        var snapshot = HouseholdSnapshot()
        snapshot.apply(member("First", at: t0))
        XCTAssertFalse(snapshot.apply(member("Second", at: t0)))
        XCTAssertFalse(snapshot.apply(member("First", at: t0)))
        XCTAssertEqual(snapshot.members["member-1"]?.displayName, "First")
    }

    func testRecommendationsAndPostsMergeByCreatedAt() {
        var snapshot = HouseholdSnapshot()
        let r1 = HouseholdRecommendation(id: "rec-1", fromMemberId: "a", toMemberIds: ["b"], libraryItemId: "i",
                                         serverFingerprint: "", title: "One", author: "", note: "", createdAt: t0)
        var r2 = r1; r2.title = "Two"; r2.createdAt = t0.addingTimeInterval(1)
        snapshot.apply(.recommendation(r2))
        XCTAssertFalse(snapshot.apply(.recommendation(r1)))
        XCTAssertEqual(snapshot.recommendations["rec-1"]?.title, "Two")
        XCTAssertEqual(snapshot.recommendations(for: "b").count, 1)
        XCTAssertTrue(snapshot.recommendations(for: "c").isEmpty)
    }

    func testLocalSetOverridesSkewedStamp() {
        var snapshot = HouseholdSnapshot()
        snapshot.apply(member("Remote", at: t0.addingTimeInterval(1000)))
        snapshot.set(member("Mine", at: t0))
        XCTAssertEqual(snapshot.members["member-1"]?.displayName, "Mine")
    }

    func testRemoveByRecordTypeAndName() {
        var snapshot = HouseholdSnapshot()
        let n = HouseholdNowListening(memberId: "member-1", libraryItemId: "i", serverFingerprint: "", title: "T",
                                      author: "", progress: 0.1, updatedAt: t0)
        snapshot.apply(.nowListening(n))
        snapshot.apply(member("Sam", at: t0))
        XCTAssertNotNil(snapshot.record(named: "nl-member-1"))
        XCTAssertTrue(snapshot.remove(recordType: HouseholdRecordMapper.RecordType.nowListening, recordName: "nl-member-1"))
        XCTAssertTrue(snapshot.remove(recordType: HouseholdRecordMapper.RecordType.member, recordName: "member-1"))
        XCTAssertFalse(snapshot.remove(recordType: "Nope", recordName: "member-1"))
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testSnapshotCodableRoundTrip() throws {
        var snapshot = HouseholdSnapshot()
        snapshot.apply(member("Sam", at: t0))
        snapshot.apply(.clubPost(HouseholdClubPost(id: "post-1", clubId: "c", memberId: "member-1",
                                                   positionSeconds: 5, text: "Hi", createdAt: t0)))
        let data = try JSONEncoder().encode({ var c = HouseholdCache(); c.snapshot = snapshot; return c }())
        XCTAssertEqual(try JSONDecoder().decode(HouseholdCache.self, from: data).snapshot, snapshot)
    }

    // MARK: Batch 481

    private func plainMember(_ id: String) -> HouseholdMember {
        HouseholdMember(id: id, displayName: id, avatarSymbol: "book.fill", avatarColorIndex: 0,
                        serverFingerprint: "", updatedAt: t0)
    }

    func testMembershipHidesSomeoneNoLongerOnTheShare() {
        let members = ["member-me", "member-a", "member-gone"].map(plainMember)
        let current = HouseholdMembership.current(members: members,
                                                  participantRecordNames: [CKCurrentUserDefaultName, "_a"],
                                                  myMemberId: "member-me")
        XCTAssertEqual(current.map(\.id), ["member-me", "member-a"])
    }

    func testMembershipShowsEveryoneWhenTheShareIsUnknownOrDoesNotRecogniseYou() {
        let members = ["member-me", "member-a"].map(plainMember)
        XCTAssertEqual(HouseholdMembership.current(members: members, participantRecordNames: nil,
                                                   myMemberId: "member-me").count, 2)
        XCTAssertEqual(HouseholdMembership.current(members: members, participantRecordNames: ["_x"],
                                                   myMemberId: "member-me").count, 2)
        XCTAssertEqual(HouseholdMembership.current(members: members, participantRecordNames: ["_a"],
                                                   myMemberId: nil).count, 2)
    }

    func testLeavingRemovesYourRecordsButNotOthersOrClubs() {
        var snapshot = HouseholdSnapshot()
        snapshot.apply(.recommendation(HouseholdRecommendation(id: "rec-mine", fromMemberId: "member-me",
                                                               toMemberIds: ["member-a"], libraryItemId: "i",
                                                               serverFingerprint: "", title: "T", author: "",
                                                               note: "", createdAt: t0)))
        snapshot.apply(.recommendation(HouseholdRecommendation(id: "rec-theirs", fromMemberId: "member-a",
                                                               toMemberIds: ["member-me"], libraryItemId: "i",
                                                               serverFingerprint: "", title: "T", author: "",
                                                               note: "", createdAt: t0)))
        snapshot.apply(.clubPost(HouseholdClubPost(id: "post-mine", clubId: "club-1", memberId: "member-me",
                                                   positionSeconds: 1, text: "x", createdAt: t0)))
        snapshot.apply(.clubPost(HouseholdClubPost(id: "post-theirs", clubId: "club-1", memberId: "member-a",
                                                   positionSeconds: 1, text: "y", createdAt: t0)))
        snapshot.apply(.club(HouseholdClub(id: "club-1", libraryItemId: "i", title: "T", author: "",
                                           serverFingerprint: "", goalText: nil, goalSeconds: nil, goalDate: nil,
                                           createdBy: "member-me", updatedAt: t0)))
        XCTAssertEqual(HouseholdLeave.recordNamesToDelete(snapshot: snapshot, myMemberId: "member-me"),
                       ["member-me", "nl-member-me", "rec-mine", "post-mine"])
    }
}
