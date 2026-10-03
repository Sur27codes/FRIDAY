import Foundation
#if canImport(Security)
import Security
#endif

/// P2-PROD-BOOTSTRAP §B4 — identifies one stored credential. Two are
/// needed today (conversation provider, Cartesia); any future provider
/// fits the same shape without a new type.
public struct CredentialIdentifier: Sendable, Equatable, Hashable {
    public let service: String // Keychain "service" attribute — namespaced to this app
    public let account: String // Keychain "account" attribute — which credential within that service

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    public static let conversationProvider = CredentialIdentifier(service: "com.friday.companion.credentials", account: "conversationProvider")
    public static let cartesiaVoiceProvider = CredentialIdentifier(service: "com.friday.companion.credentials", account: "cartesiaVoiceProvider")
}

public enum CredentialStoreError: Error, Sendable, Equatable {
    /// Wraps a Keychain `OSStatus` — never the credential value itself.
    case osStatus(Int32)
    case unexpectedItemFormat
}

/// The whole point of this type: a caller can learn WHETHER a credential
/// is present and get metadata about it, without ever seeing the value
/// again after it was saved (§B4: "Never expose full credential after
/// save"). `maskedPreview` is deliberately short and lossy — e.g. the
/// last 4 characters only — never enough to reconstruct the credential.
public struct CredentialStatus: Sendable, Equatable {
    public let exists: Bool
    public let maskedPreview: String?
    public let savedAt: Date?

    public init(exists: Bool, maskedPreview: String?, savedAt: Date?) {
        self.exists = exists
        self.maskedPreview = maskedPreview
        self.savedAt = savedAt
    }

    public static let absent = CredentialStatus(exists: false, maskedPreview: nil, savedAt: nil)
}

/// P2-PROD-BOOTSTRAP §B4 — the abstraction boundary. Production code
/// depends on this protocol, never directly on `Security` framework
/// calls, so tests can use `FakeCredentialStore` (in-memory, never
/// touches the real Keychain) and so a future non-Keychain-backed
/// implementation (unlikely, but the point of an abstraction) would fit
/// without touching any call site.
public protocol CredentialStoring: Sendable {
    /// Saves (or replaces, if one already exists for this identifier) a
    /// credential value. The value is never logged, never returned by
    /// any other method on this protocol.
    func save(_ value: String, for identifier: CredentialIdentifier) throws
    /// Reads the real credential value back — used ONLY at the point a
    /// provider config is actually being constructed for a real network
    /// call, never for display.
    func read(_ identifier: CredentialIdentifier) throws -> String?
    /// Removes a stored credential, if any. Not an error if none existed.
    func delete(_ identifier: CredentialIdentifier) throws
    /// Whether a credential exists, plus safe-to-display metadata —
    /// never the value itself.
    func status(_ identifier: CredentialIdentifier) -> CredentialStatus
}

/// The real, `Security`-framework-backed implementation — a generic
/// password Keychain item per `CredentialIdentifier`, scoped to this
/// device only (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never
/// synced to iCloud Keychain, since these are machine-local service
/// credentials, not something meant to roam).
public struct KeychainCredentialStore: CredentialStoring {
    public init() {}

    public func save(_ value: String, for identifier: CredentialIdentifier) throws {
        #if canImport(Security)
        let valueData = Data(value.utf8)
        let existing = baseQuery(identifier)
        let status = SecItemCopyMatching(existing as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [
                kSecValueData as String: valueData,
                kSecAttrModificationDate as String: Date(),
            ]
            let updateStatus = SecItemUpdate(existing as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw CredentialStoreError.osStatus(updateStatus) }
        } else if status == errSecItemNotFound {
            var addQuery = baseQuery(identifier)
            addQuery[kSecValueData as String] = valueData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError.osStatus(addStatus) }
        } else {
            throw CredentialStoreError.osStatus(status)
        }
        #else
        throw CredentialStoreError.osStatus(-1)
        #endif
    }

    public func read(_ identifier: CredentialIdentifier) throws -> String? {
        #if canImport(Security)
        var query = baseQuery(identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.osStatus(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError.unexpectedItemFormat
        }
        return value
        #else
        return nil
        #endif
    }

    public func delete(_ identifier: CredentialIdentifier) throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(identifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.osStatus(status) }
        #endif
    }

    public func status(_ identifier: CredentialIdentifier) -> CredentialStatus {
        guard let value = try? read(identifier), !value.isEmpty else { return .absent }
        let preview = maskedPreview(of: value)
        let savedAt = attributeModificationDate(identifier)
        return CredentialStatus(exists: true, maskedPreview: preview, savedAt: savedAt)
    }

    #if canImport(Security)
    private func baseQuery(_ identifier: CredentialIdentifier) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.service,
            kSecAttrAccount as String: identifier.account,
        ]
    }

    private func attributeModificationDate(_ identifier: CredentialIdentifier) -> Date? {
        var query = baseQuery(identifier)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }
    #endif
}

/// Returns e.g. "••••ab12" — the value's own length is never revealed
/// beyond "long enough to have 4+ characters," and nothing before the
/// last 4 characters is ever included.
public func maskedPreview(of value: String) -> String {
    guard value.count > 4 else { return String(repeating: "•", count: max(value.count, 1)) }
    let suffix = value.suffix(4)
    return "••••" + suffix
}

/// P2-PROD-BOOTSTRAP §B4/§B17 — the ONLY `CredentialStoring`
/// implementation any automated test may use. In-memory, never touches
/// the real Keychain, never leaves any trace on the developer's machine.
public final class FakeCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialIdentifier: (value: String, savedAt: Date)] = [:]
    public var saveError: Error?
    public var readError: Error?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func save(_ value: String, for identifier: CredentialIdentifier) throws {
        if let saveError { throw saveError }
        lock.lock(); storage[identifier] = (value, now()); lock.unlock()
    }

    public func read(_ identifier: CredentialIdentifier) throws -> String? {
        if let readError { throw readError }
        lock.lock(); defer { lock.unlock() }
        return storage[identifier]?.value
    }

    public func delete(_ identifier: CredentialIdentifier) throws {
        lock.lock(); storage[identifier] = nil; lock.unlock()
    }

    public func status(_ identifier: CredentialIdentifier) -> CredentialStatus {
        lock.lock(); let entry = storage[identifier]; lock.unlock()
        guard let entry, !entry.value.isEmpty else { return .absent }
        return CredentialStatus(exists: true, maskedPreview: maskedPreview(of: entry.value), savedAt: entry.savedAt)
    }
}
