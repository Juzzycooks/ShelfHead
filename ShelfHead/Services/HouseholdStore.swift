import Foundation
import CloudKit
import CryptoKit
import UIKit
import SwiftUI

// MARK: - Settings

extension SettingsKeys {
    /// Batch 453: how you appear to the household. Local only; copied into your `Member` record.
    static let householdDisplayName = "settings_householdDisplayName"
    static let householdAvatarSymbol = "settings_householdAvatarSymbol"
    static let householdAvatarColor = "settings_householdAvatarColor"
}

extension SettingsStore {
    static var householdDisplayName: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.householdDisplayName) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.householdDisplayName) }
    }
    static var householdAvatarSymbol: String {
        get { UserDefaults.standard.string(forKey: SettingsKeys.householdAvatarSymbol) ?? HouseholdAvatar.symbols[0] }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.householdAvatarSymbol) }
    }
    static var householdAvatarColor: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKeys.householdAvatarColor) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKeys.householdAvatarColor) }
    }
}

/// Batch 453: the avatar choices. Symbols are SF Symbols; colours are indices into the app's token colours
/// (resolved in the view layer, `HouseholdAvatarView`).
nonisolated enum HouseholdAvatar {
    static let symbols = ["book.fill", "headphones", "moon.stars.fill", "leaf.fill", "flame.fill", "pawprint.fill",
                          "star.fill", "heart.fill", "bolt.fill", "cup.and.saucer.fill", "sailboat.fill", "guitars.fill"]
    static let colorCount = 6

    /// Batch 490 (REVIEW 2026-11-11 A2): VoiceOver names for the pictures (was the raw
    /// symbol name) and the colours (was "Colour 1"…"Colour 6"). The colours are app
    /// tokens that follow the chosen accent, so they're named by role, not hue.
    static var symbolNames: [String: String] {
        [
            "book.fill": String(localized: "Book", comment: "Household avatar picture name, read by VoiceOver"),
            "headphones": String(localized: "Headphones", comment: "Household avatar picture name, read by VoiceOver"),
            "moon.stars.fill": String(localized: "Moon and stars", comment: "Avatar picture name, read by VoiceOver"),
            "leaf.fill": String(localized: "Leaf", comment: "Avatar picture name, read by VoiceOver"),
            "flame.fill": String(localized: "Flame", comment: "Household avatar picture name, read by VoiceOver"),
            "pawprint.fill": String(localized: "Paw print", comment: "Avatar picture name, read by VoiceOver"),
            "star.fill": String(localized: "Star", comment: "Avatar picture name, read by VoiceOver"),
            "heart.fill": String(localized: "Heart", comment: "Household avatar picture name, read by VoiceOver"),
            "bolt.fill": String(localized: "Lightning bolt", comment: "Household avatar picture name, read by VoiceOver"),
            "cup.and.saucer.fill": String(localized: "Cup and saucer", comment: "Household avatar picture name, read by VoiceOver"),
            "sailboat.fill": String(localized: "Sailboat", comment: "Household avatar picture name, read by VoiceOver"),
            "guitars.fill": String(localized: "Guitars", comment: "Household avatar picture name, read by VoiceOver"),
        ]
    }

    /// One per colour index, in `HouseholdAvatarView.color(_:)`'s order.
    static var colorNames: [String] {
        [
            String(localized: "Accent", comment: "Household avatar colour name (the app's accent colour), read by VoiceOver"),
            String(localized: "Second accent", comment: "Household avatar colour name (the app's second accent colour), read by VoiceOver"),
            String(localized: "Highlight", comment: "Household avatar colour name (the app's emphasis colour), read by VoiceOver"),
            String(localized: "Deep accent", comment: "Household avatar colour name (a darker accent), read by VoiceOver"),
            String(localized: "Taupe", comment: "Household avatar colour name (the muted brown-grey), read by VoiceOver"),
            String(localized: "Cream", comment: "Household avatar colour name, read by VoiceOver"),
        ]
    }

    static func name(forSymbol symbol: String) -> String {
        symbolNames[symbol] ?? String(localized: "Picture", comment: "Avatar picture with no name, read by VoiceOver")
    }

    static func name(forColorIndex index: Int) -> String {
        colorNames[clampedColor(index)]
    }
    static func clampedColor(_ index: Int) -> Int { min(max(index, 0), colorCount - 1) }
}

