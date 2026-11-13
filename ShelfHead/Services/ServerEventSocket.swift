import Foundation
import UIKit   // UIApplication lifecycle notifications + applicationState: the socket lives outside any View, so SwiftUI's scenePhase isn't reachable here

// MARK: - Live server events (Batch 406)
//
// Audiobookshelf pushes progress changes over socket.io (server/SocketAuthority.js), but
// until Batch 406 this app only learned about progress made elsewhere (the web player,
// another phone, the Watch's own session) the next time it fetched `/api/me`. This file
// is a dependency-free socket.io client — Engine.IO v4 over a single
// `URLSessionWebSocketTask`, no HTTP long-polling — just big enough to receive those
// events:
//
//   1. GET `<server>/socket.io/?EIO=4&transport=websocket` (upgrade to a WebSocket). The
//      server answers with an Engine.IO `open` packet: `0{"sid":…,"pingInterval":25000,…}`.
//   2. Send the socket.io CONNECT for the main namespace: `40`. Server answers `40{"sid":…}`.
//   3. Authenticate: `42["auth","<access token>"]`. ABS answers `42["init",{…}]` on
//      success or `42["auth_failed",{"message":…}]`. (ABS authenticates the socket with
//      this event, not with the handshake headers — see `authenticateSocket`.)
//   4. Heartbeat: the SERVER pings (`2`) every `pingInterval`; the client answers `3`.
//      No ping within `pingInterval + pingTimeout` means the connection is dead.
//   5. Events arrive as `42["user_item_progress_updated",{id,sessionId,deviceDescription,
//      data: MediaProgress}]`, emitted to every socket of the user whenever a playback
//      session syncs or closes (server/managers/PlaybackSessionManager.js).
//
// The wire parsing is pure (`EngineIOPacket`, `SocketIOPacket`) and unit-tested in
// `ServerEventSocketTests.swift`; so are the reconnect delay (`ReconnectBackoff`) and the
// decision about what a remote position may do to the paused player
// (`RemoteProgressDecision`).

// MARK: - Engine.IO v4 packets

/// The Engine.IO `open` packet's JSON payload. `pingInterval`/`pingTimeout` are in
/// milliseconds (engine.io-protocol README, "Handshake").
struct EngineIOHandshake: Decodable, Equatable, Sendable {
    let sid: String
    let pingInterval: Int
    let pingTimeout: Int
    let maxPayload: Int?
}

/// One Engine.IO v4 packet as carried in one WebSocket text frame: a single type digit
/// followed by an optional payload (engine.io-protocol README, "Packet encoding").
enum EngineIOPacket: Equatable, Sendable {
    case open(EngineIOHandshake)
    case close
    case ping(String)
    case pong(String)
    case message(String)
    case upgrade
    case noop

    /// Parses one text frame. Returns nil for an empty frame, an unknown type digit, or
    /// an `open` packet whose JSON doesn't decode — the caller treats nil as "ignore".
    static func parse(_ frame: String) -> EngineIOPacket? {
        guard let first = frame.first else { return nil }
        let body = String(frame.dropFirst())
        switch first {
        case "0":
            guard let data = body.data(using: .utf8),
                  let handshake = try? JSONDecoder().decode(EngineIOHandshake.self, from: data)
            else { return nil }
            return .open(handshake)
        case "1": return .close
        case "2": return .ping(body)
        case "3": return .pong(body)
        case "4": return .message(body)
        case "5": return .upgrade
        case "6": return .noop
        default: return nil
        }
    }

    /// The text frame for packets a client sends. A client never sends `open`; it's
    /// encoded anyway (as a bare `0`) so the function stays total.
    var encoded: String {
        switch self {
        case .open: return "0"
        case .close: return "1"
        case .ping(let p): return "2" + p
        case .pong(let p): return "3" + p
        case .message(let m): return "4" + m
        case .upgrade: return "5"
        case .noop: return "6"
        }
    }
}

// MARK: - Socket.IO v5 packets

