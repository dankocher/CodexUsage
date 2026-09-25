import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private func window(_ used: String = "36", minutes: Int = 10_080, reset: Double = 1_900_000_000) throws -> UsageWindow {
        try decode(UsageWindow.self, "{\"usedPercent\":\(used),\"windowDurationMins\":\(minutes),\"resetsAt\":\(reset)}")
    }
    private func snapshot(reset: Double = 1_900_000_000, fetchedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> UsageSnapshot {
        UsageSnapshot(account: try decode(Account.self, "{\"type\":\"chatgpt\",\"email\":\"a@example.invalid\"}"),
                      limits: try decode(RateLimitsResponse.self, "{\"rateLimits\":{\"primary\":{\"usedPercent\":36,\"windowDurationMins\":10080,\"resetsAt\":\(reset)}}}"),
                      activity: nil, activityNotice: nil, fetchedAt: fetchedAt, executable: "/test/codex")
    }

    func testRemainingIsClampedAndNullIsNotZero() throws {
        XCTAssertEqual(try window().remainingPercent, 64)
        XCTAssertEqual(try window("110").remainingPercent, 0)
        XCTAssertEqual(try window("-8").remainingPercent, 100)
        XCTAssertNil(try window("null").remainingPercent)
        XCTAssertEqual(UsageFormat.percent(nil), "—")
        XCTAssertEqual(UsageFormat.percent(99.9), "99%")
    }
    func testWeeklyMayBePrimaryOrSecondary() throws {
        for slot in ["primary", "secondary"] {
            let value = try decode(RateLimitsResponse.self, "{\"rateLimitsByLimitId\":{\"codex\":{\"\(slot)\":{\"usedPercent\":25,\"windowDurationMins\":10080}}}}")
            XCTAssertEqual(value.weekly?.remainingPercent, 75)
        }
    }
    func testMultiBucketWinsAndCodexSortsFirst() throws {
        let value = try decode(RateLimitsResponse.self, #"{"rateLimits":{"primary":{"usedPercent":99,"windowDurationMins":10080}},"rateLimitsByLimitId":{"spark":{"secondary":{"usedPercent":75,"windowDurationMins":10080}},"codex":{"primary":{"usedPercent":36,"windowDurationMins":10080}},"base":{"limitName":"gpt-reserve"}}}"#)
        XCTAssertEqual(value.groups.map(\.id), ["codex", "base", "spark"])
        XCTAssertEqual(value.weekly?.remainingPercent, 64)
        XCTAssertEqual(value.groups[1].title, "Reserve")
    }
    func testOtherWeeklyNeverReplacesGeneralWeekly() throws {
        let value = try decode(RateLimitsResponse.self, #"{"rateLimitsByLimitId":{"spark":{"primary":{"windowDurationMins":10080,"usedPercent":50}}}}"#)
        XCTAssertNil(value.weekly)
        XCTAssertEqual(UsageFormat.statusTitle(window: value.weekly, resetsAvailable: nil, stale: false), "C —")
    }
    func testLegacyAndEmptyMapFallback() throws {
        let value = try decode(RateLimitsResponse.self, #"{"rateLimitsByLimitId":{},"rateLimits":{"secondary":{"windowDurationMins":10080,"usedPercent":0}}}"#)
        XCTAssertEqual(value.weekly?.remainingPercent, 100)
        XCTAssertTrue(try decode(RateLimitsResponse.self, "{}").groups.isEmpty)
    }
    func testResetCountAuthoritativeAndUnknownExpiryPreserved() throws {
        let value = try decode(ResetCredits.self, #"{"availableCount":4,"credits":[{"status":"available","expiresAt":null},{"status":"used","expiresAt":1800000000},{"status":"available","expiresAt":1900000000}]}"#)
        XCTAssertEqual(value.availableCount, 4)
        XCTAssertEqual(value.availableDetails?.count, 2)
        XCTAssertNotNil(value.availableDetails?.first?.expiryDate)
        XCTAssertNil(value.availableDetails?.last?.expiryDate)
        XCTAssertNil(try decode(ResetCredits.self, #"{"availableCount":1,"credits":null}"#).availableDetails)
        XCTAssertEqual(try decode(ResetCredits.self, #"{"availableCount":0,"credits":[]}"#).availableDetails, [])
    }
    func testBalanceAcceptsStringNumberAndMissing() throws {
        XCTAssertEqual(try decode(CreditBalance.self, #"{"balance":"0"}"#).balance, "0")
        XCTAssertEqual(try decode(CreditBalance.self, #"{"balance":12}"#).balance, "12.0")
        XCTAssertNil(try decode(CreditBalance.self, "{}").balance)
    }
    func testCountdownBoundariesAndNoInventedReset() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UsageFormat.countdown(to: nil, now: now), "No date")
        XCTAssertEqual(UsageFormat.countdown(to: now, now: now), "Pending")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(-3), now: now), "Pending")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(59), now: now), "<1 min")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(3_660), now: now), "1h 1min")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(86_399), now: now), "23h 59min")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(86_400), now: now), "1d 0h")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(273_600), now: now), "3d 4h")
        let expired = try window(reset: now.timeIntervalSince1970 - 1)
        XCTAssertEqual(UsageFormat.statusTitle(window: expired, resetsAvailable: 1, stale: true, now: now), "C 64% · Pending · 1R !")
    }
    func testStatusBarShowsResetCountOnlyWhenKnown() throws {
        let active = try window(reset: 1_800_000_000 + 3 * 86_400 + 4 * 3_600)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UsageFormat.statusTitle(window: active, resetsAvailable: 1, stale: false, now: now), "C 64% · 3d 4h · 1R")
        XCTAssertEqual(UsageFormat.statusTitle(window: active, resetsAvailable: 0, stale: false, now: now), "C 64% · 3d 4h · 0R")
        XCTAssertEqual(UsageFormat.statusTitle(window: active, resetsAvailable: nil, stale: false, now: now), "C 64% · 3d 4h")
        XCTAssertEqual(UsageFormat.statusTitle(window: nil, resetsAvailable: 2, stale: true, now: now), "C — · 2R !")
        XCTAssertEqual(UsageFormat.statusTitle(window: active, resetsAvailable: -2, stale: false, now: now), "C 64% · 3d 4h · 0R")
    }
    func testDatesUseChosenTimeZoneAcrossMidnight() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(UsageFormat.exactDate(date, timeZone: TimeZone(secondsFromGMT: 0)!).contains("1 Jan 1970"))
        XCTAssertTrue(UsageFormat.exactDate(date, timeZone: TimeZone(secondsFromGMT: -3_600)!).contains("31 Dec 1969"))
    }
    func testMissingAndInvalidResetDates() throws {
        XCTAssertNil(try window(reset: -1).resetDate)
        XCTAssertNil(try window(reset: 1e20).resetDate)
        XCTAssertEqual(try window(minutes: 300).title, "5 hours")
        XCTAssertEqual(try window(minutes: 10_080).title, "Weekly")
    }
    func testFailurePreservesSameAccountAndChangeClearsIt() throws {
        var state = UsageState()
        let value = try snapshot()
        state.accept(value)
        state.fail("Offline")
        XCTAssertNotNil(state.snapshot)
        state.observeAccount(value.account)
        XCTAssertNotNil(state.snapshot)
        state.observeAccount(try decode(Account.self, #"{"type":"chatgpt","email":"b@example.invalid"}"#))
        XCTAssertNil(state.snapshot)
        XCTAssertNil(state.error)
        state.accept(value)
        state.observeAccount(nil)
        XCTAssertNil(state.snapshot)
    }
    func testRefreshOnMenuWakeTimeAndExpiredWindow() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let value = try snapshot(reset: start.timeIntervalSince1970 + 90, fetchedAt: start)
        var policy = RefreshPolicy(interval: 300)
        policy.lastAttempt = start
        XCTAssertFalse(policy.shouldRefresh(now: start.addingTimeInterval(20), snapshot: value, menuOpened: true))
        XCTAssertTrue(policy.shouldRefresh(now: start.addingTimeInterval(61), snapshot: value, menuOpened: true))
        XCTAssertTrue(policy.shouldRefresh(now: start.addingTimeInterval(91), snapshot: value))
        policy.lastAttempt = start.addingTimeInterval(91)
        XCTAssertFalse(policy.shouldRefresh(now: start.addingTimeInterval(92), snapshot: value))
        XCTAssertFalse(policy.shouldRefresh(now: start.addingTimeInterval(130), snapshot: value))
        XCTAssertTrue(policy.shouldRefresh(now: start.addingTimeInterval(4_000), snapshot: value))
        XCTAssertTrue(policy.shouldRefresh(now: start.addingTimeInterval(-60), snapshot: value))
    }
}

