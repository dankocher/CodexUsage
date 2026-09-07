import SwiftUI
import ServiceManagement
import UsageCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @State private var draftPath = ""
    @State private var pathError: String?
    @State private var applying = false

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $store.intervalMinutes) {
                    Text("1 minute").tag(1)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                }
                Toggle("Launch at login", isOn: Binding(get: { store.loginEnabled }, set: { store.setLoginEnabled($0) }))
                if let notice = store.loginNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            } header: { Text("General") }
            Section {
                TextField("Executable path", text: $draftPath, prompt: Text("Automatic"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityHint("Leave blank to detect Codex automatically")
                HStack {
                    Button("Choose…") { chooseExecutable() }
                    Button("Automatic") { draftPath = ""; pathError = nil }
                    Spacer()
                    Button(applying ? "Applying…" : "Apply") { applyPath() }
                        .disabled(applying)
                }
                if let pathError { Text(pathError).font(.caption).foregroundStyle(.orange) }
                Text("Uses your current Codex session. No password or API key is needed.")
                    .font(.caption).foregroundStyle(.secondary)
                if let path = try? ExecutableResolver.resolve(store.executablePath).path {
                    Text("Using: \(path)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: { Text("Codex connection") }
            Section {
                Text("The menu bar shows your general weekly allowance. Open it to see all usage groups and optional account data available in Codex.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("CodexUsage 1.0 · Independent app · Read-only")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 490, height: 445)
        .onAppear { draftPath = store.executablePath; store.syncLoginStatus() }
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the codex executable."
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { draftPath = url.path; pathError = nil }
    }

    private func applyPath() {
        do { _ = try ExecutableResolver.resolve(draftPath) }
        catch { pathError = error.localizedDescription; return }
        pathError = nil
        applying = true
        Task {
            await store.applyExecutable(draftPath)
            applying = false
        }
    }
}
