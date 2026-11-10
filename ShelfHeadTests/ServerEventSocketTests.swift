import XCTest
@testable import ShelfHead

/// Batch 406: the pure parts of the live server-event socket — the Engine.IO v4 /
/// Socket.IO v5 wire format, the ws(s) endpoint, reconnect backoff, the
/// `user_item_progress_updated` payload, and the decision about what a remote position
/// may do to the player.
final class ServerEventSocketTests: XCTestCase {

    // MARK: - Engine.IO

    func testParsesOpenHandshake() {
        let frame = #"0{"sid":"lv_VI97HAXpY6yYWAAAC","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}"#
        guard case .open(let h)? = EngineIOPacket.parse(frame) else { return XCTFail("expected open") }
        XCTAssertEqual(h.sid, "lv_VI97HAXpY6yYWAAAC")
        XCTAssertEqual(h.pingInterval, 25000)
        XCTAssertEqual(h.pingTimeout, 20000)
        XCTAssertEqual(h.maxPayload, 1000000)
    }

    func testMalformedOpenIsIgnored() {
        XCTAssertNil(EngineIOPacket.parse("0{not json"))
        XCTAssertNil(EngineIOPacket.parse(""))
        XCTAssertNil(EngineIOPacket.parse("9"))
    }

    func testPingAnswersWithPongCarryingSamePayload() {
        XCTAssertEqual(EngineIOPacket.parse("2"), .ping(""))
        XCTAssertEqual(EngineIOPacket.pong("").encoded, "3")
        XCTAssertEqual(EngineIOPacket.parse("2probe"), .ping("probe"))
        XCTAssertEqual(EngineIOPacket.pong("probe").encoded, "3probe")
    }

    func testOtherEngineIOTypes() {
        XCTAssertEqual(EngineIOPacket.parse("1"), .close)
        XCTAssertEqual(EngineIOPacket.parse("3"), .pong(""))
        XCTAssertEqual(EngineIOPacket.parse("4hello"), .message("hello"))
        XCTAssertEqual(EngineIOPacket.parse("6"), .noop)
        XCTAssertEqual(EngineIOPacket.message("40").encoded, "440")
    }

    // MARK: - Socket.IO

