import AppKit
import SwiftUI
import ServiceManagement
import UsageCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state = UsageState()
    @Published private(set) var isRefreshing = false
    @Published var now = Date()
    @Published var intervalMinutes: Int {
        didSet {
            defaults.set(intervalMinutes, forKey: "refreshMinutes")
            policy.interval = Double(intervalMinutes * 60)
        }
    }
    @Published private(set) var executablePath: String
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNotice: String?
    @Published var actionNotice: String?
    private let defaults: UserDefaults
    private var policy = RefreshPolicy()
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    var didChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: "refreshMinutes")
        intervalMinutes = [1, 5, 15].contains(saved) ? saved : 5
        executablePath = defaults.string(forKey: "executablePath") ?? ""
        policy.interval = Double(intervalMinutes * 60)
        syncLoginStatus()
    }

    var snapshot: UsageSnapshot? { state.snapshot }
    var stale: Bool {
        state.error != nil || snapshot.map { now.timeIntervalSince($0.fetchedAt) > Double(intervalMinutes * 60 + 30) } == true
    }
    var statusTitle: String {
        UsageFormat.statusTitle(window: snapshot?.limits.weekly,
                                resetsAvailable: snapshot?.limits.rateLimitResetCredits?.availableCount,
                                stale: stale, now: now)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.now = Date()
                self?.refresh()
            }
        }
        refresh()
    }

    func menuOpened() {
        now = Date()
        syncLoginStatus()
        if !isRefreshing && policy.shouldRefresh(now: now, snapshot: snapshot, menuOpened: true) { refresh() }
    }

    private func tick() {
        now = Date()
        if !isRefreshing && policy.shouldRefresh(now: now, snapshot: snapshot) { refresh() }
        didChange?()
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        policy.lastAttempt = Date()
        let client = AppServerClient(executablePath: executablePath)
        refreshTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { [weak self] in
                try await client.fetch { [weak self] account in
                    await self?.observe(account)
                }
            }
            do {
                let value = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                if !Task.isCancelled { self?.state.accept(value) }
            } catch is CancellationError {
                // App shutdown/settings change intentionally cancels the old connection.
            } catch {
                if !Task.isCancelled {
                    if let clientError = error as? ClientError, clientError.isAuthenticationFailure { self?.state.clear() }
                    self?.state.fail(error.localizedDescription)
                }
            }
            self?.now = Date()
            self?.isRefreshing = false
            self?.didChange?()
        }
    }

    private func observe(_ account: Account?) {
        state.observeAccount(account)
        didChange?()
    }

    func applyExecutable(_ path: String) async {
        refreshTask?.cancel()
        await refreshTask?.value
        executablePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(executablePath, forKey: "executablePath")
        state.clear()
        policy.reset()
        refresh()
    }

    func stop() async {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        refreshTask?.cancel()
        await refreshTask?.value
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            syncLoginStatus()
        } catch {
            syncLoginStatus()
            loginNotice = "Could not change launch at login. Move the app to Applications and try again."
        }
    }

    func syncLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled || status == .requiresApproval
        loginNotice = status == .requiresApproval ? "Allow CodexUsage in System Settings → General → Login Items." : nil
    }

    func openCodex() {
        let workspace = NSWorkspace.shared
        let candidates = ["com.openai.codex", "com.openai.chat", "com.openai.chatgpt"]
        let known = candidates.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
        let paths = ["/Applications/Codex.app", "/Applications/ChatGPT.app", NSHomeDirectory() + "/Applications/Codex.app"]
        let url = known ?? paths.first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
        guard let url else { actionNotice = "The Codex app was not found. Open your installation and sign in."; return }
        workspace.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            if error != nil { Task { @MainActor in self?.actionNotice = "Could not open Codex." } }
        }
    }
}
