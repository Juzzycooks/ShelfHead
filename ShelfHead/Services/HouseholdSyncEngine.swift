import Foundation
import CloudKit

/// Batch 453: one `CKSyncEngine` (iOS 17.0, https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)
/// wrapped for one database. A household uses two at most: the owner's runs on the private database (their
/// own `Household` zone), a member's runs on the shared database (the zone the owner shared). The engine
/// persists nothing itself: its state serialization is handed to `HouseholdStore`, which writes it to disk.
///
/// This type only translates engine events into plain values (`HouseholdRecord`, `Data`) and hops to the main
/// actor store. All decisions (merge, ownership, reset) live in the store and the pure mapper/snapshot.
nonisolated final class HouseholdSyncEngine: CKSyncEngineDelegate, @unchecked Sendable {
    enum Scope: String, Codable, Sendable { case privateDatabase, sharedDatabase }

    /// A fetched record, already mapped, with its system fields so a later save can update it in place.
    struct FetchedItem: Sendable {
        let item: HouseholdRecord
        let systemFields: Data
    }

    let scope: Scope
    private weak var store: HouseholdStore?
    private var engine: CKSyncEngine!

    init(container: CKContainer, scope: Scope, stateData: Data?, store: HouseholdStore) {
        self.scope = scope
        self.store = store
        let database = scope == .privateDatabase ? container.privateCloudDatabase : container.sharedCloudDatabase
        let serialization = stateData.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization,
                                                       delegate: self)
        configuration.automaticallySync = true
        engine = CKSyncEngine(configuration)
    }

    // MARK: Commands

    func queueSave(_ recordName: String, zoneID: CKRecordZone.ID) {
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: recordName, zoneID: zoneID))])
    }

    func queueDelete(_ recordName: String, zoneID: CKRecordZone.ID) {
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(CKRecord.ID(recordName: recordName, zoneID: zoneID))])
    }

    func queueZoneSave(_ zoneID: CKRecordZone.ID) {
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }

    /// Fetch what changed on the server, then send what is waiting. Throws CloudKit's error for the caller to word.
    func syncNow() async throws {
        try await engine.fetchChanges()
        try await engine.sendChanges()
    }

    func cancel() async { await engine.cancelOperations() }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let store else { return }
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                await store.engineStateDidChange(scope, data: data)
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: await store.accountDidChange(signedOut: false)
            case .signOut, .switchAccounts: await store.accountDidChange(signedOut: true)
            @unknown default: break
            }
        case .fetchedDatabaseChanges(let changes):
            await store.fetchedZones(scope, modified: changes.modifications.map(\.zoneID),
                                     deleted: changes.deletions.map(\.zoneID))
        case .fetchedRecordZoneChanges(let changes):
            var items: [FetchedItem] = []
            var shareData: Data?
            for modification in changes.modifications {
                let record = modification.record
                if record.recordType == CKRecord.SystemType.share {
                    let coder = NSKeyedArchiver(requiringSecureCoding: true)
                    coder.encode(record, forKey: NSKeyedArchiveRootObjectKey)
                    coder.finishEncoding()
                    shareData = coder.encodedData
                } else if let item = HouseholdRecordMapper.item(from: record) {
                    items.append(FetchedItem(item: item, systemFields: HouseholdRecordMapper.encodeSystemFields(of: record)))
                }
            }
            let deleted = changes.deletions.map { ($0.recordID.recordName, $0.recordType) }
            await store.fetchedRecords(scope, items: items, shareData: shareData, deleted: deleted)
        case .sentRecordZoneChanges(let sent):
            await handleSent(sent, syncEngine: syncEngine, store: store)
        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        let store = self.store
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            if let record = await store?.ckRecord(for: recordID) { return record }
            // Nothing local to send (deleted since it was queued): drop the pending change.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }

    // MARK: Send results

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine,
                            store: HouseholdStore) async {
        if !sent.savedRecords.isEmpty {
            let fields = sent.savedRecords.map { ($0.recordID.recordName, HouseholdRecordMapper.encodeSystemFields(of: $0)) }
            await store.recordsWereSent(fields)
        }
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone saved first. Hand the server copy to the store, which keeps the newer one and re-sends.
                if let server = failure.error.serverRecord {
                    let item = HouseholdRecordMapper.item(from: server)
                    await store.conflictResolved(recordName: id.recordName, zoneID: id.zoneID, server: item,
                                                 systemFields: HouseholdRecordMapper.encodeSystemFields(of: server))
                }
            case .zoneNotFound:
                if scope == .privateDatabase { queueZoneSave(id.zoneID) }
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .unknownItem:
                await store.recordWasMissingOnServer(recordName: id.recordName)
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
            case .permissionFailure, .limitExceeded, .invalidArguments, .badContainer, .badDatabase:
                // Not retryable (a read-only participant, a malformed record). Drop it and say so.
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
                await store.sendFailed(failure.error)
            case .quotaExceeded, .notAuthenticated:
                // Review Medium 39 (30 October 2026): these used to fall into `default` and fail silently, so a post
                // looked sent when it wasn't. Keep the change pending (it goes out once the person frees iCloud
                // space or signs back in) but tell them, through the same `lastError` path as the other failures.
                await store.sendFailed(failure.error)
            default:
                // Network and throttling errors stay pending; the engine retries on its own schedule.
                break
            }
        }
    }
}