@MainActor
final class AppServerClientTests: XCTestCase {
    private func client(_ scenario: String, timeout: Double = 2, pidFile: String? = nil) -> AppServerClient {
        let fixture = Bundle.module.url(forResource: "server", withExtension: "py", subdirectory: "Fixtures")!
        var client = AppServerClient(executablePath: "/usr/bin/python3", timeout: timeout)
        client.processArguments = [fixture.path, scenario] + (pidFile.map { [$0] } ?? [])
        return client
    }
    func testFragmentedRepliesAndNotifications() async throws {
        let result = try await client("success").fetch()
        XCTAssertEqual(result.limits.weekly?.remainingPercent, 64)
        XCTAssertEqual(result.activity?.summary?.lifetimeTokens, 1234)
        XCTAssertEqual(result.limits.rateLimitResetCredits?.availableCount, 2)
    }
    func testOptionalActivityFailuresPreserveLimits() async throws {
        for scenario in ["unsupported-stats", "invalid-stats"] {
            let result = try await client(scenario).fetch()
            XCTAssertEqual(result.limits.weekly?.remainingPercent, 64)
            XCTAssertNil(result.activity)
            XCTAssertNotNil(result.activityNotice)
        }
    }
    func testSignedOutAndAPIKey() async {
        for (scenario, expected) in [("signed-out", ClientError.signedOut), ("api-key", .unsupportedAccount)] {
            do { _ = try await client(scenario).fetch(); XCTFail("Expected failure") }
            catch { XCTAssertEqual(error as? ClientError, expected) }
        }
    }
    func testTimeoutDisconnectInvalidAndExpiredAuth() async {
        for (scenario, expected) in [("timeout", ClientError.timeout), ("disconnect", .disconnected), ("invalid", .invalidResponse), ("auth-expired", .rpc(401, "Unauthorized"))] {
            do { _ = try await client(scenario, timeout: 0.4).fetch(); XCTFail("Expected failure: \(scenario)") }
            catch { XCTAssertEqual(error as? ClientError, expected) }
        }
    }
    func testMissingExecutable() async {
        do { _ = try await AppServerClient(executablePath: "/nonexistent/codex").fetch(); XCTFail("Expected failure") }
        catch { XCTAssertEqual(error as? ClientError, .executableMissing) }
    }
    func testNoShellEvaluation() {
        XCTAssertThrowsError(try ExecutableResolver.resolve("$(touch /tmp/do-not-create-codex-usage)"))
    }
    func testCancellationTerminatesChild() async throws {
        let pidURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { if FileManager.default.fileExists(atPath: pidURL.path) { try? FileManager.default.removeItem(at: pidURL) } }
        let configured = client("timeout", timeout: 15, pidFile: pidURL.path)
        let task = Task.detached { try await configured.fetch() }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidURL.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidURL, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1, "The app-server process must not survive cancellation")
    }
}
