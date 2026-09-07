import Foundation

public struct Account: Decodable, Equatable, Sendable {
    public let type: String
    public let email: String?
    public let planType: String?
    public let accountId: String?
    public var identity: String { "\(type):\(accountId ?? email ?? "unknown"):\(planType ?? "")" }
}

public struct AccountResponse: Decodable, Sendable {
    public let account: Account?
}

public struct UsageWindow: Decodable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }
    public var resetDate: Date? {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0, resetsAt < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }
    public var title: String {
        switch windowDurationMins {
        case 10_080: "Weekly"
        case 300: "5 hours"
        case let minutes? where minutes > 0 && minutes % 1_440 == 0: "\(minutes / 1_440) days"
        case let minutes? where minutes > 0 && minutes % 60 == 0: "\(minutes / 60) hours"
        case let minutes? where minutes > 0: "\(minutes) minutes"
        default: "Usage window"
        }
    }
}

public struct CreditBalance: Decodable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: String?

    enum CodingKeys: String, CodingKey { case hasCredits, unlimited, balance }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = try c.decodeIfPresent(Bool.self, forKey: .hasCredits)
        unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited)
        if let text = try? c.decode(String.self, forKey: .balance) { balance = text }
        else if let number = try? c.decode(Double.self, forKey: .balance) { balance = String(number) }
        else { balance = nil }
    }
}

public struct LimitBucket: Decodable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let credits: CreditBalance?
    public let planType: String?
    public let rateLimitReachedType: String?
    public var windows: [UsageWindow] { [primary, secondary].compactMap { $0 } }
}

public struct LimitGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let bucket: LimitBucket
    public var title: String {
        if id == "codex" { return "Codex" }
        if bucket.limitName == "gpt-reserve" { return "Reserve" }
        return bucket.limitName ?? bucket.limitId ?? id
    }
}

public struct ResetCredit: Decodable, Equatable, Sendable {
    public let status: String?
    public let expiresAt: Double?
    public var expiryDate: Date? {
        guard let expiresAt, expiresAt.isFinite, expiresAt > 0, expiresAt < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: expiresAt)
    }
}

public struct ResetCredits: Decodable, Equatable, Sendable {
    public let availableCount: Int?
    public let credits: [ResetCredit]?
    public var availableDetails: [ResetCredit]? {
        credits?.filter { $0.status == nil || $0.status == "available" }
            .sorted { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
    }
}

public struct RateLimitsResponse: Decodable, Equatable, Sendable {
    public let rateLimits: LimitBucket?
    public let rateLimitsByLimitId: [String: LimitBucket]?
    public let rateLimitResetCredits: ResetCredits?
    public let accountId: String?

    public var groups: [LimitGroup] {
        let buckets: [String: LimitBucket]
        if let multi = rateLimitsByLimitId, !multi.isEmpty { buckets = multi }
        else if let single = rateLimits { buckets = [single.limitId ?? "codex": single] }
        else { buckets = [:] }
        return buckets.map { LimitGroup(id: $0.key, bucket: $0.value) }.sorted {
            if $0.id == "codex" { return $1.id != "codex" }
            if $1.id == "codex" { return false }
            return $0.id < $1.id
        }
    }
    public var weekly: UsageWindow? {
        groups.first { $0.id == "codex" }?.bucket.windows.first { $0.windowDurationMins == 10_080 }
    }
}

public struct ActivitySummary: Decodable, Equatable, Sendable {
    public let lifetimeTokens: Int64?
    public let peakDailyTokens: Int64?
    public let longestRunningTurnSec: Double?
    public let currentStreakDays: Int?
    public let longestStreakDays: Int?
}

public struct DailyUsage: Decodable, Equatable, Sendable {
    public let startDate: String
    public let tokens: Int64
}

public struct ActivityResponse: Decodable, Equatable, Sendable {
    public let summary: ActivitySummary?
    public let dailyUsageBuckets: [DailyUsage]?
}

public struct UsageSnapshot: Sendable {
    public let account: Account
    public let limits: RateLimitsResponse
    public let activity: ActivityResponse?
    public let activityNotice: String?
    public let fetchedAt: Date
    public let executable: String

    public init(account: Account, limits: RateLimitsResponse, activity: ActivityResponse?,
                activityNotice: String?, fetchedAt: Date, executable: String) {
        self.account = account; self.limits = limits; self.activity = activity
        self.activityNotice = activityNotice; self.fetchedAt = fetchedAt; self.executable = executable
    }
}
