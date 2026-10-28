import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Written for Shep.

/// The rights of one ACL entry that matter here (the macOS names; `addFile` is the directory name of write data, `addSubdirectory` of append).
public struct RecordingACLRights: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let readData = RecordingACLRights(rawValue: 1 << 0)
    public static let writeData = RecordingACLRights(rawValue: 1 << 1)
    public static let execute = RecordingACLRights(rawValue: 1 << 2)
    public static let delete = RecordingACLRights(rawValue: 1 << 3)
    public static let append = RecordingACLRights(rawValue: 1 << 4)
    public static let deleteChild = RecordingACLRights(rawValue: 1 << 5)
    public static let readAttributes = RecordingACLRights(rawValue: 1 << 6)
    public static let writeAttributes = RecordingACLRights(rawValue: 1 << 7)
    public static let readExtAttributes = RecordingACLRights(rawValue: 1 << 8)
    public static let writeExtAttributes = RecordingACLRights(rawValue: 1 << 9)
    public static let readSecurity = RecordingACLRights(rawValue: 1 << 10)
    public static let writeSecurity = RecordingACLRights(rawValue: 1 << 11)
    public static let changeOwner = RecordingACLRights(rawValue: 1 << 12)
    public static let synchronize = RecordingACLRights(rawValue: 1 << 13)

    public static let addFile = RecordingACLRights.writeData
    public static let addSubdirectory = RecordingACLRights.append
    public static let listDirectory = RecordingACLRights.readData
    public static let search = RecordingACLRights.execute

    /// Rights that let a principal add, remove or rename entries, or change the folder's mode or owner.
    public static let changesEntries: RecordingACLRights = [.writeData, .append, .deleteChild, .delete, .writeSecurity, .changeOwner]
}

public enum RecordingACLPrincipal: Equatable, Sendable {
    case user(UInt32)
    case group(UInt32)
    case unresolvable
}

public struct RecordingACLEntry: Equatable, Sendable {
    public var allow: Bool
    public var principal: RecordingACLPrincipal
    public var rights: RecordingACLRights

    public init(allow: Bool, principal: RecordingACLPrincipal, rights: RecordingACLRights) {
        self.allow = allow
        self.principal = principal
        self.rights = rights
    }
}

public enum RecordingACLRead: Equatable, Sendable {
    /// No extended ACL on the path.
    case none
    case entries([RecordingACLEntry])
    /// The ACL could not be read (any failure other than "there is none"): fail closed.
    case unreadable
}

/// What the file system says about the extended ACL of one (already resolved) path. Injected in unit tests.
public protocol RecordingACLReading {
    func read(path: String) -> RecordingACLRead
}

/// Answers "no ACL" for everything: for tests of the mode-bit rules only. Never used by the real checks.
public struct RecordingNoACLReader: RecordingACLReading {
    public init() {}
    public func read(path: String) -> RecordingACLRead { .none }
}

public enum RecordingACLRule {
    /// nil when the ACL of `path` is acceptable, else a short phrase for the refusal (no path in it).
    public static func problem(path: String, effectiveUID: UInt32, reader: RecordingACLReading) -> String? {
        switch reader.read(path: path) {
        case .none:
            return nil
        case .unreadable:
            return "its ACL could not be read"
        case .entries(let entries):
            for entry in entries where entry.allow && !entry.rights.isDisjoint(with: RecordingACLRights.changesEntries) {
                if case .user(let uid) = entry.principal, uid == effectiveUID { continue }
                return "an ACL lets another user change it"
            }
            return nil
        }
    }
}

#if canImport(Darwin)
/// The real reader (macOS): `acl_get_link_np` (the path is already resolved, and a link is not followed), one pass over the entries,
/// `acl_get_perm_np` for each right, and the qualifier of every ALLOW entry that carries a mutating right resolved with
/// `mbr_uuid_to_id`. Everything it allocates is freed. ENOENT from the ACL call means "no ACL"; any other failure is `.unreadable`.
@_silgen_name("mbr_uuid_to_id")
private func shepMbrUUIDToID(_ uuid: UnsafePointer<UInt8>, _ idOrGid: UnsafeMutablePointer<UInt32>, _ idType: UnsafeMutablePointer<Int32>) -> Int32

