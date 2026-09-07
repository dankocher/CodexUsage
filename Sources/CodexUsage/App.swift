import AppKit
import SwiftUI
import UsageCore

@main
enum CodexUsageApp {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--check") {
            // Integration check uses the same client as the UI and emits no account IDs/email/tokens.
            let args = CommandLine.arguments
            let path = args.firstIndex(of: "--codex").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? ""
            Task.detached {
                do {
                    let snapshot = try await AppServerClient(executablePath: path).fetch()
                    let summary: [String: Any] = [
                        "executable": snapshot.executable,
                        "statusBar": UsageFormat.statusTitle(window: snapshot.limits.weekly, stale: false),
                        "groups": snapshot.limits.groups.map { ["id": $0.id, "windows": $0.bucket.windows.map { ["minutes": $0.windowDurationMins ?? 0, "remaining": $0.remainingPercent ?? -1] as [String: Any] }] },
                        "resetCreditsAvailable": snapshot.limits.rateLimitResetCredits?.availableCount as Any? ?? NSNull(),
                        "activityAvailable": snapshot.activity != nil,
                        "activityNotice": snapshot.activityNotice as Any? ?? NSNull()
                    ]
                    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    exit(0)
                } catch {
                    print("Error: \(error.localizedDescription)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        // Reopening from Finder must not create a second status item/process.
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.setAccessibilityLabel("Codex weekly usage")
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 650)
        popover.contentViewController = NSHostingController(rootView: UsagePanel(store: store, openSettings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) }))
        store.didChange = { [weak self] in self?.updateStatus() }
        updateStatus()
        store.start()
        if CommandLine.arguments.contains("--show-panel") { togglePanel() }
    }

    private func updateStatus() {
        statusItem.button?.title = store.statusTitle
        let description = "Weekly usage remaining: \(UsageFormat.percent(store.snapshot?.limits.weekly?.remainingPercent)). Reset: \(UsageFormat.countdown(to: store.snapshot?.limits.weekly?.resetDate, now: store.now)).\(store.stale ? " Data is out of date." : "")"
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityValue(description)
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem.button else { return }
        store.menuOpened()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 445), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CodexUsage Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(store: store))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        store.syncLoginStatus()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePanel() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await store.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
