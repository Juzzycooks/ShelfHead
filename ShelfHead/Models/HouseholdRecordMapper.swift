import Foundation
import CloudKit

/// Batch 453: pure mapping between the Household value types and `CKRecord`. No network, no container:
/// `CKRecord` can be built and read without iCloud, which is what the tests do. Record type names and
/// field keys are constants so a rename can't drift between the writer and the reader.
nonisolated enum HouseholdRecordMapper {
    static let containerIdentifier = "iCloud.com.justin.ShelfHead"
    static let zoneName = "Household"

    enum RecordType {
        static let member = "Member"
        static let nowListening = "NowListening"
        static let recommendation = "Recommendation"
        static let club = "Club"
        static let clubPost = "ClubPost"
    }

    enum Key {
        static let displayName = "displayName"
        static let avatarSymbol = "avatarSymbol"
        static let avatarColorIndex = "avatarColorIndex"
        static let serverFingerprint = "serverFingerprint"
        static let updatedAt = "updatedAt"
        static let memberId = "memberId"
        static let libraryItemId = "libraryItemId"
        static let title = "title"
        static let author = "author"
        static let progress = "progress"
        static let fromMemberId = "fromMemberId"
        static let toMemberIds = "toMemberIds"
        static let note = "note"
        static let createdAt = "createdAt"
        static let goalText = "goalText"
        static let goalSeconds = "goalSeconds"
        static let goalDate = "goalDate"
        static let createdBy = "createdBy"
        static let clubId = "clubId"
        static let positionSeconds = "positionSeconds"
        static let text = "text"
    }

    static func recordType(for record: HouseholdRecord) -> String {
        switch record {
        case .member: return RecordType.member
        case .nowListening: return RecordType.nowListening
        case .recommendation: return RecordType.recommendation
        case .club: return RecordType.club
        case .clubPost: return RecordType.clubPost
        }
    }

    // MARK: To CKRecord

    /// A `CKRecord` for `item` in `zoneID`. Pass `base` (a record rebuilt from saved system fields) to update
    /// an existing server record instead of creating a new one, which CloudKit would reject as a conflict.
    static func ckRecord(for item: HouseholdRecord, zoneID: CKRecordZone.ID, base: CKRecord? = nil) -> CKRecord {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        let type = recordType(for: item)
        let record: CKRecord
        if let base, base.recordID == id, base.recordType == type {
            record = base
        } else {
            record = CKRecord(recordType: type, recordID: id)
        }
        switch item {
        case .member(let m):
            record[Key.displayName] = m.displayName as CKRecordValue
            record[Key.avatarSymbol] = m.avatarSymbol as CKRecordValue
            record[Key.avatarColorIndex] = m.avatarColorIndex as CKRecordValue
            record[Key.serverFingerprint] = m.serverFingerprint as CKRecordValue
            record[Key.updatedAt] = m.updatedAt as CKRecordValue
        case .nowListening(let n):
            record[Key.memberId] = n.memberId as CKRecordValue
            record[Key.libraryItemId] = n.libraryItemId as CKRecordValue
            record[Key.serverFingerprint] = n.serverFingerprint as CKRecordValue
            record[Key.title] = n.title as CKRecordValue
            record[Key.author] = n.author as CKRecordValue
            record[Key.progress] = n.progress as CKRecordValue
            record[Key.updatedAt] = n.updatedAt as CKRecordValue
        case .recommendation(let r):
            record[Key.fromMemberId] = r.fromMemberId as CKRecordValue
            record[Key.toMemberIds] = r.toMemberIds as CKRecordValue
            record[Key.libraryItemId] = r.libraryItemId as CKRecordValue
            record[Key.serverFingerprint] = r.serverFingerprint as CKRecordValue
            record[Key.title] = r.title as CKRecordValue
            record[Key.author] = r.author as CKRecordValue
            record[Key.note] = r.note as CKRecordValue
            record[Key.createdAt] = r.createdAt as CKRecordValue
        case .club(let c):
            record[Key.libraryItemId] = c.libraryItemId.map { $0 as CKRecordValue }
            record[Key.title] = c.title as CKRecordValue
            record[Key.author] = c.author as CKRecordValue
            record[Key.serverFingerprint] = c.serverFingerprint as CKRecordValue
            record[Key.goalText] = c.goalText.map { $0 as CKRecordValue }
            record[Key.goalSeconds] = c.goalSeconds.map { $0 as CKRecordValue }
            record[Key.goalDate] = c.goalDate.map { $0 as CKRecordValue }
            record[Key.createdBy] = c.createdBy as CKRecordValue
            record[Key.updatedAt] = c.updatedAt as CKRecordValue
        case .clubPost(let p):
            record[Key.clubId] = p.clubId as CKRecordValue
            record[Key.memberId] = p.memberId as CKRecordValue
            record[Key.positionSeconds] = p.positionSeconds as CKRecordValue
            record[Key.text] = p.text as CKRecordValue
            record[Key.createdAt] = p.createdAt as CKRecordValue
        }
        return record
    }

    // MARK: From CKRecord

    /// The value type a fetched record describes, or nil for a foreign type (the `CKShare`) or one missing a
    /// required field. A bad record from a newer app version is skipped rather than half-read.
    static func item(from record: CKRecord) -> HouseholdRecord? {
        func string(_ key: String) -> String? { record[key] as? String }
        func double(_ key: String) -> Double? { (record[key] as? NSNumber)?.doubleValue }
        func date(_ key: String) -> Date? { record[key] as? Date }

        switch record.recordType {
        case RecordType.member:
            guard let name = string(Key.displayName), let symbol = string(Key.avatarSymbol),
                  let color = (record[Key.avatarColorIndex] as? NSNumber)?.intValue,
                  let updated = date(Key.updatedAt) else { return nil }
            return .member(HouseholdMember(id: record.recordID.recordName, displayName: name, avatarSymbol: symbol,
                                           avatarColorIndex: color,
                                           serverFingerprint: string(Key.serverFingerprint) ?? "",
                                           updatedAt: updated))
        case RecordType.nowListening:
            guard let memberId = string(Key.memberId), let itemId = string(Key.libraryItemId),
                  let title = string(Key.title), let progress = double(Key.progress),
                  let updated = date(Key.updatedAt) else { return nil }
            return .nowListening(HouseholdNowListening(memberId: memberId, libraryItemId: itemId,
                                                       serverFingerprint: string(Key.serverFingerprint) ?? "",
                                                       title: title, author: string(Key.author) ?? "",
                                                       progress: progress, updatedAt: updated))
        case RecordType.recommendation:
            guard let from = string(Key.fromMemberId), let itemId = string(Key.libraryItemId),
                  let title = string(Key.title), let created = date(Key.createdAt) else { return nil }
            return .recommendation(HouseholdRecommendation(
                id: record.recordID.recordName, fromMemberId: from,
                toMemberIds: record[Key.toMemberIds] as? [String] ?? [], libraryItemId: itemId,
                serverFingerprint: string(Key.serverFingerprint) ?? "", title: title,
                author: string(Key.author) ?? "", note: string(Key.note) ?? "", createdAt: created))
        case RecordType.club:
            guard let title = string(Key.title), let createdBy = string(Key.createdBy),
                  let updated = date(Key.updatedAt) else { return nil }
            return .club(HouseholdClub(id: record.recordID.recordName, libraryItemId: string(Key.libraryItemId),
                                       title: title, author: string(Key.author) ?? "",
                                       serverFingerprint: string(Key.serverFingerprint) ?? "",
                                       goalText: string(Key.goalText), goalSeconds: double(Key.goalSeconds),
                                       goalDate: date(Key.goalDate), createdBy: createdBy, updatedAt: updated))
        case RecordType.clubPost:
            guard let clubId = string(Key.clubId), let memberId = string(Key.memberId),
                  let position = double(Key.positionSeconds), let text = string(Key.text),
                  let created = date(Key.createdAt) else { return nil }
            return .clubPost(HouseholdClubPost(id: record.recordID.recordName, clubId: clubId, memberId: memberId,
                                               positionSeconds: position, text: text, createdAt: created))
        default:
            return nil
        }
    }

    // MARK: System fields

    /// Just the server-assigned fields (record change tag, zone), so a later save updates rather than
    /// conflicts. Stored per record in the local cache.
    static func encodeSystemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }
}