    func testConnectFrames() {
        XCTAssertEqual(SocketIOPacket.connectFrame, "40")
        XCTAssertEqual(SocketIOPacket.parse(#"0{"sid":"abc"}"#), .connect(sid: "abc"))
        XCTAssertEqual(SocketIOPacket.parse("0"), .connect(sid: nil))
    }

    func testConnectErrorAndDisconnect() {
        XCTAssertEqual(SocketIOPacket.parse(#"4{"message":"Not authorized"}"#), .connectError(message: "Not authorized"))
        XCTAssertEqual(SocketIOPacket.parse("1"), .disconnect)
    }

    func testAuthEventFrameEscapesToken() throws {
        let frame = try XCTUnwrap(SocketIOPacket.eventFrame(name: "auth", argument: #"a"b\c"#))
        XCTAssertTrue(frame.hasPrefix("42"))
        // Round-trips through the parser intact.
        guard case .event(let name, let payload)? = SocketIOPacket.parse(String(frame.dropFirst())) else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(name, "auth")
        let value = try JSONSerialization.jsonObject(with: XCTUnwrap(payload), options: [.fragmentsAllowed]) as? String
        XCTAssertEqual(value, #"a"b\c"#)
    }

    func testParsesEventWithObjectPayload() throws {
        guard case .event(let name, let payload)? = SocketIOPacket.parse(#"2["init",{"userId":"u1","username":"demo"}]"#) else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(name, "init")
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(payload)) as? [String: Any]
        XCTAssertEqual(object?["userId"] as? String, "u1")
    }

    func testEventWithoutArgumentAndWithAckId() {
        XCTAssertEqual(SocketIOPacket.parse(#"2["pong"]"#), .event(name: "pong", payload: nil))
        guard case .event(let name, _)? = SocketIOPacket.parse(#"212["x",1]"#) else { return XCTFail("expected event") }
        XCTAssertEqual(name, "x")
    }

    func testOtherNamespacesAndBinaryAreIgnored() {
        XCTAssertEqual(SocketIOPacket.parse(#"2/admin,["bar"]"#), .ignored)
        XCTAssertEqual(SocketIOPacket.parse(#"51-["baz",{"_placeholder":true,"num":0}]"#), .ignored)
        XCTAssertNotNil(SocketIOPacket.parse(#"2/,["foo"]"#))
        XCTAssertNil(SocketIOPacket.parse(#"2not json"#))
        XCTAssertNil(SocketIOPacket.parse(""))
    }

    // MARK: - Endpoint

    func testEndpointURL() {
        XCTAssertEqual(SocketIOEndpoint.url(serverURL: "https://abs.example.com")?.absoluteString,
                       "wss://abs.example.com/socket.io/?EIO=4&transport=websocket")
        XCTAssertEqual(SocketIOEndpoint.url(serverURL: "http://192.168.1.5:13378/")?.absoluteString,
                       "ws://192.168.1.5:13378/socket.io/?EIO=4&transport=websocket")
        XCTAssertEqual(SocketIOEndpoint.url(serverURL: "https://example.com/audiobookshelf")?.absoluteString,
                       "wss://example.com/audiobookshelf/socket.io/?EIO=4&transport=websocket")
        XCTAssertNil(SocketIOEndpoint.url(serverURL: ""))
        XCTAssertNil(SocketIOEndpoint.url(serverURL: "/api/me"))
        XCTAssertNil(SocketIOEndpoint.url(serverURL: "ftp://example.com"))
    }

    // MARK: - Backoff

    func testBackoffGrowsAndCaps() {
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 0, jitter: 1), 2)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 1, jitter: 1), 4)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 3, jitter: 1), 16)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 50, jitter: 1), ReconnectBackoff.cap)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: 50, jitter: 0), ReconnectBackoff.cap / 2)
        XCTAssertEqual(ReconnectBackoff.delay(attempt: -3, jitter: 0), 1)
    }

    // MARK: - Payload

    func testDecodesProgressEventPayload() throws {
        let json = #"""
        {"id":"p1","sessionId":"s-web","deviceDescription":"macOS 15 / Safari",
         "data":{"id":"p1","userId":"u1","libraryItemId":"li1","episodeId":null,"mediaItemId":"b1",
                 "mediaItemType":"book","duration":3600,"progress":0.5,"currentTime":1800,
                 "isFinished":false,"hideFromContinueListening":false,"ebookLocation":null,
                 "ebookProgress":null,"lastUpdate":1760000000000,"startedAt":1750000000000,"finishedAt":null}}
        """#
        let event = try JSONDecoder().decode(RemoteProgressEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.sessionId, "s-web")
        XCTAssertEqual(event.data.libraryItemId, "li1")
        XCTAssertNil(event.data.episodeId)
        XCTAssertEqual(event.data.currentTime, 1800)
        XCTAssertEqual(event.data.lastUpdate, 1760000000000)
    }

    func testPayloadWithoutLibraryItemIdIsRejected() {
        let json = #"{"id":"p1","sessionId":"s","data":{"id":"p1","libraryItemId":null,"currentTime":5}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RemoteProgressEvent.self, from: Data(json.utf8)))
    }

    // MARK: - RemoteProgressDecision

    private func decide(
        sessionId: String? = "s-other", own: Set<String> = ["s-mine"],
        eventItem: String = "li1", eventEpisode: String? = nil,
        loadedItem: String? = "li1", loadedEpisode: String? = nil,
        playing: Bool = false,
        localTime: Double = 100, localMs: Double? = 1_000,
        remoteTime: Double? = 900, remoteMs: Double? = 2_000, finished: Bool = false
    ) -> RemoteProgressDecision.PlayerAction {
        RemoteProgressDecision.playerAction(
            eventSessionId: sessionId, ownSessionIds: own,
            eventItemId: eventItem, eventEpisodeId: eventEpisode,
            loadedItemId: loadedItem, loadedEpisodeId: loadedEpisode,
            isPlayingOrStarting: playing,
            localTime: localTime, localLastUpdateMs: localMs,
            remoteTime: remoteTime, remoteLastUpdateMs: remoteMs, remoteIsFinished: finished)
    }

    func testMovesPausedPlayerToNewerRemotePosition() {
        XCTAssertEqual(decide(), .moveTo(900))
    }

    func testNeverYanksAPlayingBook() {
        XCTAssertEqual(decide(playing: true), .leave(.playingLocally))
    }

    func testIgnoresOwnSessionEcho() {
        XCTAssertEqual(decide(sessionId: "s-mine"), .leave(.ownSession))
        XCTAssertTrue(RemoteProgressDecision.isOwnEcho(eventSessionId: "s-mine", ownSessionIds: ["s-mine"]))
        XCTAssertFalse(RemoteProgressDecision.isOwnEcho(eventSessionId: nil, ownSessionIds: ["s-mine"]))
        XCTAssertFalse(RemoteProgressDecision.isOwnEcho(eventSessionId: "", ownSessionIds: [""]))
    }

    func testOtherItemOrEpisodeLeavesPlayerAlone() {
        XCTAssertEqual(decide(eventItem: "li2"), .leave(.notLoaded))
        XCTAssertEqual(decide(loadedItem: nil), .leave(.notLoaded))
        XCTAssertEqual(decide(eventEpisode: "ep1", loadedEpisode: "ep2"), .leave(.notLoaded))
        XCTAssertEqual(decide(eventEpisode: "ep1", loadedEpisode: nil), .leave(.notLoaded))
        XCTAssertEqual(decide(eventEpisode: "ep1", loadedEpisode: "ep1"), .moveTo(900))
    }

    func testLocalNewerWins() {
        XCTAssertEqual(decide(localMs: 3_000, remoteMs: 2_000), .leave(.localNewer))
    }

    func testTieGoesToServerLikeProgressReconciler() {
        XCTAssertEqual(decide(localMs: 2_000, remoteMs: 2_000), .moveTo(900))
    }

    func testMissingLocalStampTreatsRemoteAsNewer() {
        XCTAssertEqual(decide(localMs: nil), .moveTo(900))
    }

    func testFinishedOrPositionlessOrSamePositionLeavesPlayer() {
        XCTAssertEqual(decide(finished: true), .leave(.remoteFinished))
        XCTAssertEqual(decide(remoteTime: nil), .leave(.noPosition))
        XCTAssertEqual(decide(remoteTime: -.infinity), .leave(.noPosition))
        XCTAssertEqual(decide(localTime: 899, remoteTime: 900), .leave(.alreadyThere))
    }

    func testCacheReplacementIsNewerOrEqualWins() {
        XCTAssertTrue(RemoteProgressDecision.replacesCached(existingLastUpdate: nil, incomingLastUpdate: nil))
        XCTAssertTrue(RemoteProgressDecision.replacesCached(existingLastUpdate: nil, incomingLastUpdate: 5))
        XCTAssertTrue(RemoteProgressDecision.replacesCached(existingLastUpdate: 5, incomingLastUpdate: 5))
        XCTAssertTrue(RemoteProgressDecision.replacesCached(existingLastUpdate: 5, incomingLastUpdate: 6))
        XCTAssertFalse(RemoteProgressDecision.replacesCached(existingLastUpdate: 6, incomingLastUpdate: 5))
        XCTAssertFalse(RemoteProgressDecision.replacesCached(existingLastUpdate: 6, incomingLastUpdate: nil))
    }

    // MARK: - user_updated snapshot (Batch 409)

    private func rec(_ item: String, episode: String? = nil, time: Double = 100,
                     finished: Bool = false, lastUpdate: Int? = 1000) -> MediaProgress {
        MediaProgress(id: episode.map { "\(item)-\($0)" } ?? item, libraryItemId: item, episodeId: episode,
                      duration: 1000, progress: time / 1000, currentTime: time, isFinished: finished,
                      lastUpdate: lastUpdate, startedAt: 1, finishedAt: nil)
    }

    private func diff(items: [MediaProgress] = [], episodes: [MediaProgress] = [],
                      snapshot: [MediaProgress], allDecoded: Bool = true) -> ProgressSnapshotDiff {
        RemoteProgressDecision.snapshotDiff(
            cachedItems: Dictionary(uniqueKeysWithValues: items.map { ($0.libraryItemId, $0) }),
            cachedEpisodes: Dictionary(uniqueKeysWithValues: episodes.compactMap { p in p.episodeId.map { ($0, p) } }),
            snapshot: snapshot, allRecordsDecoded: allDecoded)
    }

    func testSnapshotEchoIsEmptyDiff() {
        let d = diff(items: [rec("a"), rec("b", time: 5)], episodes: [rec("p", episode: "e1")],
                     snapshot: [rec("a"), rec("b", time: 5), rec("p", episode: "e1")])
        XCTAssertTrue(d.isEmpty)
    }

    func testSnapshotNewerFinishedUpserts() {
        let d = diff(items: [rec("a")], snapshot: [rec("a", time: 1000, finished: true, lastUpdate: 2000)])
        XCTAssertEqual(d.upserts.count, 1)
        XCTAssertEqual(d.upserts.first?.isFinished, true)
        XCTAssertTrue(d.removedItemIds.isEmpty)
    }

    func testSnapshotOlderRemoteDoesNotUpsert() {
        let d = diff(items: [rec("a", time: 500, lastUpdate: 2000)], snapshot: [rec("a", time: 10, lastUpdate: 1000)])
        XCTAssertTrue(d.upserts.isEmpty)
    }

    func testSnapshotNewRecordUpserts() {
        XCTAssertEqual(diff(snapshot: [rec("new")]).upserts.count, 1)
    }

    func testSnapshotMissingRecordIsRemoved() {
        let d = diff(items: [rec("a"), rec("b")], episodes: [rec("p", episode: "e1"), rec("p", episode: "e2")],
                     snapshot: [rec("a"), rec("p", episode: "e1")])
        XCTAssertEqual(d.removedItemIds, ["b"])
        XCTAssertEqual(d.removedEpisodeIds, ["e2"])
        XCTAssertTrue(d.upserts.isEmpty)
    }

    func testPartialDecodeNeverRemoves() {
        let d = diff(items: [rec("a"), rec("b")], snapshot: [rec("a")], allDecoded: false)
        XCTAssertTrue(d.isEmpty)
    }

    func testSnapshotEpisodesKeyedByEpisodeId() {
        // Same libraryItemId, different episodes: must not collapse onto one key.
        let d = diff(episodes: [rec("p", episode: "e1")],
                     snapshot: [rec("p", episode: "e1"), rec("p", episode: "e2", time: 7)])
        XCTAssertEqual(d.upserts.count, 1)
        XCTAssertEqual(d.upserts.first?.episodeId, "e2")
        XCTAssertTrue(d.removedItemIds.isEmpty)
    }

    func testUserUpdatedDecodesWithoutKeepingToken() throws {
        let json = #"{"id":"u","username":"x","token":"SECRET","mediaProgress":[{"id":"1","libraryItemId":"a","currentTime":5,"isFinished":true,"lastUpdate":9}]}"#
        let event = try JSONDecoder().decode(RemoteUserUpdatedEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.mediaProgress?.count, 1)
        XCTAssertFalse(event.hadUndecodableRecords)
        XCTAssertFalse(String(describing: event).contains("SECRET"))
        XCTAssertFalse(String(describing: Mirror(reflecting: event).children.map { "\($0.value)" }).contains("SECRET"))
    }

    func testUserUpdatedBadElementIsFlaggedNotFatal() throws {
        let json = #"{"mediaProgress":[{"libraryItemId":"a"},{"currentTime":3}]}"#
        let event = try JSONDecoder().decode(RemoteUserUpdatedEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.mediaProgress?.map(\.libraryItemId), ["a"])
        XCTAssertTrue(event.hadUndecodableRecords)
    }

    func testUserUpdatedWithoutMediaProgressIsNoOp() throws {
        let event = try JSONDecoder().decode(RemoteUserUpdatedEvent.self, from: Data(#"{"id":"u","token":"t"}"#.utf8))
        XCTAssertNil(event.mediaProgress)
    }
}
