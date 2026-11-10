import XCTest
@testable import ShelfHead

/// Batches 454 and 455: SpoilerGate, goal maths, the publish throttle, shelf filtering, the inbox and dismissed set.
final class HouseholdSocialTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(_ id: String, by member: String, at seconds: Double, created: TimeInterval = 0) -> HouseholdClubPost {
        HouseholdClubPost(id: id, clubId: "c", memberId: member, positionSeconds: seconds, text: id,
                          createdAt: Date(timeIntervalSince1970: 1_000 + created))
    }

    private func member(_ id: String) -> HouseholdMember {
        HouseholdMember(id: id, displayName: id, avatarSymbol: "book.fill", avatarColorIndex: 0,
                        serverFingerprint: "fp", updatedAt: now)
    }

    private func listening(_ memberId: String, item: String = "i1", fp: String = "fp", progress: Double = 0.5,
                           age: TimeInterval = 60) -> HouseholdNowListening {
        HouseholdNowListening(memberId: memberId, libraryItemId: item, serverFingerprint: fp, title: "T", author: "A",
                              progress: progress, updatedAt: now.addingTimeInterval(-age))
    }

    private func rec(_ id: String, from: String, to: [String], age: TimeInterval = 60) -> HouseholdRecommendation {
        HouseholdRecommendation(id: id, fromMemberId: from, toMemberIds: to, libraryItemId: "i1",
                                serverFingerprint: "fp", title: "T", author: "A", note: "",
                                createdAt: now.addingTimeInterval(-age))
    }

    // MARK: SpoilerGate

    func testGateHidesPostsAheadAndCounts() {
        let posts = [post("a", by: "x", at: 100), post("b", by: "x", at: 500), post("c", by: "y", at: 900)]
        let r = SpoilerGate.filter(posts: posts, myPosition: 500, myMemberId: "me")
        XCTAssertEqual(r.visible.map(\.id), ["a", "b"])
        XCTAssertEqual(r.hiddenAheadCount, 1)
    }

    func testGateAlwaysShowsMyOwnPosts() {
        let posts = [post("mine", by: "me", at: 9_000), post("theirs", by: "x", at: 9_000)]
        let r = SpoilerGate.filter(posts: posts, myPosition: 10, myMemberId: "me")
        XCTAssertEqual(r.visible.map(\.id), ["mine"])
        XCTAssertEqual(r.hiddenAheadCount, 1)
    }

    func testGateFinishedBookShowsEverything() {
        let posts = [post("a", by: "x", at: 100_000)]
        let r = SpoilerGate.filter(posts: posts, myPosition: .infinity, myMemberId: nil)
        XCTAssertEqual(r.visible.count, 1)
        XCTAssertEqual(r.hiddenAheadCount, 0)
    }

    func testGateOrdersByPositionThenTime() {
        let posts = [post("late", by: "x", at: 50, created: 20), post("early", by: "x", at: 50, created: 10), post("first", by: "x", at: 5)]
        let r = SpoilerGate.filter(posts: posts, myPosition: 100, myMemberId: nil)
        XCTAssertEqual(r.visible.map(\.id), ["first", "early", "late"])
    }

    func testGateBoundaryIsInclusive() {
        let r = SpoilerGate.filter(posts: [post("a", by: "x", at: 100)], myPosition: 100, myMemberId: nil)
        XCTAssertEqual(r.visible.count, 1)
    }

    // MARK: Goal maths

    func testStatusReachedBehindAndNotShared() {
        XCTAssertEqual(ClubGoal.status(sharedProgress: nil, bookDuration: 1000, goalSeconds: 500), .notShared)
        XCTAssertEqual(ClubGoal.status(sharedProgress: 0.5, bookDuration: 1000, goalSeconds: 500), .reached)
        XCTAssertEqual(ClubGoal.status(sharedProgress: 0.2, bookDuration: 1000, goalSeconds: 500), .behind(secondsToGo: 300))
        XCTAssertEqual(ClubGoal.status(sharedProgress: 0.9, bookDuration: 0, goalSeconds: 500), .notShared)
    }

    func testFractionOfGoalClamps() {
        XCTAssertEqual(ClubGoal.fractionOfGoal(sharedProgress: 0.25, bookDuration: 1000, goalSeconds: 500), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ClubGoal.fractionOfGoal(sharedProgress: 0.9, bookDuration: 1000, goalSeconds: 500), 1)
        XCTAssertEqual(ClubGoal.fractionOfGoal(sharedProgress: nil, bookDuration: 1000, goalSeconds: 500), 0)
        XCTAssertEqual(ClubGoal.fractionOfGoal(sharedProgress: 0.1, bookDuration: 1000, goalSeconds: 0), 1)
    }

    func testSharedProgressMatchesBookAndServer() {
        let club = HouseholdClub(id: "c", libraryItemId: "i1", title: "T", author: "A", serverFingerprint: "fp",
                                 goalText: nil, goalSeconds: nil, goalDate: nil, createdBy: "m", updatedAt: now)
        XCTAssertEqual(ClubGoal.sharedProgress(of: listening("x"), in: club), 0.5)
        XCTAssertNil(ClubGoal.sharedProgress(of: listening("x", item: "other"), in: club))
        // Batch 482: another server matches by title and author instead of item id.
        XCTAssertEqual(ClubGoal.sharedProgress(of: listening("x", item: "zzz", fp: "elsewhere"), in: club), 0.5)
        XCTAssertNil(ClubGoal.sharedProgress(of: nil, in: club))
    }

    func testBookClubIdsSpanServersAndReadOlderClubs() {
        let here = BookClubIds(serverFingerprint: "fp1", libraryItemId: "li_1", title: "Dune", author: "Herbert")
        let there = BookClubIds(serverFingerprint: "fp2", libraryItemId: "li_9", title: "DUNE", author: "herbert")
        XCTAssertEqual(here.shared, there.shared)
        XCTAssertNotEqual(here.legacy, there.legacy)
        var snapshot = HouseholdSnapshot()
        let old = HouseholdClub(id: here.legacy, libraryItemId: "li_1", title: "Dune", author: "Herbert",
                                serverFingerprint: "fp1", goalText: "Ch 3", goalSeconds: nil, goalDate: nil,
                                createdBy: "m", updatedAt: now)
        snapshot.apply(.club(old))
        XCTAssertEqual(here.club(in: snapshot)?.id, here.legacy)
        snapshot.apply(.clubPost(HouseholdClubPost(id: "p1", clubId: here.legacy, memberId: "m", positionSeconds: 10,
                                                   text: "a", createdAt: now)))
        snapshot.apply(.clubPost(HouseholdClubPost(id: "p2", clubId: here.shared, memberId: "n", positionSeconds: 5,
                                                   text: "b", createdAt: now)))
        XCTAssertEqual(here.posts(in: snapshot).map(\.id), ["p2", "p1"])
        XCTAssertEqual(there.posts(in: snapshot).map(\.id), ["p2"])
        var moved = old
        moved.id = here.shared
        snapshot.apply(.club(moved))
        XCTAssertEqual(here.club(in: snapshot)?.id, here.shared)
    }

    func testSharedProgressByTitleWhenNoItemId() {
        let club = HouseholdClub(id: "c", libraryItemId: nil, title: "t", author: "a", serverFingerprint: "",
                                 goalText: nil, goalSeconds: nil, goalDate: nil, createdBy: "m", updatedAt: now)
        XCTAssertEqual(ClubGoal.sharedProgress(of: listening("x", item: "zzz", fp: "other"), in: club), 0.5)
    }

    func testDaysLeftAndHasGoal() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ClubGoal.daysLeft(goalDate: now.addingTimeInterval(3 * 86_400), now: now, calendar: cal), 3)
        XCTAssertEqual(ClubGoal.daysLeft(goalDate: now.addingTimeInterval(-86_400), now: now, calendar: cal), -1)
        XCTAssertNil(ClubGoal.daysLeft(goalDate: nil, now: now, calendar: cal))
        var club = HouseholdClub(id: "c", libraryItemId: nil, title: "t", author: "a", serverFingerprint: "",
                                 goalText: "  ", goalSeconds: nil, goalDate: nil, createdBy: "m", updatedAt: now)
        XCTAssertFalse(ClubGoal.hasGoal(club))
        XCTAssertFalse(ClubGoal.hasGoal(nil))
        club.goalSeconds = 10
        XCTAssertTrue(ClubGoal.hasGoal(club))
    }

    func testPostDraftRules() {
        XCTAssertFalse(ClubPostDraft.canPost("  \n"))
        XCTAssertTrue(ClubPostDraft.canPost("hi"))
        XCTAssertEqual(ClubPostDraft.clamped(String(repeating: "a", count: 600)).count, ClubPostDraft.maxLength)
    }

    // MARK: Publisher throttle

    func testTickIsThrottledToOncePerMinute() {
        XCTAssertTrue(NowListeningThrottle.shouldPublish(.tick, lastPublishedAt: nil, now: now))
        XCTAssertFalse(NowListeningThrottle.shouldPublish(.tick, lastPublishedAt: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(NowListeningThrottle.shouldPublish(.tick, lastPublishedAt: now.addingTimeInterval(-60), now: now))
    }

    func testPauseFinishAndBookChangeIgnoreThrottle() {
        let recent = now.addingTimeInterval(-1)
        for t: NowListeningThrottle.Trigger in [.pause, .finish, .bookChanged] {
            XCTAssertTrue(NowListeningThrottle.shouldPublish(t, lastPublishedAt: recent, now: now))
        }
    }

    func testTriggerDecisions() {
        typealias T = NowListeningThrottle
        XCTAssertEqual(T.trigger(wasPlaying: true, isPlaying: false, previousItemId: "a", itemId: "a", progress: 0.4), .pause)
        XCTAssertEqual(T.trigger(wasPlaying: true, isPlaying: false, previousItemId: "a", itemId: "a", progress: 0.995), .finish)
        XCTAssertEqual(T.trigger(wasPlaying: true, isPlaying: true, previousItemId: "a", itemId: "a", progress: 0.4), .tick)
        XCTAssertEqual(T.trigger(wasPlaying: false, isPlaying: true, previousItemId: "a", itemId: "b", progress: 0.1), .bookChanged)
        // Paused and loaded (app launch): not "now listening".
        XCTAssertNil(T.trigger(wasPlaying: false, isPlaying: false, previousItemId: nil, itemId: "a", progress: 0.4))
        XCTAssertNil(T.trigger(wasPlaying: true, isPlaying: true, previousItemId: "a", itemId: nil, progress: 0))
    }

    func testPublishedProgress() {
        XCTAssertEqual(NowListeningThrottle.publishedProgress(0.995, trigger: .finish), 1)
        XCTAssertEqual(NowListeningThrottle.publishedProgress(1.4, trigger: .tick), 1)
        XCTAssertEqual(NowListeningThrottle.publishedProgress(-1, trigger: .pause), 0)
    }

    // MARK: Shelf filtering

    func testSameServerNeedsMatchingNonEmptyFingerprint() {
        XCTAssertTrue(HouseholdShelfLogic.isSameServer("abc", mine: "abc"))
        XCTAssertFalse(HouseholdShelfLogic.isSameServer("abc", mine: "xyz"))
        XCTAssertFalse(HouseholdShelfLogic.isSameServer("", mine: ""))
    }

    func testShelfListeningExcludesMeStaleAndUnknownMembers() {
        var snap = HouseholdSnapshot()
        for id in ["me", "a", "b"] { snap.set(.member(member(id))) }
        snap.set(.nowListening(listening("me")))
        snap.set(.nowListening(listening("a", age: 60)))
        snap.set(.nowListening(listening("b", age: HouseholdShelfLogic.maxListeningAge + 1)))
        snap.set(.nowListening(listening("ghost")))
        let rows = HouseholdShelfLogic.listening(snapshot: snap, myMemberId: "me", now: now)
        XCTAssertEqual(rows.map(\.memberId), ["a"])
    }

    func testShelfShowsOnlyInHouseholdWithContent() {
        XCTAssertFalse(HouseholdShelfLogic.shouldShow(inHousehold: false, listeningCount: 2, inboxCount: 2))
        XCTAssertFalse(HouseholdShelfLogic.shouldShow(inHousehold: true, listeningCount: 0, inboxCount: 0))
        XCTAssertTrue(HouseholdShelfLogic.shouldShow(inHousehold: true, listeningCount: 0, inboxCount: 1))
    }

    // MARK: Inbox and dismissed set

    func testInboxIsToMeNotDismissedNewestFirst() {
        var snap = HouseholdSnapshot()
        snap.set(.recommendation(rec("old", from: "a", to: ["me"], age: 500)))
        snap.set(.recommendation(rec("new", from: "a", to: ["me", "b"], age: 10)))
        snap.set(.recommendation(rec("other", from: "a", to: ["b"])))
        snap.set(.recommendation(rec("gone", from: "a", to: ["me"], age: 100)))
        let inbox = HouseholdInboxLogic.inbox(snapshot: snap, myMemberId: "me", dismissed: ["gone"])
        XCTAssertEqual(inbox.map(\.id), ["new", "old"])
        XCTAssertTrue(HouseholdInboxLogic.inbox(snapshot: snap, myMemberId: nil, dismissed: []).isEmpty)
    }

    func testDismissedSetPrunesDeletedRecommendations() {
        XCTAssertEqual(HouseholdInboxLogic.pruned(["a", "b"], existing: ["b", "c"]), ["b"])
    }

    func testNewArrivalsAreRecentUnknownUnnotifiedAndNotMine() {
        var snap = HouseholdSnapshot()
        snap.set(.recommendation(rec("fresh", from: "a", to: ["me"], age: 60)))
        snap.set(.recommendation(rec("known", from: "a", to: ["me"], age: 60)))
        snap.set(.recommendation(rec("done", from: "a", to: ["me"], age: 60)))
        snap.set(.recommendation(rec("stale", from: "a", to: ["me"], age: 3 * 86_400)))
        snap.set(.recommendation(rec("mine", from: "me", to: ["me"], age: 60)))
        snap.set(.recommendation(rec("elsewhere", from: "a", to: ["b"], age: 60)))
        let arrivals = HouseholdInboxLogic.newArrivals(snapshot: snap, myMemberId: "me", knownBefore: ["known"],
                                                       notified: ["done"], now: now)
        XCTAssertEqual(arrivals.map(\.id), ["fresh"])
    }

    // MARK: Recommend draft

    func testRecommendDraftClampsNoteAndKeepsMemberOrder() {
        let members = [member("a"), member("b"), member("c")]
        let made = RecommendDraft.make(fromMemberId: "me", toMemberIds: ["c", "a"], members: members,
                                       libraryItemId: "i1", serverFingerprint: "fp", title: "T", author: "A",
                                       note: String(repeating: "x", count: 400), now: now, id: "rec-1")
        XCTAssertEqual(made.toMemberIds, ["a", "c"])
        XCTAssertEqual(made.note.count, RecommendDraft.maxNoteLength)
        XCTAssertFalse(RecommendDraft.canSend(selected: []))
        XCTAssertTrue(RecommendDraft.canSend(selected: ["a"]))
        XCTAssertEqual(RecommendDraft.recipients(members: members, myMemberId: "b").map(\.id), ["a", "c"])
    }

    // MARK: Book Detail row

    func testBookClubRowOnlyInHouseholdAndNotPodcasts() {
        func rows(podcast: Bool, household: Bool) -> [BookDetailView.BookToolRow] {
            BookDetailView.bookToolRows(isPodcast: podcast, chapterCount: 0, bookmarkCount: 0, bookmarksLoadFailed: false,
                                        showsTranscript: false, hasSearchableTranscript: false,
                                        hasCompanionEbook: false, inHousehold: household)
        }
        XCTAssertEqual(rows(podcast: false, household: true), [.bookClub])
        XCTAssertTrue(rows(podcast: false, household: false).isEmpty)
        XCTAssertTrue(rows(podcast: true, household: true).isEmpty)
    }
}