/// A Socket.IO v5 packet, i.e. the payload of an Engine.IO `message` (socket.io-protocol
/// v5, "Packet encoding": `<type>[<attachments>-][<namespace>,][<ack id>][JSON]`). Only
/// the main namespace (`/`) is used by Audiobookshelf; a packet for any other namespace
/// parses to `.ignored`. Binary events/acks are never sent by ABS to this client and
/// also parse to `.ignored`.
enum SocketIOPacket: Equatable, Sendable {
    /// CONNECT acknowledgement (`0{"sid":…}`).
    case connect(sid: String?)
    /// The server disconnected this socket from the namespace (`1`).
    case disconnect
    /// An event: the name plus its first argument re-serialized as JSON (nil when the
    /// event carried no argument). ABS events carry exactly one argument.
    case event(name: String, payload: Data?)
    /// CONNECT_ERROR (`4{"message":…}`).
    case connectError(message: String?)
    case ignored

    static func parse(_ text: String) -> SocketIOPacket? {
        guard let first = text.first, let type = first.wholeNumberValue else { return nil }
        var rest = Substring(text.dropFirst())
        // A namespace other than "/" is written as "/name," before the payload.
        if rest.first == "/" {
            guard let comma = rest.firstIndex(of: ",") else { return .ignored }
            let namespace = rest[rest.startIndex..<comma]
            guard namespace == "/" else { return .ignored }
            rest = rest[rest.index(after: comma)...]
        }
        switch type {
        case 0:
            let sid = Self.jsonObject(rest)?["sid"] as? String
            return .connect(sid: sid)
        case 1:
            return .disconnect
        case 2:
            // Skip an optional ack id (digits) before the JSON array.
            let json = rest.drop(while: { $0.isNumber })
            guard let data = String(json).data(using: .utf8),
                  let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let name = array.first as? String else { return nil }
            var payload: Data?
            if array.count > 1 {
                payload = try? JSONSerialization.data(withJSONObject: array[1], options: [.fragmentsAllowed])
            }
            return .event(name: name, payload: payload)
        case 4:
            return .connectError(message: Self.jsonObject(rest)?["message"] as? String)
        default:
            return .ignored
        }
    }

    /// CONNECT to the main namespace, already wrapped in its Engine.IO `message` frame.
    static let connectFrame = "40"

    /// An EVENT frame (`42[<name>,<argument>]`), Engine.IO-wrapped. The argument is
    /// JSON-encoded with `JSONSerialization`, so a token containing quotes or
    /// backslashes can't break the frame.
    static func eventFrame(name: String, argument: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [name, argument]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "42" + json
    }

    private static func jsonObject(_ text: Substring) -> [String: Any]? {
        guard !text.isEmpty, let data = String(text).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Endpoint, backoff, event payload

enum SocketIOEndpoint {
    /// `http(s)://host[:port][/base]` → `ws(s)://host[:port][/base]/socket.io/?EIO=4&transport=websocket`.
    /// ABS serves socket.io at `/socket.io` and, when a router base path is set, also at
    /// `<base>/socket.io` (SocketAuthority.initialize); the official app connects to
    /// `<server path>/socket.io` with `transports: ['websocket']` (audiobookshelf-app
    /// plugins/server.js), which is what this mirrors.
    static func url(serverURL: String) -> URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.host != nil else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        components.fragment = nil
        return components.url
    }
}

enum ReconnectBackoff {
    static let base: TimeInterval = 2
    static let cap: TimeInterval = 120

    /// Capped exponential backoff with jitter: `min(cap, base · 2^attempt)` scaled into
    /// `[50%, 100%]` by `jitter` (0…1). The 50% floor keeps a run of failures from ever
    /// collapsing into a tight loop; the jitter keeps several devices that lost the same
    /// server at the same moment from reconnecting in lockstep.
    static func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let exponent = Double(min(max(attempt, 0), 16))
        let raw = min(cap, base * pow(2, exponent))
        let j = min(max(jitter, 0), 1)
        return raw * (0.5 + 0.5 * j)
    }
}

/// `user_item_progress_updated`'s payload (PlaybackSessionManager.js: `{ id, sessionId,
/// deviceDescription, data: mediaProgress.getOldMediaProgress() }`). `data` decodes
/// through `MediaProgress`'s tolerant decoder, so it fails only when `libraryItemId` is
/// missing — a record nothing here could key anyway.
struct RemoteProgressEvent: Decodable {
    let id: String?
    let sessionId: String?
    let deviceDescription: String?
    let data: MediaProgress
}

