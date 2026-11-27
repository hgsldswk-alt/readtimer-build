import Foundation
import Security

struct Entitlement: Codable, Equatable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(localStart, trialClaimedAt ?? localStart)
    }
    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }
    func hasPro(at date: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (date >= trialStart && date < trialEnd)
    }

    mutating func applyVerifiedTrial(_ originalDate: Date) {
        trialClaimedAt = min(trialClaimedAt ?? originalDate, originalDate)
    }

    mutating func applyVerifiedPro(revoked: Bool) {
        purchasedPro = !revoked
    }
}

actor EntitlementVault {
    private var newestRevision = 0
    private let query: [String: String] = [
        kSecClass as String: kSecClassGenericPassword as String,
        kSecAttrService as String: "com.hgsldswk.readtimer.entitlement",
        kSecAttrAccount as String: "paid-state"
    ]

    struct KeychainError: Error { let status: OSStatus }

    private func read() throws -> Entitlement? {
        var request: [String: Any] = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    func load(at now: Date) throws -> Entitlement {
        if var saved = try read() {
            if saved.proStartedAt == nil {
                saved.proStartedAt = now
                try write(saved)
            }
            return saved
        }
        let value = Entitlement(firstOpen: now, proStartedAt: now)
        try write(value)
        return value
    }

    func save(_ value: Entitlement, revision: Int) throws {
        guard revision >= newestRevision else { return }
        newestRevision = revision
        try write(value)
    }

    private func write(_ value: Entitlement) throws {
        let data = try JSONEncoder().encode(value)
        let values = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(query as CFDictionary, values)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var item: [String: Any] = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(item as CFDictionary, nil)
        guard inserted == errSecSuccess else { throw KeychainError(status: inserted) }
    }
}
