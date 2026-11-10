import Foundation
import CryptoKit
import CloudKit

/// Batch 453: the pure data model for Household (CloudKit sharing). Plain `Codable` value types, no I/O,
/// no CloudKit. `HouseholdRecordMapper` turns them into `CKRecord`s; `HouseholdSnapshot` is the merged
/// local copy. Everything here is `nonisolated` so tests and the sync engine can use it off the main actor.

// MARK: - Server fingerprint

/// Same server ⇒ same fingerprint across members. SHA-256 of the normalised host (lowercased, no scheme, no
/// path, no trailing slash, default ports 80/443 dropped), first 16 hex characters. Username is deliberately
/// not part of it: the point is "same server", so members can open each other's books.
nonisolated enum ServerFingerprint {
    /// `https://Books.Example.com:443/` and `books.example.com` normalise to the same string.
    static func normalizedHost(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var result = host.lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        if let port = components.port, port != 80, port != 443 {
            result += ":\(port)"
        }
        return result
    }

    /// 16 hex characters, or "" when `serverURL` has no usable host.
    static func fingerprint(forServerURL serverURL: String) -> String {
        let host = normalizedHost(serverURL)
        guard !host.isEmpty else { return "" }
        return hexDigest(host, length: 16)
    }

    static func hexDigest(_ text: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}

// MARK: - Records

nonisolated struct HouseholdMember: Codable, Equatable, Identifiable, Sendable {
    /// The CKRecord name. Built from the member's iCloud user record name (`makeId`), so a reinstall keeps
    /// the same member.
    var id: String
    var displayName: String
    /// An SF Symbol name.
    var avatarSymbol: String
    /// Index into the app's six avatar token colours.
    var avatarColorIndex: Int
    var serverFingerprint: String
    var updatedAt: Date

    static func makeId(userRecordName: String) -> String {
        "member-" + userRecordName.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}

/// Opt-in (Batch 454): what a member is listening to now. One record per member.
nonisolated struct HouseholdNowListening: Codable, Equatable, Identifiable, Sendable {
    var memberId: String
    var libraryItemId: String
    var serverFingerprint: String
    var title: String
    var author: String
    /// 0...1
    var progress: Double
    var updatedAt: Date
    var id: String { memberId }
}

nonisolated struct HouseholdRecommendation: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var fromMemberId: String
    var toMemberIds: [String]
    var libraryItemId: String
    var serverFingerprint: String
    var title: String
    var author: String
    var note: String
    var createdAt: Date

    static func makeId() -> String { "rec-" + UUID().uuidString }
}

/// A book club: one per book, keyed so every member who opens the same book lands on the same record.
nonisolated struct HouseholdClub: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var libraryItemId: String?
    var title: String
    var author: String
    var serverFingerprint: String
    var goalText: String?
    var goalSeconds: Double?
    var goalDate: Date?
    var createdBy: String
    var updatedAt: Date

    /// Same book on the same server ⇒ same club id. Without an item id (a book matched by name only) the
    /// key is a hash of the lowercased title and author.
    static func makeId(serverFingerprint: String, libraryItemId: String?, title: String, author: String) -> String {
        if let libraryItemId, !libraryItemId.isEmpty, !serverFingerprint.isEmpty {
            return "club-\(serverFingerprint)-\(libraryItemId)"
        }
        return sharedId(title: title, author: author)
    }

    /// Batch 482: the id every member lands on for a book, whatever server they use: a hash of the lowercased
    /// title and author. New clubs and posts use this. Clubs made before Batch 482 on a same-server book keep the
    /// server-keyed `makeId` id, and Book Club reads both (`BookClubIds`).
    static func sharedId(title: String, author: String) -> String {
        let key = (title + "|" + author).lowercased()
        return "club-t-" + ServerFingerprint.hexDigest(key, length: 16)
    }
}

nonisolated struct HouseholdClubPost: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var clubId: String
    var memberId: String
    var positionSeconds: Double
    var text: String
    var createdAt: Date

    static func makeId() -> String { "post-" + UUID().uuidString }
}

// MARK: - One record, any type