/// Batch 409: `user_updated`'s payload. The server (MeController/UserController) emits it
/// to the user's own sockets after "mark finished", manual progress edits, "reset
/// progress" (which DELETES the record), bookmark and hide-from-continue-listening
/// changes, carrying `user.toOldJSONForBrowser()` — which includes the user's `token`.
/// Only `mediaProgress` is declared, so the token is never decoded or retained. Elements
/// decode one by one: a malformed record is dropped but remembered
/// (`hadUndecodableRecords`) so a partial snapshot can never be mistaken for "the server
/// deleted everything else".
struct RemoteUserUpdatedEvent: Decodable {
    /// nil when the key is absent or not an array — the event then means nothing to us.
    let mediaProgress: [MediaProgress]?
    let hadUndecodableRecords: Bool

    private enum CodingKeys: String, CodingKey { case mediaProgress }

    /// Never throws, so one bad element can't fail the array.
    private struct Slot: Decodable {
        let value: MediaProgress?
        init(from decoder: Decoder) throws { value = try? MediaProgress(from: decoder) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let slots = try? c.decode([Slot].self, forKey: .mediaProgress) {
            let records = slots.compactMap(\.value)
            mediaProgress = records
            hadUndecodableRecords = records.count != slots.count
        } else {
            mediaProgress = nil
            hadUndecodableRecords = false
        }
    }
}

/// Batch 409: the minimal change a full `user_updated` progress snapshot makes to the
/// library's progress maps. Empty when the snapshot is just an echo of what's cached.
struct ProgressSnapshotDiff {
    /// Records to write (newer-or-equal and actually different from the cached one).
    var upserts: [MediaProgress] = []
    /// Book keys (`libraryItemId`) cached but absent from the snapshot.
    var removedItemIds: [String] = []
    /// Episode keys (`episodeId`) cached but absent from the snapshot.
    var removedEpisodeIds: [String] = []

    var isEmpty: Bool { upserts.isEmpty && removedItemIds.isEmpty && removedEpisodeIds.isEmpty }
}

// MARK: - What a remote position may do to the player

/// Batch 406: the pure decision behind `PlayerViewModel.applyRemoteProgress`. The rule
/// the brief set — and the reason this is a separate, tested function — is "never yank a
/// playing book": a remote position only ever moves a *paused* player, only for the item
/// (and episode) that is actually loaded, never for this device's own session echoing
/// back, and only when the remote write is the newer one by the same newer-wins rule
/// `ProgressReconciler` applies everywhere else.
enum RemoteProgressDecision {
    enum PlayerAction: Equatable, Sendable {
        case moveTo(Double)
        case leave(Reason)
    }

    enum Reason: Equatable, Sendable {
        case ownSession, notLoaded, playingLocally, remoteFinished, noPosition, localNewer, alreadyThere
    }

    /// Positions closer than this are treated as the same — a remote sync of a position
    /// this device is already parked on must not cause a visible seek.
    static let samePositionTolerance: Double = 2

    static func isOwnEcho(eventSessionId: String?, ownSessionIds: Set<String>) -> Bool {
        guard let eventSessionId, !eventSessionId.isEmpty else { return false }
        return ownSessionIds.contains(eventSessionId)
    }

    static func playerAction(
        eventSessionId: String?, ownSessionIds: Set<String>,
        eventItemId: String, eventEpisodeId: String?,
        loadedItemId: String?, loadedEpisodeId: String?,
        isPlayingOrStarting: Bool,
        localTime: Double, localLastUpdateMs: Double?,
        remoteTime: Double?, remoteLastUpdateMs: Double?, remoteIsFinished: Bool
    ) -> PlayerAction {
        if isOwnEcho(eventSessionId: eventSessionId, ownSessionIds: ownSessionIds) { return .leave(.ownSession) }
        guard loadedItemId == eventItemId, loadedEpisodeId == eventEpisodeId else { return .leave(.notLoaded) }
        if isPlayingOrStarting { return .leave(.playingLocally) }
        // Moving a paused player to the very end would only make the next tap of Play
        // finish the book; the library shows it finished and the user decides.
        if remoteIsFinished { return .leave(.remoteFinished) }
        guard let remoteTime, remoteTime.isFinite, remoteTime >= 0 else { return .leave(.noPosition) }
        if ProgressReconciler.newerSide(localLastUpdate: localLastUpdateMs ?? 0,
                                        serverLastUpdate: remoteLastUpdateMs ?? 0) == .local {
            return .leave(.localNewer)
        }
        if abs(remoteTime - localTime) < samePositionTolerance { return .leave(.alreadyThere) }
        return .moveTo(remoteTime)
    }

