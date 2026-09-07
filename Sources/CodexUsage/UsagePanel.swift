import SwiftUI
import Charts
import UsageCore

private let accent = Color(red: 0.17, green: 0.57, blue: 0.47)

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = store.state.error { notice(error, icon: "exclamationmark.triangle", color: .orange) }
                    if let message = store.actionNotice { notice(message, icon: "info.circle", color: .secondary) }
                    if let snapshot = store.snapshot {
                        if store.stale { notice("Out of date · showing the last successful reading.", icon: "clock.arrow.circlepath", color: .orange) }
                        ForEach(snapshot.limits.groups) { group in
                            if group.id == "codex" { primaryGroup(group) }
                        }
                        if snapshot.limits.weekly == nil {
                            notice("This account does not report a general weekly allowance.", icon: "info.circle", color: .secondary)
                        }
                        let others = snapshot.limits.groups.filter { $0.id != "codex" }
                        if !others.isEmpty {
                            sectionTitle("OTHER LIMITS")
                            VStack(spacing: 14) {
                                ForEach(others) { group in bucketView(group) }
                            }
                        }
                        resetCredits(snapshot.limits.rateLimitResetCredits)
                        activity(snapshot)
                    } else if store.isRefreshing {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text("Checking your account…").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 48)
                    } else {
                        ContentUnavailableView("Connect to Codex", systemImage: "terminal", description: Text("Uses your existing Codex session. Make sure you are signed in, then refresh."))
                            .padding(.vertical, 12)
                    }
                }.padding(20)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 380, height: 650)
        .background(.regularMaterial)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private var header: some View {
        HStack(spacing: 11) {
            Text("C").font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(accent).frame(width: 36, height: 36)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("CodexUsage").font(.system(size: 15, weight: .semibold))
                Text(store.snapshot.map { "Plan \($0.account.planType ?? "unavailable")" } ?? "Your usage, at a glance")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isRefreshing { ProgressView().controlSize(.small).scaleEffect(0.8).accessibilityLabel("Refreshing") }
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).disabled(store.isRefreshing)
                .help("Refresh now").accessibilityLabel("Refresh now")
        }.padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func primaryGroup(_ group: LimitGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let weekly = group.bucket.windows.first(where: { $0.windowDurationMins == 10_080 }) {
                HStack(alignment: .firstTextBaseline) {
                    Text("WEEKLY ALLOWANCE").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Codex").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(UsageFormat.percent(weekly.remainingPercent))
                        .font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("remaining").font(.subheadline).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
                quotaBar(weekly)
                resetLine(weekly)
            }
            ForEach(Array(group.bucket.windows.enumerated()), id: \.offset) { _, window in
                if window.windowDurationMins != 10_080 { windowRow(window) }
            }
            if let balance = group.bucket.credits { balanceView(balance) }
            if group.bucket.rateLimitReachedType != nil {
                Label("Limit reached", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.15), lineWidth: 1))
    }

    private func bucketView(_ group: LimitGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.title).font(.system(size: 12, weight: .semibold))
            ForEach(Array(group.bucket.windows.enumerated()), id: \.offset) { _, window in windowRow(window) }
            if group.bucket.windows.isEmpty { Text("No usage windows available").font(.caption).foregroundStyle(.secondary) }
            if let balance = group.bucket.credits { balanceView(balance) }
            if group.bucket.rateLimitReachedType != nil { Text("Limit reached").font(.caption).foregroundStyle(.orange) }
        }
        .padding(13)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }

    private func windowRow(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title).foregroundStyle(.secondary)
                Spacer()
                Text("\(UsageFormat.percent(window.remainingPercent)) remaining").fontWeight(.medium).monospacedDigit()
            }.font(.caption).accessibilityElement(children: .combine)
            quotaBar(window)
            resetLine(window)
        }
    }

    private func quotaBar(_ window: UsageWindow) -> some View {
        let remaining = window.remainingPercent
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                if let remaining {
                    Capsule().fill(remaining <= 10 ? Color.orange : accent)
                        .frame(width: geometry.size.width * remaining / 100)
                }
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Usage remaining")
        .accessibilityValue(remaining.map { UsageFormat.percent($0) } ?? "Unavailable")
    }

    private func resetLine(_ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(window.resetDate.map { $0 <= store.now ? "Waiting for reset confirmation" : "Resets in \(UsageFormat.countdown(to: $0, now: store.now))" } ?? "Reset date unavailable", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
            if window.resetDate != nil {
                Text(UsageFormat.exactDate(window.resetDate)).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 16)
            }
        }
    }

    private func balanceView(_ balance: CreditBalance) -> some View {
        HStack {
            Text("Additional credits")
            Spacer()
            Text(balance.unlimited == true ? "Unlimited" : (balance.balance ?? "Unavailable"))
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func resetCredits(_ credits: ResetCredits?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("AVAILABLE RESETS")
                Spacer()
                Text(credits?.availableCount.map { String(max(0, $0)) } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(accent.opacity(0.1), in: Capsule())
            }
            if let details = credits?.availableDetails {
                ForEach(Array(details.enumerated()), id: \.offset) { index, credit in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Reset \(index + 1)").font(.caption).fontWeight(.medium)
                            Text(credit.expiryDate.map { $0 <= store.now ? "Expiry reached · refresh to confirm" : "Expires in \(UsageFormat.countdown(to: $0, now: store.now))" } ?? "No expiry date provided")
                                .font(.caption).foregroundStyle(.secondary)
                            if credit.expiryDate != nil { Text(UsageFormat.exactDate(credit.expiryDate)).font(.system(size: 10)).foregroundStyle(.tertiary) }
                        }
                    }
                }
                if let count = credits?.availableCount, count > details.count {
                    Text("Codex has not provided details for every reset.").font(.caption).foregroundStyle(.secondary)
                } else if details.isEmpty && credits?.availableCount == 0 {
                    Text("No resets available.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(credits == nil ? "This Codex installation has not provided this data." : "Expiry dates are unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func activity(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("ACCOUNT ACTIVITY")
            if let summary = snapshot.activity?.summary {
                VStack(spacing: 7) {
                    metric("Lifetime tokens", summary.lifetimeTokens.map { $0.formatted(.number.locale(Locale(identifier: "en_US"))) })
                    metric("Daily peak", summary.peakDailyTokens.map { $0.formatted(.number.locale(Locale(identifier: "en_US"))) })
                    metric("Current streak", summary.currentStreakDays.map { "\($0) days" })
                    metric("Longest streak", summary.longestStreakDays.map { "\($0) days" })
                    metric("Longest turn", summary.longestRunningTurnSec.flatMap { $0.isFinite && $0 >= 0 ? "\(Int(min($0 / 60, 1_000_000))) min" : nil })
                }
            }
            if let buckets = snapshot.activity?.dailyUsageBuckets, !buckets.isEmpty {
                let displayed = Array(buckets.sorted { $0.startDate < $1.startDate }.suffix(30))
                Text("Daily tokens · last \(displayed.count) available dates").font(.caption).foregroundStyle(.secondary)
                Chart(Array(displayed.enumerated()), id: \.offset) { _, bucket in
                    BarMark(x: .value("Date", bucket.startDate), y: .value("Tokens", max(0, bucket.tokens)))
                        .foregroundStyle(accent.gradient).cornerRadius(2)
                        .accessibilityLabel(bucket.startDate).accessibilityValue("\(bucket.tokens) tokens")
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(number.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US"))))
                            }
                        }
                    }
                }
                .frame(height: 100)
                HStack { Text(displayed.first?.startDate ?? ""); Spacer(); Text(displayed.last?.startDate ?? "") }
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if let notice = snapshot.activityNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            } else if snapshot.activity?.summary == nil && (snapshot.activity?.dailyUsageBuckets?.isEmpty ?? true) {
                Text("No activity statistics are available for this account.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ label: String, _ value: String?) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value ?? "—").monospacedDigit() }.font(.caption)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
    }

    private func notice(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 5) {
                Circle().fill(store.stale ? Color.orange : accent).frame(width: 5, height: 5)
                Text(store.snapshot.map { "Updated \($0.fetchedAt.formatted(date: .omitted, time: .shortened))" } ?? "No reading available")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("Read-only").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack {
                Button("Open Codex") { store.openCodex() }
                Spacer()
                Button { openSettings() } label: { Image(systemName: "gearshape") }.help("Settings").accessibilityLabel("Settings")
                Button { quit() } label: { Image(systemName: "power") }.help("Quit").accessibilityLabel("Quit CodexUsage")
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
}