public struct RecordingRealACLReader: RecordingACLReading {
    public init() {}

    public func read(path: String) -> RecordingACLRead {
        errno = 0
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT ? .none : .unreadable
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }

        var entries: [RecordingACLEntry] = []
        var entryID: Int32 = Int32(truncatingIfNeeded: ACL_FIRST_ENTRY.rawValue)
        while true {
            var raw: acl_entry_t? = nil
            errno = 0
            let status = acl_get_entry(acl, entryID, &raw)
            entryID = Int32(truncatingIfNeeded: ACL_NEXT_ENTRY.rawValue)
            if status != 0 {
                // EINVAL is how the end of the list is reported; anything else is a failure.
                if errno == EINVAL { break }
                return .unreadable
            }
            guard let entry = raw else { return .unreadable }

            var tag: acl_tag_t = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { return .unreadable }
            let allow: Bool
            if tag == ACL_EXTENDED_ALLOW {
                allow = true
            } else if tag == ACL_EXTENDED_DENY {
                allow = false
            } else {
                return .unreadable
            }

            var permset: acl_permset_t? = nil
            guard acl_get_permset(entry, &permset) == 0, let perms = permset else { return .unreadable }
            var rights: RecordingACLRights = []
            let table: [(acl_perm_t, RecordingACLRights)] = [
                (ACL_READ_DATA, .readData), (ACL_WRITE_DATA, .writeData), (ACL_EXECUTE, .execute), (ACL_DELETE, .delete),
                (ACL_APPEND_DATA, .append), (ACL_DELETE_CHILD, .deleteChild), (ACL_READ_ATTRIBUTES, .readAttributes),
                (ACL_WRITE_ATTRIBUTES, .writeAttributes), (ACL_READ_EXTATTRIBUTES, .readExtAttributes),
                (ACL_WRITE_EXTATTRIBUTES, .writeExtAttributes), (ACL_READ_SECURITY, .readSecurity),
                (ACL_WRITE_SECURITY, .writeSecurity), (ACL_CHANGE_OWNER, .changeOwner), (ACL_SYNCHRONIZE, .synchronize),
            ]
            for (perm, right) in table {
                let has = acl_get_perm_np(perms, perm)
                if has < 0 { return .unreadable }
                if has == 1 { rights.insert(right) }
            }

            // Only an allow entry with a mutating right needs a principal; for the rest the answer cannot change the verdict.
            var principal = RecordingACLPrincipal.unresolvable
            if allow && !rights.isDisjoint(with: RecordingACLRights.changesEntries) {
                principal = RecordingRealACLReader.principal(of: entry)
            }
            entries.append(RecordingACLEntry(allow: allow, principal: principal, rights: rights))
        }
        return .entries(entries)
    }

    private static func principal(of entry: acl_entry_t) -> RecordingACLPrincipal {
        guard let qualifier = acl_get_qualifier(entry) else { return .unresolvable }
        defer { acl_free(qualifier) }
        // The qualifier is a guid_t: 16 bytes, which is what mbr_uuid_to_id takes.
        let bytes = qualifier.assumingMemoryBound(to: UInt8.self)
        var id: uid_t = 0
        var idType: Int32 = -1
        guard shepMbrUUIDToID(bytes, &id, &idType) == 0 else { return .unresolvable }
        // ID_TYPE_UID is 0 and ID_TYPE_GID is 1 in <membership.h>, which the Darwin module does not export.
        if idType == 0 { return .user(UInt32(id)) }
        if idType == 1 { return .group(UInt32(id)) }
        return .unresolvable
    }
}
#else
/// Without the macOS ACL API there is nothing to read: the mode bits are the whole rule there.
public struct RecordingRealACLReader: RecordingACLReading {
    public init() {}
    public func read(path: String) -> RecordingACLRead { .none }
}
#endif