    /// Whether an incoming record may replace the cached one in the library's progress
    /// map: newer-or-equal `lastUpdate` wins, so a late, out-of-order event can't roll a
    /// book's progress bar back. An incoming record without a timestamp only fills a gap.
    static func replacesCached(existingLastUpdate: Int?, incomingLastUpdate: Int?) -> Bool {
        guard let existingLastUpdate else { return true }
        guard let incomingLastUpdate else { return false }
        return incomingLastUpdate >= existingLastUpdate
    }

    /// Batch 409: whether two records for the same key differ in anything the library
    /// shows (position, fraction, finished flag, timestamps, duration). Used so an echo of
    /// a change this device already has doesn't rewrite the map and re-render everything.
    static func differs(_ a: MediaProgress, _ b: MediaProgress) -> Bool {
        a.currentTime != b.currentTime || a.progress != b.progress
            || a.isFinished != b.isFinished || a.lastUpdate != b.lastUpdate
            || a.duration != b.duration || a.startedAt != b.startedAt
            || a.finishedAt != b.finishedAt
            || a.ebookProgress != b.ebookProgress   // Batch 495 (L12): reading progress refreshes tiles too
    }

    /// Batch 409: the pure decision behind `LibraryViewModel.applyRemoteProgressSnapshot`.
    /// `user_updated` carries the user's COMPLETE progress list, so besides upserts it can
    /// express deletions ("reset progress" removes the record server-side): a cached key
    /// missing from the snapshot is removed. Removals are computed only when
    /// `allRecordsDecoded` — a partially decoded snapshot is missing records for reasons
    /// that have nothing to do with the server, and must never delete anything.
    /// Upserts follow `replacesCached`, so an older snapshot can't roll a bar back.
    static func snapshotDiff(
        cachedItems: [String: MediaProgress],
        cachedEpisodes: [String: MediaProgress],
        snapshot: [MediaProgress],
        allRecordsDecoded: Bool
    ) -> ProgressSnapshotDiff {
        var diff = ProgressSnapshotDiff()
        var itemKeys = Set<String>()
        var episodeKeys = Set<String>()
        for record in snapshot {
            let cached: MediaProgress?
            if let episodeId = record.episodeId {
                episodeKeys.insert(episodeId)
                cached = cachedEpisodes[episodeId]
            } else {
                itemKeys.insert(record.libraryItemId)
                cached = cachedItems[record.libraryItemId]
            }
            if let cached {
                guard replacesCached(existingLastUpdate: cached.lastUpdate,
                                     incomingLastUpdate: record.lastUpdate),
                      differs(cached, record) else { continue }
            }
            diff.upserts.append(record)
        }
        if allRecordsDecoded {
            diff.removedItemIds = cachedItems.keys.filter { !itemKeys.contains($0) }.sorted()
            diff.removedEpisodeIds = cachedEpisodes.keys.filter { !episodeKeys.contains($0) }.sorted()
        }
        return diff
    }
}

// MARK: - The socket

/// Batch 406: one live socket.io connection to the active account's server.
///
/// Lifecycle: `start(player:library:)` once the UI has its view models; the socket then
/// owns its own reconnects. It closes and reopens on `.shelfheadAccountChanged` (one
/// socket per active account, never one per account ever signed in), stops on its own
/// when the API has no configured account (signed out), suspends when the app goes to
/// the background while nothing is playing, and resumes on foreground. Reconnects use
/// `ReconnectBackoff`; three `auth_failed` replies in a row park the socket until the
/// next foreground or account change rather than rotating refresh tokens in a loop.
@MainActor
@Observable
final class ServerEventSocket {
    static let shared = ServerEventSocket()