/// Any of the five record types, so the store and sync engine can treat them uniformly.
nonisolated enum HouseholdRecord: Equatable, Sendable {
    case member(HouseholdMember)
    case nowListening(HouseholdNowListening)
    case recommendation(HouseholdRecommendation)
    case club(HouseholdClub)
    case clubPost(HouseholdClubPost)

    /// The CKRecord name, unique within the zone.
    var recordName: String {
        switch self {
        case .member(let m): return m.id
        case .nowListening(let n): return HouseholdRecord.nowListeningRecordName(memberId: n.memberId)
        case .recommendation(let r): return r.id
        case .club(let c): return c.id
        case .clubPost(let p): return p.id
        }
    }

    /// `updatedAt` for mutable records, `createdAt` for write-once ones. The merge rule compares this.
    var stamp: Date {
        switch self {
        case .member(let m): return m.updatedAt
        case .nowListening(let n): return n.updatedAt
        case .recommendation(let r): return r.createdAt
        case .club(let c): return c.updatedAt
        case .clubPost(let p): return p.createdAt
        }
    }

    static func nowListeningRecordName(memberId: String) -> String { "nl-" + memberId }
}

// MARK: - Snapshot and merge

/// The merged local copy of everything in the household zone. Newest stamp wins per record id; a tie keeps
/// what is already here, so applying the same record twice is a no-op.
nonisolated struct HouseholdSnapshot: Codable, Equatable, Sendable {
    var members: [String: HouseholdMember] = [:]
    /// Keyed by member id.
    var nowListening: [String: HouseholdNowListening] = [:]
    var recommendations: [String: HouseholdRecommendation] = [:]
    var clubs: [String: HouseholdClub] = [:]
    var posts: [String: HouseholdClubPost] = [:]

    var isEmpty: Bool {
        members.isEmpty && nowListening.isEmpty && recommendations.isEmpty && clubs.isEmpty && posts.isEmpty
    }

    /// Applies `record` when it is newer than what is stored (or new). Returns true when the snapshot changed.
    @discardableResult
    mutating func apply(_ record: HouseholdRecord) -> Bool {
        switch record {
        case .member(let m):
            return Self.merge(m, into: &members, key: m.id, stamp: \.updatedAt)
        case .nowListening(let n):
            return Self.merge(n, into: &nowListening, key: n.memberId, stamp: \.updatedAt)
        case .recommendation(let r):
            return Self.merge(r, into: &recommendations, key: r.id, stamp: \.createdAt)
        case .club(let c):
            return Self.merge(c, into: &clubs, key: c.id, stamp: \.updatedAt)
        case .clubPost(let p):
            return Self.merge(p, into: &posts, key: p.id, stamp: \.createdAt)
        }
    }

    /// Unconditional write for the user's own edit: the clock on this device is the authority for what the
    /// user just did, so it must not lose to a stamp that skew made look newer.
    mutating func set(_ record: HouseholdRecord) {
        switch record {
        case .member(let m): members[m.id] = m
        case .nowListening(let n): nowListening[n.memberId] = n
        case .recommendation(let r): recommendations[r.id] = r
        case .club(let c): clubs[c.id] = c
        case .clubPost(let p): posts[p.id] = p
        }
    }

    private static func merge<T: Equatable>(_ incoming: T, into dict: inout [String: T], key: String,
                                            stamp: KeyPath<T, Date>) -> Bool {
        if let existing = dict[key] {
            guard incoming[keyPath: stamp] > existing[keyPath: stamp] else { return false }
        }
        dict[key] = incoming
        return true
    }

    /// Removes the record a CloudKit deletion names. Returns true when something was removed.
    @discardableResult
    mutating func remove(recordType: String, recordName: String) -> Bool {
        switch recordType {
        case HouseholdRecordMapper.RecordType.member:
            return members.removeValue(forKey: recordName) != nil
        case HouseholdRecordMapper.RecordType.nowListening:
            let prefix = "nl-"
            let key = recordName.hasPrefix(prefix) ? String(recordName.dropFirst(prefix.count)) : recordName
            return nowListening.removeValue(forKey: key) != nil
        case HouseholdRecordMapper.RecordType.recommendation:
            return recommendations.removeValue(forKey: recordName) != nil
        case HouseholdRecordMapper.RecordType.club:
            return clubs.removeValue(forKey: recordName) != nil
        case HouseholdRecordMapper.RecordType.clubPost:
            return posts.removeValue(forKey: recordName) != nil
        default:
            return false
        }
    }

    /// The record stored under `recordName`, whichever type it is. Used to build a `CKRecord` to send.
    func record(named recordName: String) -> HouseholdRecord? {
        if let m = members[recordName] { return .member(m) }
        if let r = recommendations[recordName] { return .recommendation(r) }
        if let c = clubs[recordName] { return .club(c) }
        if let p = posts[recordName] { return .clubPost(p) }
        if recordName.hasPrefix("nl-"), let n = nowListening[String(recordName.dropFirst(3))] { return .nowListening(n) }
        return nil
    }

    // MARK: Queries (454/455 build on these)

    var membersSorted: [HouseholdMember] {
        members.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Recommendations addressed to `memberId`, newest first.
    func recommendations(for memberId: String) -> [HouseholdRecommendation] {
        recommendations.values.filter { $0.toMemberIds.contains(memberId) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// A club's posts in book order (position, then time).
    func posts(inClub clubId: String) -> [HouseholdClubPost] {
        posts.values.filter { $0.clubId == clubId }
            .sorted { ($0.positionSeconds, $0.createdAt) < ($1.positionSeconds, $1.createdAt) }
    }
}

// MARK: - Membership and leaving (Batch 481)

/// Who still belongs to the household, judged from the share's participants.
nonisolated enum HouseholdMembership {
    /// User record names of the owner and everyone who has accepted. `CKCurrentUserDefaultName` stands for the
    /// current user (CloudKit reports the owner's own id that way on the owner's devices).
    static func participantRecordNames(_ share: CKShare) -> [String] {
        share.participants
            .filter { $0.role == .owner || $0.acceptanceStatus == .accepted }
            .compactMap { $0.userIdentity.userRecordID?.recordName }
    }

    /// `members` minus anyone not on the share. Falls back to everyone when there's no share copy yet, or when
    /// the mapping doesn't recognise you (a guard against hiding the whole household if ids ever differ).
    static func current(members: [HouseholdMember], participantRecordNames: [String]?,
                        myMemberId: String?) -> [HouseholdMember] {
        guard let participantRecordNames, let myMemberId else { return members }
        let ids = Set(participantRecordNames.map { name in
            name == CKCurrentUserDefaultName ? myMemberId : HouseholdMember.makeId(userRecordName: name)
        })
        guard ids.contains(myMemberId) else { return members }
        return members.filter { ids.contains($0.id) }
    }
}

/// What a member removes from the household's zone when they leave.
nonisolated enum HouseholdLeave {
    /// Your profile, your Now Listening, every recommendation you sent and every club post you wrote. Clubs stay:
    /// other people's posts hang off them.
    static func recordNamesToDelete(snapshot: HouseholdSnapshot, myMemberId: String) -> [String] {
        var names = [myMemberId, HouseholdRecord.nowListeningRecordName(memberId: myMemberId)]
        names += snapshot.recommendations.values.filter { $0.fromMemberId == myMemberId }.map(\.id).sorted()
        names += snapshot.posts.values.filter { $0.memberId == myMemberId }.map(\.id).sorted()
        return names
    }
}

/// Batch 482: which club records Book Club reads and writes for a book. Writes go to the shared (title and
/// author) id so members on other servers join the same club. Reads also take the older server-keyed id, so
/// clubs and posts made before Batch 482 still show.
nonisolated struct BookClubIds: Equatable {
    let shared: String
    let legacy: String

    init(serverFingerprint: String, libraryItemId: String, title: String, author: String) {
        shared = HouseholdClub.sharedId(title: title, author: author)
        legacy = HouseholdClub.makeId(serverFingerprint: serverFingerprint, libraryItemId: libraryItemId,
                                      title: title, author: author)
    }

    /// The club to show: the shared one once it exists, else an older server-keyed one.
    func club(in snapshot: HouseholdSnapshot) -> HouseholdClub? {
        snapshot.clubs[shared] ?? snapshot.clubs[legacy]
    }

    /// Posts from both ids, in book order.
    func posts(in snapshot: HouseholdSnapshot) -> [HouseholdClubPost] {
        let ids: Set<String> = [shared, legacy]
        return snapshot.posts.values.filter { ids.contains($0.clubId) }
            .sorted { ($0.positionSeconds, $0.createdAt) < ($1.positionSeconds, $1.createdAt) }
    }
}
