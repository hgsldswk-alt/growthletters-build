import Foundation

struct Entitlement: Codable, Equatable, Sendable {
    static let duration: TimeInterval = 30 * 24 * 3600
    var firstOpen: Date = .now
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date { proStartedAt ?? firstOpen }
    var trialEnd: Date { trialStart.addingTimeInterval(Self.duration) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart.addingTimeInterval(-600) && now < trialEnd)
    }

    mutating func limitStart(to evidence: Date) {
        guard evidence.timeIntervalSinceReferenceDate.isFinite else { return }
        proStartedAt = min(trialStart, evidence)
    }

    mutating func applyVerifiedPurchase(_ active: Bool) { purchasedPro = active }
}

struct AccessRecord: Codable, Sendable {
    var entitlement: Entitlement
    var recoverOriginalDate = false
    var purchaseSignedAt: Date?

    mutating func acceptVerified(productID: String, signedAt: Date, originalDate: Date, revoked: Bool) -> Bool {
        switch productID {
        case Launch.proID:
            if let purchaseSignedAt, purchaseSignedAt > signedAt ||
                (purchaseSignedAt == signedAt && !entitlement.purchasedPro && !revoked) { return true }
            purchaseSignedAt = signedAt
            entitlement.applyVerifiedPurchase(!revoked)
        case Launch.trialID:
            let previousClaim = entitlement.trialClaimedAt ?? originalDate
            entitlement.trialClaimedAt = min(previousClaim, originalDate)
            entitlement.limitStart(to: originalDate)
        default: return false
        }
        return true
    }
}

struct ReviewProgress: Codable, Sendable {
    var days: Set<CivilDay> = []
    var requestedVersions: Set<String> = []

    mutating func record(_ date: Date, calendar: Calendar = .current) {
        days.insert(CivilDay(date, timeZone: calendar.timeZone))
    }

    func eligible(_ version: String, idle: Bool) -> Bool {
        idle && days.count >= 3 && !requestedVersions.contains(version)
    }
}

struct ReviewOpportunity {
    private(set) var ticket: UUID?

    mutating func saved(eligible: Bool) { ticket = eligible ? UUID() : nil }
    mutating func cancel() { ticket = nil }

    func permits(_ candidate: UUID, unobstructed: Bool) -> Bool {
        ticket == candidate && unobstructed
    }
}