// MARK: - Cache

/// The on-disk copy, so the Household page shows something offline. JSON in Application Support.
nonisolated struct HouseholdCache: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case none, owner, member }
    var role: Role = .none
    /// A member's view of the owner's zone (the owner's name is the owner's iCloud user id).
    var sharedZoneName: String?
    var sharedZoneOwner: String?
    var snapshot = HouseholdSnapshot()
    /// Per record name, the server-assigned fields (change tag) so edits update instead of conflict.
    var systemFields: [String: Data] = [:]
    var privateEngineState: Data?
    var sharedEngineState: Data?
    var myMemberId: String?
    /// The archived `CKShare` (owner), for listing participants and re-presenting the invite.
    var shareData: Data?
}

nonisolated enum HouseholdState: Equatable, Sendable {
    case notJoined
    case owner
    case member
    /// iCloud can't be used right now; the string is the user-facing reason.
    case iCloudUnavailable(String)
}

// MARK: - Store

/// Batch 453: the household as the UI and the later batches (454 shelf and recommendations, 455 book club) see
/// it. State, members and records are observable; writes go through `save`/`delete`, which update the local
/// copy at once and queue the change for the sync engine.
///
/// CloudKit is never touched until Household is used (a Settings page opens, a share is accepted, or a
/// household already exists at launch), so a build without the iCloud entitlement runs unchanged.
@MainActor
@Observable
final class HouseholdStore {
    static let shared = HouseholdStore()

    // Observable state
    private(set) var cache: HouseholdCache
    /// Non-nil when iCloud can't be used (signed out, restricted, no entitlement yet).
    private(set) var unavailableReason: String?
    private(set) var isBusy = false
    /// The last problem worth showing, in plain words. Cleared by the next successful action.
    private(set) var lastError: String?
    /// Set when a share is accepted or the household goes away underneath you; the UI can show it once.
    var notice: String?
    private(set) var lastSyncedAt: Date?

    @ObservationIgnored private var privateEngine: HouseholdSyncEngine?
    @ObservationIgnored private var sharedEngine: HouseholdSyncEngine?
    @ObservationIgnored private var _container: CKContainer?
    @ObservationIgnored private var accountObserver: NSObjectProtocol?
    /// The household's zone-wide share once it's saved to iCloud (owner only). Observable so the invite button
    /// can hand it to the share sheet as an existing share instead of asking for a new one.
    private(set) var existingShare: CKShare?

    private init() {
        cache = HouseholdStore.loadCache()
        existingShare = cache.shareData.flatMap(HouseholdStore.share(from:))
    }

    // MARK: Derived state

    var state: HouseholdState {
        if let unavailableReason { return .iCloudUnavailable(unavailableReason) }
        switch cache.role {
        case .none: return .notJoined
        case .owner: return .owner
        case .member: return .member
        }
    }

    var isInHousehold: Bool { cache.role != .none }
    /// Batch 482: Recommend, Book Club and the Home shelf act as this device's iCloud member (the parent), so a
    /// kid profile doesn't get them. Settings › Household stays behind the parent gate as before.
    var isSocialAvailable: Bool { isInHousehold && !KidProfileStore.standard.isKid(AccountStore.currentAccountId) }
    var isOwner: Bool { cache.role == .owner }
    var snapshot: HouseholdSnapshot { cache.snapshot }
    var myMemberId: String? { cache.myMemberId }
    /// Batch 481: members still on the share. Someone the owner removed keeps a `Member` record in the zone
    /// (only they could delete it), so without this they stayed listed and could still be sent recommendations.
    var members: [HouseholdMember] {
        HouseholdMembership.current(members: cache.snapshot.membersSorted,
                                    participantRecordNames: existingShare.map(HouseholdMembership.participantRecordNames),
                                    myMemberId: cache.myMemberId)
    }
    var nowListening: [HouseholdNowListening] {
        cache.snapshot.nowListening.values.sorted { $0.updatedAt > $1.updatedAt }
    }
    var recommendations: [HouseholdRecommendation] {
        cache.snapshot.recommendations.values.sorted { $0.createdAt > $1.createdAt }
    }
    var clubs: [HouseholdClub] { cache.snapshot.clubs.values.sorted { $0.updatedAt > $1.updatedAt } }
    var posts: [HouseholdClubPost] { cache.snapshot.posts.values.sorted { $0.createdAt < $1.createdAt } }
    var me: HouseholdMember? { myMemberId.flatMap { cache.snapshot.members[$0] } }

