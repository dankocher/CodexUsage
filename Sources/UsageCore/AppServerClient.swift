import Foundation
import Darwin

public enum ClientError: Error, LocalizedError, Equatable, Sendable {
    case executableMissing, launchFailed, timeout, disconnected, invalidResponse
    case rpc(Int, String)
    case signedOut, unsupportedAccount

    public var errorDescription: String? {
        switch self {
        case .executableMissing: "Codex was not found. Select its executable in Settings."
        case .launchFailed: "Could not start Codex. Check the executable in Settings."
        case .timeout: "Codex did not respond in time. Please try again."
        case .disconnected: "The connection to Codex was interrupted."
        case .invalidResponse: "Codex returned an unsupported response."
        case .signedOut: "Sign in to Codex, then click Refresh."
        case .unsupportedAccount: "Usage limits require a ChatGPT account signed in to Codex."
        case let .rpc(code, _): "Could not query Codex (\(code)). Check your sign-in and connection."
        }
    }

    public var isUnsupportedMethod: Bool {
        if case let .rpc(code, message) = self {
            return code == -32601 || (code == -32600 && message.contains("unknown variant"))
        }
        return false
    }
    public var isAuthenticationFailure: Bool {
        if case let .rpc(code, message) = self {
            let lower = message.lowercased()
            return code == 401 || lower.contains("unauthorized") || lower.contains("not authenticated")
                || lower.contains("authentication required") || lower.contains("token expired")
        }
        return self == .signedOut
    }
}

public enum ExecutableResolver {
    public static func resolve(_ configured: String = "") throws -> URL {
        let value = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if !value.isEmpty {
            let path = (value as NSString).expandingTildeInPath
            if path.hasPrefix("/") {
                guard fm.isExecutableFile(atPath: path) else { throw ClientError.executableMissing }
                return URL(fileURLWithPath: path)
            }
            // A bare executable name is searched, never evaluated by a shell.
            guard !path.contains("/") else { throw ClientError.executableMissing }
            for directory in searchDirectories {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(path)
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
            throw ClientError.executableMissing
        }
        for path in bundledCandidates {
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw ClientError.executableMissing
    }

    public static var bundledCandidates: [String] {
        ["/Applications/Codex.app/Contents/Resources/codex",
         "/Applications/ChatGPT.app/Contents/Resources/codex",
         NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex"]
    }
    private static var searchDirectories: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/usr/bin", "/bin"]
    }
}

/// Single-owner, bounded stdio JSON-RPC transport. Used exclusively on a background task.
/// No prompts, credentials or raw server errors are logged or persisted.
final class RPCConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private let timeout: TimeInterval
    private var closed = false
    private var started = false
    private let maxResponseBytes = 8 * 1_024 * 1_024

    init(executable: URL, timeout: TimeInterval, arguments: [String] = ["app-server", "--listen", "stdio://"]) throws {
        self.timeout = timeout
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClientError.launchFailed }
        started = true
        // Closing parent copies is essential for reliable EOF detection.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        if started { process.waitUntilExit() }
        try? output.fileHandleForReading.close()
    }

    func notify(_ method: String) throws {
        try send(["method": method])
    }

    func request<T: Decodable>(_ method: String, params: [String: Any]? = nil, as type: T.Type = T.self) throws -> T {
        try Task.checkCancellation()
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var totalBytes = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ClientError.invalidResponse }
                guard let responseID = envelope["id"] as? Int, responseID == id else { continue }
                if let error = envelope["error"] as? [String: Any] {
                    throw ClientError.rpc(error["code"] as? Int ?? -1, error["message"] as? String ?? "")
                }
                guard let result = envelope["result"], JSONSerialization.isValidJSONObject(result),
                      let data = try? JSONSerialization.data(withJSONObject: result),
                      let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw ClientError.invalidResponse }
                return decoded
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remainingMS = max(1, min(100, Int((deadline - ProcessInfo.processInfo.systemUptime) * 1_000)))
            let ready = poll(&descriptor, 1, Int32(remainingMS))
            if ready < 0 {
                if errno == EINTR { continue }
                throw ClientError.disconnected
            }
            if ready == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count == 0 { throw ClientError.disconnected }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw ClientError.disconnected
            }
            totalBytes += count
            guard totalBytes <= maxResponseBytes else { throw ClientError.invalidResponse }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw ClientError.timeout
    }

    private func send(_ message: [String: Any]) throws {
        guard process.isRunning else { throw ClientError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { throw ClientError.disconnected }
    }
}

public struct AppServerClient: Sendable {
    public var executablePath: String
    public var timeout: TimeInterval
    var processArguments = ["app-server", "--listen", "stdio://"]
    public init(executablePath: String = "", timeout: TimeInterval = 15) {
        self.executablePath = executablePath; self.timeout = timeout
    }

    /// The callback clears a previous account's data before subsequent network requests.
    public func fetch(onAccount: @Sendable (Account?) async -> Void = { _ in }) async throws -> UsageSnapshot {
        let executable = try ExecutableResolver.resolve(executablePath)
        let connection = try RPCConnection(executable: executable, timeout: timeout, arguments: processArguments)
        defer { connection.close() }
        struct Empty: Decodable {}
        let _: Empty = try connection.request("initialize", params: ["clientInfo": ["name": "codex_usage", "title": "CodexUsage", "version": "1.0.0"]])
        try connection.notify("initialized")
        let response: AccountResponse = try connection.request("account/read", params: ["refreshToken": false])
        await onAccount(response.account)
        guard let account = response.account else { throw ClientError.signedOut }
        guard ["chatgpt", "chatgptAuthTokens"].contains(account.type) else { throw ClientError.unsupportedAccount }
        let limits: RateLimitsResponse = try connection.request("account/rateLimits/read")
        let fetchedAt = Date()
        var activity: ActivityResponse?
        var notice: String?
        do {
            activity = try connection.request("account/usage/read")
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let clientError = error as? ClientError, clientError.isUnsupportedMethod {
                notice = "This version of Codex does not support activity statistics yet."
            } else {
                notice = "Activity could not be refreshed. Usage limits are up to date."
            }
        }
        return UsageSnapshot(account: account, limits: limits, activity: activity, activityNotice: notice, fetchedAt: fetchedAt, executable: executable.path)
    }
}
