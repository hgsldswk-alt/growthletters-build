import Foundation
import Security
import StoreKit

actor StoreAccess {
    private let service = "com.hgsldswk.growthletters.access"
    private let account = "entitlement-v1"
    private let fallbackKey = "local-access-recovery"
    private var cached: AccessRecord?

    func load() -> Entitlement {
        if let cached { return cached.entitlement }
        if Launch.uiTesting {
            let now = Date()
            let expired = Launch.args.contains("-expired") || Launch.args.contains("-paywall")
            let first = expired ? now.addingTimeInterval(-31 * 86_400) : now
            let record = AccessRecord(entitlement: Entitlement(firstOpen: first, proStartedAt: first,
                                                               purchasedPro: Launch.args.contains("-purchased")))
            cached = record
            return record.entitlement
        }

        let defaults = UserDefaults.standard
        let fallback = defaults.data(forKey: fallbackKey).flatMap { try? JSONDecoder().decode(AccessRecord.self, from: $0) }
        let secure = readKeychain()
        let now = Date()
        var record = secure ?? fallback ?? AccessRecord(entitlement: Entitlement(firstOpen: now))
        if !Launch.isFree, record.entitlement.proStartedAt == nil { record.entitlement.proStartedAt = now }
        if secure == nil, fallback == nil, defaults.bool(forKey: "had-launch") { record.recoverOriginalDate = true }
        defaults.set(true, forKey: "had-launch")
        save(record)
        return record.entitlement
    }

    func mergeTrial(_ date: Date) -> Entitlement {
        _ = load()
        guard var record = cached else { return Entitlement() }
        record.entitlement.limitStart(to: date)
        save(record)
        return record.entitlement
    }

    func refresh() async -> Entitlement {
        _ = load()
        guard !Launch.uiTesting, !Launch.isFree else { return load() }
        if let result = await StoreKit.Transaction.latest(for: Launch.proID) { _ = accept(result) }
        if let result = await StoreKit.Transaction.latest(for: Launch.trialID) { _ = accept(result) }
        if cached?.recoverOriginalDate == true,
           case .verified(let transaction)? = try? await AppTransaction.shared,
           transaction.environment == .production, var record = cached {
            record.entitlement.limitStart(to: transaction.originalPurchaseDate)
            record.recoverOriginalDate = false
            save(record)
        }
        return load()
    }

    @discardableResult
    func accept(_ result: VerificationResult<StoreKit.Transaction>) -> Bool {
        _ = load()
        guard case .verified(let transaction) = result, var record = cached,
              transaction.productType == .nonConsumable,
              record.acceptVerified(productID: transaction.productID, signedAt: transaction.signedDate,
                                    originalDate: transaction.originalPurchaseDate, revoked: transaction.revocationDate != nil)
        else { return false }
        save(record)
        return true
    }

    private var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func readKeychain() -> AccessRecord? {
        var query = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(AccessRecord.self, from: data)
    }

    private func save(_ record: AccessRecord) {
        cached = record
        guard !Launch.uiTesting, let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: fallbackKey)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(key as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var entry = key
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(entry as CFDictionary, nil)
        }
    }
}