    // MARK: Container (lazy)

    /// Created on first use only. `nonisolated` so `HouseholdInvite`'s exporter can call it.
    nonisolated static func makeContainer() -> CKContainer {
        CKContainer(identifier: HouseholdRecordMapper.containerIdentifier)
    }

    private var container: CKContainer {
        if let _container { return _container }
        let made = HouseholdStore.makeContainer()
        _container = made
        return made
    }

    private var privateZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: HouseholdRecordMapper.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private var sharedZoneID: CKRecordZone.ID? {
        guard let name = cache.sharedZoneName, let owner = cache.sharedZoneOwner else { return nil }
        return CKRecordZone.ID(zoneName: name, ownerName: owner)
    }

    /// Where this device's own records live: the private zone for the owner, the shared zone for a member.
    private var activeZoneID: CKRecordZone.ID? {
        switch cache.role {
        case .none: return nil
        case .owner: return privateZoneID
        case .member: return sharedZoneID
        }
    }

    private var activeEngine: HouseholdSyncEngine? {
        cache.role == .owner ? privateEngine : (cache.role == .member ? sharedEngine : nil)
    }

    // MARK: Account

    /// True when iCloud can be used; otherwise sets `unavailableReason`. Review Low (Household, 30 October 2026):
    /// the old first check, `FileManager.ubiquityIdentityToken`, reports the iCloud Drive identity and is nil when
    /// iCloud Drive is off even though CloudKit works, so those users were blocked. `CKContainer.accountStatus()`
    /// is the CloudKit-specific answer (its `.noAccount` case covers a signed-out device). The app's entitlements
    /// carry the CloudKit container, so creating the container here is safe.
    @discardableResult
    func checkAccount() async -> Bool {
        do {
            switch try await container.accountStatus() {
            case .available:
                unavailableReason = nil
                return true
            case .noAccount:
                unavailableReason = String(localized: "Sign in to iCloud in Settings to use Household.",
                                           comment: "Household: shown when no iCloud account is signed in on the device")
            case .restricted:
                unavailableReason = String(localized: "iCloud is restricted on this device, so Household isn't available.",
                                           comment: "Household: iCloud restricted by Screen Time or a profile")
            case .couldNotDetermine, .temporarilyUnavailable:
                unavailableReason = String(localized: "iCloud isn't responding right now. Try again in a moment.",
                                           comment: "Household: iCloud account status couldn't be read")
            @unknown default:
                unavailableReason = String(localized: "iCloud isn't available right now.",
                                           comment: "Household: generic iCloud unavailable")
            }
        } catch {
            unavailableReason = String(localized: "iCloud isn't available right now.",
                                       comment: "Household: generic iCloud unavailable")
        }
        return false
    }

    /// Call at launch. Does nothing (and touches no CloudKit) unless a household already exists on this device.
    func resumeIfJoined() {
        guard cache.role != .none else { return }
        Task { await start() }
    }

    /// Call when the Household page opens: checks iCloud, starts the engine for an existing household, syncs.
    func start() async {
        guard await checkAccount() else { return }
        observeAccountChanges()
        if cache.role == .none { await discoverExistingHousehold() }
        guard cache.role != .none else { return }
        startEngineIfNeeded()
        await refresh()
        if cache.role == .owner { await reloadShareFromServer() }
    }