    enum State: Equatable {
        case idle, connecting, connected, waitingToReconnect, suspended
    }

    /// For diagnostics; nothing in the UI depends on it yet.
    private(set) var state: State = .idle

    @ObservationIgnored private weak var player: PlayerViewModel?
    @ObservationIgnored private weak var library: LibraryViewModel?
    /// `start` was called and `stop` wasn't.
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var webSocket: URLSessionWebSocketTask?
    /// Bumped on every (re)start so a superseded loop can tell it's stale.
    @ObservationIgnored private var generation = 0
    /// Session ids this device has played under recently — an event carrying one of them
    /// is our own sync echoing back. `AudioPlayerService` keeps only the current session,
    /// so this samples it on every event and heartbeat; a session's own `close` event
    /// (sent after the player has already dropped it) is still recognised because its
    /// periodic syncs were seen first.
    @ObservationIgnored private var ownSessionIds: [String] = []
    @ObservationIgnored private var lastHeardAt = Date()
    @ObservationIgnored private var heartbeatTimeout: TimeInterval = 45
    @ObservationIgnored private var consecutiveAuthFailures = 0
    @ObservationIgnored private var hasEverAuthenticated = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .shelfheadAccountChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ServerEventSocket.shared.restartIfWanted(reason: "account changed") }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ServerEventSocket.shared.suspendIfIdleInBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ServerEventSocket.shared.resumeFromForeground() }
        })
        NetworkMonitor.shared.addConnectivityRestoredObserver {
            Task { @MainActor in ServerEventSocket.shared.connectivityRestored() }
        }
    }

    // MARK: Public control

    /// Starts (or keeps) the socket for the active account. Idempotent: calling it again
    /// while a connection loop is running only refreshes the view-model references.
    func start(player: PlayerViewModel, library: LibraryViewModel) {
        self.player = player
        self.library = library
        wanted = true
        guard loopTask == nil else { return }
        launchLoop()
    }

    /// Closes the socket and stops reconnecting until the next `start`.
    func stop() {
        wanted = false
        tearDown(newState: .idle)
    }

    // MARK: Lifecycle hooks

    private func restartIfWanted(reason: String) {
        guard wanted else { return }
        ShelfLog.info(.sync, "Server events: restarting (\(reason))")
        tearDown(newState: .idle)
        ownSessionIds.removeAll()
        hasEverAuthenticated = false
        consecutiveAuthFailures = 0
        launchLoop()
    }

    private func suspendIfIdleInBackground() {
        guard wanted, state != .suspended,
              UIApplication.shared.applicationState == .background,
              !AudioPlayerService.shared.isPlaying else { return }
        ShelfLog.debug(.sync, "Server events: suspended in background")
        tearDown(newState: .suspended)
    }

    private func resumeFromForeground() {
        guard wanted else { return }
        // A parked socket (suspended, or given up after repeated auth failures) gets a
        // fresh start; a healthy or already-retrying loop is left alone.
        if loopTask == nil {
            consecutiveAuthFailures = 0
            launchLoop()
        }
    }

    /// Batch 433: the saved sign-in was restored from the Keychain (`AuthViewModel.checkExistingSession`).
    /// On a cold launch `start` runs in `ShelfHeadApp.init`, before that restore, so its first attempt
    /// finds no account and parks ("no signed-in account; not connecting"). A restore posts no
    /// `.shelfheadAccountChanged` (it isn't a change), so without this live sync waited for the next
    /// foreground. Same rule as `resumeFromForeground`: only a parked loop is relaunched.
    func credentialsRestored() {
        guard wanted, loopTask == nil else { return }
        consecutiveAuthFailures = 0
        launchLoop()
    }

    private func connectivityRestored() {
        // Only cut a backoff wait short — a live connection doesn't need a kick.
        guard wanted, state == .waitingToReconnect else { return }
        tearDown(newState: .idle)
        launchLoop()
    }

    private func tearDown(newState: State) {
        generation &+= 1
        loopTask?.cancel()
        loopTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        state = newState
    }

    private func launchLoop() {
        generation &+= 1
        let gen = generation
        loopTask = Task { [weak self] in await self?.runLoop(generation: gen) }
    }

    // MARK: Connection loop

    private enum Outcome {
        case notConfigured, cancelled, failed, authFailed, droppedAfterAuth
    }

    private func runLoop(generation gen: Int) async {
        var attempt = 0
        while !Task.isCancelled, gen == generation {
            state = .connecting
            let outcome = await connectOnce(generation: gen)
            guard !Task.isCancelled, gen == generation else { return }
            switch outcome {
            case .notConfigured:
                ShelfLog.debug(.sync, "Server events: no signed-in account; not connecting")
                state = .idle
                loopTask = nil
                return
            case .cancelled:
                return
            case .droppedAfterAuth:
                // It was healthy; start the backoff over.
                attempt = 0
            case .authFailed:
                consecutiveAuthFailures += 1
                if consecutiveAuthFailures >= 3 {
                    ShelfLog.error(.sync, "Server events: authentication refused 3 times; pausing until next foreground")
                    state = .idle
                    loopTask = nil
                    return
                }
                // Once per streak, force a token refresh: the access token we sent may
                // have expired between the API's last call and this connection.
                if consecutiveAuthFailures == 1 {
                    await AudiobookshelfAPI.shared.ensureFreshAccessToken(force: true)
                }
                attempt += 1
            case .failed:
                attempt += 1
            }
            if state != .suspended { state = .waitingToReconnect }
            let delay = ReconnectBackoff.delay(attempt: attempt, jitter: Double.random(in: 0...1))
            ShelfLog.debug(.sync, "Server events: reconnecting in \(Int(delay))s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    /// One connection, from upgrade to drop. Every early exit closes the task.
    private func connectOnce(generation gen: Int) async -> Outcome {
        guard let socketRequest = await AudiobookshelfAPI.shared.serverEventSocketRequest() else {
            return .notConfigured
        }
        let token = socketRequest.accessToken
        guard !Task.isCancelled, gen == generation else { return .cancelled }
        let connectedServer = await AudiobookshelfAPI.shared.serverURL
        let task = urlSession.webSocketTask(with: socketRequest.request)
        // ABS events are small, but a library-wide `items_updated` can carry many
        // expanded items; past this limit `receive` fails and we'd reconnect in a loop.
        task.maximumMessageSize = 16 * 1024 * 1024
        webSocket = task
        task.resume()

        heartbeatTimeout = 45          // until the server's `open` packet gives its interval
        lastHeardAt = Date()
        var authenticated = false
        // Engine.IO v4: no server ping within pingInterval + pingTimeout means the
        // connection is dead even if the OS hasn't noticed (a NAT drop, a sleeping proxy).
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.webSocket === task else { return }
                if Date().timeIntervalSince(self.lastHeardAt) > self.heartbeatTimeout {
                    ShelfLog.debug(.sync, "Server events: heartbeat missed; closing")
                    task.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            task.cancel(with: .goingAway, reason: nil)
            if webSocket === task { webSocket = nil }
        }

        do {
            while !Task.isCancelled, gen == generation {
                let message = try await task.receive()
                guard !Task.isCancelled, gen == generation else { return .cancelled }   // Review 5 Low (socket)
                lastHeardAt = Date()
                guard case .string(let frame) = message, let packet = EngineIOPacket.parse(frame) else { continue }
                switch packet {
                case .open(let handshake):
                    heartbeatTimeout = Double(handshake.pingInterval + handshake.pingTimeout) / 1000 + 5
                    try await task.send(.string(SocketIOPacket.connectFrame))
                case .ping(let payload):
                    try await task.send(.string(EngineIOPacket.pong(payload).encoded))
                    noteOwnSession()
                    // The heartbeat doubles as a cheap periodic check: the account went
                    // away under us, or playback paused while we're in the background.
                    let api = AudiobookshelfAPI.shared
                    let stillConfigured = await api.isConfigured
                    let currentServer = await api.serverURL
                    if !stillConfigured || currentServer != connectedServer {
                        return .notConfigured
                    }
                    if UIApplication.shared.applicationState == .background, !AudioPlayerService.shared.isPlaying {
                        suspendIfIdleInBackground()
                        return .cancelled
                    }
                case .close:
                    return authenticated ? .droppedAfterAuth : .failed
                case .message(let body):
                    guard let sio = SocketIOPacket.parse(body) else { continue }
                    switch sio {
                    case .connect:
                        guard let frame = SocketIOPacket.eventFrame(name: "auth", argument: token) else { return .failed }
                        try await task.send(.string(frame))
                    case .connectError(let message):
                        ShelfLog.error(.sync, "Server events: connect refused (\(message ?? "no reason"))")
                        return .failed
                    case .disconnect:
                        return authenticated ? .droppedAfterAuth : .failed
                    case .event(let name, let payload):
                        switch name {
                        case "init":
                            let isReconnect = hasEverAuthenticated
                            authenticated = true
                            hasEverAuthenticated = true
                            consecutiveAuthFailures = 0
                            state = .connected
                            ShelfLog.info(.sync, "Server events: connected")
                            // Events sent while we were disconnected are gone; one
                            // progress fetch catches up. Not on the first connect —
                            // launch already loads progress.
                            if isReconnect, let library {
                                Task { await library.loadUserProgress() }
                            }
                        case "auth_failed":
                            let reason = payload.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["message"] as? String
                            ShelfLog.error(.sync, "Server events: auth_failed (\(reason ?? "no reason"))")
                            return .authFailed
                        case "user_item_progress_updated":
                            if let payload { handleProgress(payload) }
                        case "user_updated":
                            if let payload { handleUserUpdated(payload) }
                        default:
                            break
                        }
                    case .ignored:
                        break
                    }
                case .pong, .upgrade, .noop:
                    break
                }
            }
            return .cancelled
        } catch {
            guard !Task.isCancelled, gen == generation else { return .cancelled }
            let status = (task.response as? HTTPURLResponse)?.statusCode
            ShelfLog.debug(.sync, "Server events: connection ended (\(status.map { "HTTP \($0)" } ?? error.localizedDescription))")
            return authenticated ? .droppedAfterAuth : .failed
        }
    }

    // MARK: Event handling

    private func noteOwnSession() {
        guard let id = AudioPlayerService.shared.currentSession?.id, !id.isEmpty else { return }
        if let index = ownSessionIds.firstIndex(of: id) { ownSessionIds.remove(at: index) }
        ownSessionIds.append(id)
        if ownSessionIds.count > 16 { ownSessionIds.removeFirst(ownSessionIds.count - 16) }
    }

    private func handleProgress(_ payload: Data) {
        noteOwnSession()
        guard let event = try? JSONDecoder().decode(RemoteProgressEvent.self, from: payload) else {
            ShelfLog.debug(.sync, "Server events: unreadable user_item_progress_updated payload")
            return
        }
        let own = Set(ownSessionIds)
        // Our own syncs are already reflected locally; skipping them also keeps the
        // library from re-rendering every sync interval while this device plays.
        guard !RemoteProgressDecision.isOwnEcho(eventSessionId: event.sessionId, ownSessionIds: own) else { return }
        library?.applyRemoteProgress(event.data)
        if let action = player?.applyRemoteProgress(event.data, sessionId: event.sessionId, ownSessionIds: own),
           case .moveTo(let time) = action {
            ShelfLog.info(.sync, "Server events: moved paused player to \(Int(time))s from another device")
        }
    }

    /// Batch 409: `user_updated` — web-app "mark finished", manual edits and "reset
    /// progress" arrive as the user's full progress list. Applies only to the library's
    /// progress maps; the player keeps its own `user_item_progress_updated` rules. The
    /// payload contains the user's token, so only counts are ever logged.
    private func handleUserUpdated(_ payload: Data) {
        guard let event = try? JSONDecoder().decode(RemoteUserUpdatedEvent.self, from: payload),
              let records = event.mediaProgress else { return }
        let applied = library?.applyRemoteProgressSnapshot(records, allRecordsDecoded: !event.hadUndecodableRecords)
        ShelfLog.debug(.sync, "Server events: user_updated with \(records.count) progress records, \(applied ?? 0) changes applied")
    }
}
