import Foundation

public enum UsageFormat {
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        // Do not display 100% for a partially depleted window.
        return "\(Int(floor(min(100, max(0, value)))))%"
    }

    public static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "No date" }
        let delta = date.timeIntervalSince(now)
        guard delta.isFinite else { return "No date" }
        guard delta > 0 else { return "Pending" }
        if delta < 60 { return "<1 min" }
        let minutes = Int(min(delta / 60, Double(Int.max / 2)))
        if minutes >= 1_440 { return "\(minutes / 1_440)d \((minutes % 1_440) / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)min"
    }

    public static func exactDate(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "Date unavailable" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy, HH:mm z"
        return formatter.string(from: date)
    }

    public static func statusTitle(window: UsageWindow?, resetsAvailable: Int?, stale: Bool, now: Date = Date()) -> String {
        let quota: String
        if let window, let remaining = window.remainingPercent {
            quota = "C \(percent(remaining)) · \(countdown(to: window.resetDate, now: now))"
        } else {
            quota = "C —"
        }
        let resets = resetsAvailable.map { " · \(max(0, $0))R" } ?? ""
        let staleMarker = stale ? " !" : ""
        return "\(quota)\(resets)\(staleMarker)"
    }
}

/// Pure scheduling policy, shared by the menu controller and deterministic tests.
public struct RefreshPolicy: Sendable {
    public var interval: TimeInterval
    public var lastAttempt: Date?
    private var attemptedExpirations: Set<Date> = []
    public init(interval: TimeInterval = 300) { self.interval = interval }

    public mutating func shouldRefresh(now: Date, snapshot: UsageSnapshot?, menuOpened: Bool = false) -> Bool {
        // A failed reset query should not cause an endless one-second request loop.
        if let lastAttempt, now >= lastAttempt, now.timeIntervalSince(lastAttempt) < 30 { return false }
        if let snapshot {
            let deadlines = snapshot.limits.groups.flatMap { $0.bucket.windows }.compactMap(\.resetDate)
                + (snapshot.limits.rateLimitResetCredits?.availableDetails?.compactMap(\.expiryDate) ?? [])
            let expired = Set(deadlines.filter { $0 <= now })
            let newExpirations = expired.subtracting(attemptedExpirations)
            if !newExpirations.isEmpty {
                attemptedExpirations.formUnion(newExpirations)
                return true
            }
            if menuOpened && now.timeIntervalSince(snapshot.fetchedAt) >= 60 { return true }
        } else if menuOpened { return true }
        return lastAttempt.map { now.timeIntervalSince($0) >= interval || now < $0 } ?? true
    }

    public mutating func reset() { lastAttempt = nil; attemptedExpirations = [] }
}

public struct UsageState: Sendable {
    public private(set) var snapshot: UsageSnapshot?
    public private(set) var account: Account?
    public private(set) var error: String?
    public init() {}

    public mutating func observeAccount(_ newAccount: Account?) {
        if account?.identity != newAccount?.identity { snapshot = nil; error = nil }
        account = newAccount
    }
    public mutating func accept(_ value: UsageSnapshot) {
        observeAccount(value.account)
        snapshot = value; error = nil
    }
    public mutating func fail(_ message: String) { error = message }
    public mutating func clear() { snapshot = nil; account = nil; error = nil }
}