    /// Batch 481: the household lives in iCloud, but the role is only in this device's cache, so the owner's
    /// second iPhone (or a reinstall) used to offer "Create a Household" and a member had to tap the invite again.
    /// Looks for this account's own `Household` zone, then for one shared with it. Quiet on failure: the page
    /// then just offers Create, as before.
    private func discoverExistingHousehold() async {
        do {
            _ = try await container.privateCloudDatabase.recordZone(for: privateZoneID)
            _ = try await ensureMyMemberId()
            cache.role = .owner
            persist()
            return
        } catch let error as CKError where [.zoneNotFound, .unknownItem, .partialFailure].contains(error.code) {
            // Not the owner of one; look for a shared one below.
        } catch {
            return
        }
        do {
            let zones = try await container.sharedCloudDatabase.allRecordZones()
            guard let zone = zones.first(where: { $0.zoneID.zoneName == HouseholdRecordMapper.zoneName }) else { return }
            _ = try await ensureMyMemberId()
            cache.role = .member
            cache.sharedZoneName = zone.zoneID.zoneName
            cache.sharedZoneOwner = zone.zoneID.ownerName
            persist()
        } catch {
            return
        }
    }

    private func observeAccountChanges() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil,
                                                                 queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.accountDidChange(signedOut: false) }
        }
    }

    func accountDidChange(signedOut: Bool) async {
        if signedOut {
            // The household belongs to the other account: forget it locally rather than show strangers' data.
            await resetLocal(notice: String(localized: "iCloud account changed, so Household was cleared on this device.",
                                            comment: "Household: shown after the iCloud account changed"))
            // Batch 481: the member id is derived from the iCloud user, so the next account must make its own.
            cache.myMemberId = nil
            persist()
            unavailableReason = nil
        }
        _ = await checkAccount()
    }

    // MARK: Create / accept / leave

    /// Makes the household: this iCloud account owns a private `Household` zone, ready to be shared.
    func createHousehold() async {
        guard cache.role == .none, await checkAccount() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await ensureMyMemberId()
            let zone = CKRecordZone(zoneID: privateZoneID)
            _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
            cache.role = .owner
            persist()
            lastError = nil
            observeAccountChanges()
            startEngineIfNeeded()
            publishMyProfile()
        } catch {
            lastError = HouseholdStore.describe(error)
        }
    }

    /// The zone-wide share for `ShareLink`. Reuses the one already made; creates and saves it the first time.
    func prepareShare() async throws -> CKShare {
        // A zone holds one zone-wide share, so saving a second one fails. Use the server's if there is one
        // (the local copy can be missing even though a share was saved, e.g. after a reinstall).
        if let share = try await fetchServerShare() {
            remember(share)
            return share
        }
        let database = container.privateCloudDatabase
        let share = CKShare(recordZoneID: privateZoneID)
        share[CKShare.SystemFieldKey.title] = String(localized: "ShelfHead Household",
                                                     comment: "Household: the title of the iCloud share") as CKRecordValue
        share.publicPermission = .none
        let result = try await database.modifyRecords(saving: [share], deleting: [])
        guard case .success(let saved)? = result.saveResults[share.recordID], let saved = saved as? CKShare else {
            throw CKError(.internalError)
        }
        remember(saved)
        return saved
    }

    /// The zone-wide share on the server, or nil when none has been saved yet.
    private func fetchServerShare() async throws -> CKShare? {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: privateZoneID)
        do {
            return try await container.privateCloudDatabase.record(for: id) as? CKShare
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Owner: brings `existingShare` in line with the server, so the invite button uses the right share.
    private func reloadShareFromServer() async {
        do {
            if let share = try await fetchServerShare() {
                remember(share)
            } else if existingShare != nil {
                existingShare = nil
                cache.shareData = nil
                persist()
            }
        } catch {
            // Offline or similar: keep the local copy; the invite path checks the server again.
        }
    }

    private func remember(_ share: CKShare) {
        existingShare = share
        cache.shareData = HouseholdStore.archive(share)
        persist()
    }

    /// Joins the household an invitation points at. Refuses when already in one.
    func acceptShare(_ metadata: CKShare.Metadata) async {
        guard cache.role == .none else {
            notice = String(localized: "You're already in a household. Leave it first to join another.",
                            comment: "Household: shown when accepting an invite while already in a household")
            return
        }
        guard await checkAccount() else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await ensureMyMemberId()
            _ = try await container.accept(metadata)
            let zoneID = metadata.share.recordID.zoneID
            cache.role = .member
            cache.sharedZoneName = zoneID.zoneName
            cache.sharedZoneOwner = zoneID.ownerName
            persist()
            lastError = nil
            notice = String(localized: "You joined the household.", comment: "Household: shown after accepting an invite")
            observeAccountChanges()
            startEngineIfNeeded()
            publishMyProfile()
            await refresh()
        } catch {
            lastError = HouseholdStore.describe(error)
        }
    }

    /// Owner: deletes the household for everyone (the zone and its share). Member: removes yourself and your
    /// records. Either way the local copy is cleared.
    func leave() async {
        guard cache.role != .none else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            switch cache.role {
            case .owner:
                _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [privateZoneID])
            case .member:
                if let zoneID = sharedZoneID {
                    let database = container.sharedCloudDatabase
                    if let myId = myMemberId {
                        // Batch 481: the dialog promises your posts and recommendations go too, not just your profile.
                        let names = HouseholdLeave.recordNamesToDelete(snapshot: cache.snapshot, myMemberId: myId)
                        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
                        // CloudKit takes at most 400 items per modify request.
                        for start in stride(from: 0, to: ids.count, by: 400) {
                            let chunk = Array(ids[start..<min(start + 400, ids.count)])
                            _ = try? await database.modifyRecords(saving: [], deleting: chunk)
                        }
                    }
                    // Deleting a shared zone from the shared database removes you from its share.
                    _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
                }
            case .none:
                break
            }
            await resetLocal(notice: nil)
            lastError = nil
        } catch {
            lastError = HouseholdStore.describe(error)
        }
    }

    private func resetLocal(notice newNotice: String?) async {
        let engines = [privateEngine, sharedEngine].compactMap { $0 }
        privateEngine = nil
        sharedEngine = nil
        existingShare = nil
        for engine in engines { await engine.cancel() }
        let myId = cache.myMemberId
        cache = HouseholdCache()
        cache.myMemberId = myId
        persist()
        if let newNotice { notice = newNotice }
    }

    // MARK: Reading and writing records

    /// Writes one of your own records: local copy now, sync engine soon. Silent no-op when not in a household.
    func save(_ record: HouseholdRecord) {
        guard let zoneID = activeZoneID else { return }
        cache.snapshot.set(record)
        persist()
        activeEngine?.queueSave(record.recordName, zoneID: zoneID)
    }

    func delete(_ record: HouseholdRecord) {
        guard let zoneID = activeZoneID else { return }
        _ = cache.snapshot.remove(recordType: HouseholdRecordMapper.recordType(for: record),
                                  recordName: record.recordName)
        cache.systemFields[record.recordName] = nil
        persist()
        activeEngine?.queueDelete(record.recordName, zoneID: zoneID)
    }

    /// Pulls server changes and pushes pending ones.
    func refresh() async {
        guard cache.role != .none, let engine = activeEngine else { return }
        do {
            try await engine.syncNow()
            lastSyncedAt = Date()
            lastError = nil
        } catch {
            lastError = HouseholdStore.describe(error)
        }
    }

    /// Your `Member` record from the Settings values and the active server. Call after editing the profile.
    func publishMyProfile() {
        guard let id = cache.myMemberId, cache.role != .none else { return }
        var name = SettingsStore.householdDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = String(localized: "New member", comment: "Household: name shown before someone sets theirs")
        }
        let member = HouseholdMember(id: id, displayName: name,
                                     avatarSymbol: SettingsStore.householdAvatarSymbol,
                                     avatarColorIndex: HouseholdAvatar.clampedColor(SettingsStore.householdAvatarColor),
                                     serverFingerprint: ServerFingerprint.fingerprint(forServerURL: AuthStore.shared.serverURL),
                                     updatedAt: Date())
        save(.member(member))
    }

    // MARK: Engine plumbing

    private func startEngineIfNeeded() {
        switch cache.role {
        case .owner where privateEngine == nil:
            privateEngine = HouseholdSyncEngine(container: container, scope: .privateDatabase,
                                                stateData: cache.privateEngineState, store: self)
        case .member where sharedEngine == nil:
            sharedEngine = HouseholdSyncEngine(container: container, scope: .sharedDatabase,
                                               stateData: cache.sharedEngineState, store: self)
        default:
            return
        }
        // CKSyncEngine subscribes to changes itself; the app must be registered for remote notifications to hear them.
        UIApplication.shared.registerForRemoteNotifications()
    }

    private func ensureMyMemberId() async throws -> String {
        if let id = cache.myMemberId { return id }
        let userID = try await container.userRecordID()
        let id = HouseholdMember.makeId(userRecordName: userID.recordName)
        cache.myMemberId = id
        persist()
        return id
    }

    // MARK: Engine callbacks (called by `HouseholdSyncEngine`)

    func engineStateDidChange(_ scope: HouseholdSyncEngine.Scope, data: Data) {
        switch scope {
        case .privateDatabase: cache.privateEngineState = data
        case .sharedDatabase: cache.sharedEngineState = data
        }
        persist()
    }

    func fetchedZones(_ scope: HouseholdSyncEngine.Scope, modified: [CKRecordZone.ID], deleted: [CKRecordZone.ID]) async {
        let name = HouseholdRecordMapper.zoneName
        switch scope {
        case .sharedDatabase:
            if cache.role == .member, cache.sharedZoneName == nil,
               let zone = modified.first(where: { $0.zoneName == name }) {
                cache.sharedZoneName = zone.zoneName
                cache.sharedZoneOwner = zone.ownerName
                persist()
            }
            if cache.role == .member, deleted.contains(where: { $0.zoneName == name }) {
                await resetLocal(notice: String(localized: "The household was deleted, or you were removed from it.",
                                                comment: "Household: shown when the shared zone disappears"))
            }
        case .privateDatabase:
            if cache.role == .owner, deleted.contains(where: { $0.zoneName == name }) {
                await resetLocal(notice: String(localized: "The household was deleted from iCloud.",
                                                comment: "Household: shown when the owner's zone disappears"))
            }
        }
    }

    func fetchedRecords(_ scope: HouseholdSyncEngine.Scope, items: [HouseholdSyncEngine.FetchedItem],
                        shareData: Data?, deleted: [(String, String)]) async {
        // Batch 454: ids already here, so the inbox can tell which recommendations just arrived.
        let knownRecommendations = Set(cache.snapshot.recommendations.keys)
        for fetched in items {
            cache.snapshot.apply(fetched.item)
            cache.systemFields[fetched.item.recordName] = fetched.systemFields
        }
        if let shareData {
            cache.shareData = shareData
            existingShare = HouseholdStore.share(from: shareData)
        }
        for (name, type) in deleted {
            if type == CKRecord.SystemType.share {
                if cache.role == .member {
                    await resetLocal(notice: String(localized: "You were removed from the household.",
                                                    comment: "Household: shown when your access is revoked"))
                    return
                }
                cache.shareData = nil
                existingShare = nil
            } else {
                cache.snapshot.remove(recordType: type, recordName: name)
                cache.systemFields[name] = nil
            }
        }
        lastSyncedAt = Date()
        persist()
        HouseholdInbox.shared.handleFetched(snapshot: cache.snapshot, myMemberId: cache.myMemberId,
                                            knownBefore: knownRecommendations)
    }

    func recordsWereSent(_ fields: [(String, Data)]) {
        for (name, data) in fields { cache.systemFields[name] = data }
        persist()
    }

    /// The server already had a different version. Keep whichever is newer; re-send ours when it wins.
    func conflictResolved(recordName: String, zoneID: CKRecordZone.ID, server: HouseholdRecord?, systemFields: Data) {
        cache.systemFields[recordName] = systemFields
        if let server { cache.snapshot.apply(server) }
        persist()
        if cache.snapshot.record(named: recordName) != server {
            activeEngine?.queueSave(recordName, zoneID: zoneID)
        }
    }

    func recordWasMissingOnServer(recordName: String) {
        cache.systemFields[recordName] = nil
        persist()
    }

    func sendFailed(_ error: CKError) {
        lastError = error.code == .permissionFailure
            ? String(localized: "You can view this household but not change it.",
                     comment: "Household: a read-only participant tried to write")
            : HouseholdStore.describe(error)
    }

    /// The `CKRecord` to send for a pending save, built from the local copy plus the saved system fields.
    func ckRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let item = cache.snapshot.record(named: id.recordName) else { return nil }
        let base = cache.systemFields[id.recordName].flatMap { HouseholdRecordMapper.record(fromSystemFields: $0) }
        return HouseholdRecordMapper.ckRecord(for: item, zoneID: id.zoneID, base: base)
    }

    // MARK: Disk

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Household", isDirectory: true).appendingPathComponent("cache.json")
    }

    private static func loadCache() -> HouseholdCache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(HouseholdCache.self, from: data) else { return HouseholdCache() }
        return cache
    }

    private func persist() {
        let url = HouseholdStore.cacheURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
        } catch {
            ShelfLog.error(.sync, "Household cache write failed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    nonisolated static func archive(_ share: CKShare) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.encode(share, forKey: NSKeyedArchiveRootObjectKey)
        coder.finishEncoding()
        return coder.encodedData
    }

    nonisolated static func share(from data: Data) -> CKShare? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.self, from: data)
    }

    /// Plain-words text for a CloudKit failure.
    nonisolated static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else {
            return String(localized: "Something went wrong. Try again.", comment: "Household: generic failure")
        }
        switch ck.code {
        case .notAuthenticated:
            return String(localized: "Sign in to iCloud in Settings to use Household.",
                          comment: "Household: shown when no iCloud account is signed in on the device")
        case .networkUnavailable, .networkFailure:
            return String(localized: "You're offline. Household will sync when you're back online.",
                          comment: "Household: offline")
        case .quotaExceeded:
            return String(localized: "Your iCloud storage is full.", comment: "Household: iCloud quota")
        case .permissionFailure:
            return String(localized: "You don't have permission to do that in this household.",
                          comment: "Household: permission error")
        case .missingEntitlement:
            return String(localized: "This build of ShelfHead isn't set up for iCloud yet.",
                          comment: "Household: iCloud entitlement missing")
        default:
            return String(localized: "Household couldn't reach iCloud. Try again.", comment: "Household: generic CloudKit failure")
        }
    }
}

// MARK: - Invite

/// Batch 453: the item `ShareLink` shares, via `CKShareTransferRepresentation` (iOS 16).
/// Batch 480: an already-saved share must go out as `.existing`; `.prepareShare` is only for when there is no
/// share yet (https://developer.apple.com/documentation/cloudkit/cksharetransferrepresentation/exportedshare).
/// Handing a saved share to `.prepareShare` made the share sheet fail with "a link could not be created".
struct HouseholdInvite: Transferable {
    var share: CKShare?

    static var transferRepresentation: some TransferRepresentation {
        CKShareTransferRepresentation { invite in
            let container = HouseholdStore.makeContainer()
            let options = CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                                  allowedParticipantAccessOptions: .specifiedRecipientsOnly)
            if let share = invite.share {
                return .existing(share, container: container, allowedSharingOptions: options)
            }
            return .prepareShare(container: container, allowedSharingOptions: options) {
                try await HouseholdStore.shared.prepareShare()
            }
        }
    }
}
