import Darwin
import Foundation

/// The build chooses the installation mechanism explicitly. An ad-hoc local
/// daemon never uses SMAppService's signed-distribution launch constraints.
public enum HelperInstallationBackend: String, Codable, Sendable {
    case localDaemon
    case serviceManagement

    public static let infoKey = "RunAnywaysHelperInstallationMode"

    public static func configured(in appURL: URL) throws -> Self {
        guard let info = Bundle(url: appURL)?.infoDictionary,
              let raw = info[infoKey] as? String,
              let backend = Self(rawValue: raw) else {
            throw RunAnywaysIPCError.invalidInstallation("The helper installation mode is missing or unsupported; rebuild and reinstall the app.")
        }
        let team = info["RunAnywaysSigningTeamID"] as? String ?? ""
        switch backend {
        case .localDaemon:
            guard team.isEmpty else {
                throw RunAnywaysIPCError.invalidInstallation("A local daemon build must use the constrained local signing configuration.")
            }
        case .serviceManagement:
            guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
                throw RunAnywaysIPCError.invalidInstallation("Service Management requires a configured distribution signing team.")
            }
        }
        return backend
    }

    public var embeddedPlistName: String {
        self == .localDaemon ? "com.runanyways.RunAnywaysHelper.local.plist" : RunAnywaysServiceIdentity.launchDaemonPlistName
    }

    public func embeddedPlistURL(in appURL: URL) -> URL {
        appURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(embeddedPlistName)")
    }

    public func validatesLaunchDaemonPlist(_ value: [String: Any]) -> Bool {
        guard value["Label"] as? String == RunAnywaysServiceIdentity.machServiceName,
              value["UserName"] as? String == "root",
              value["RunAtLoad"] as? Bool == true,
              value["KeepAlive"] as? Bool == true,
              let services = value["MachServices"] as? [String: Any],
              services.count == 1,
              services[RunAnywaysServiceIdentity.machServiceName] as? Bool == true else { return false }
        switch self {
        case .localDaemon:
            return value["ProgramArguments"] as? [String] == [LocalDaemonManager.helperPath] &&
                value["BundleProgram"] == nil && value["Program"] == nil && value["SpawnConstraint"] == nil && value["EnvironmentVariables"] == nil
        case .serviceManagement:
            return value["BundleProgram"] as? String == "Contents/Library/HelperTools/RunAnywaysHelper" &&
                value["ProgramArguments"] == nil && value["Program"] == nil
        }
    }
}

public struct LocalDaemonStatus: Codable, Equatable, Sendable {
    public let plistInstalled: Bool
    public let inspectionReliable: Bool
    public let jobLoaded: Bool
    public let processRunning: Bool
    public let processID: Int?
    public let lastExitStatus: Int?
    public let detail: String?

    public var isInstalled: Bool { plistInstalled && jobLoaded }

    public init(plistInstalled: Bool, jobLoaded: Bool, processRunning: Bool, processID: Int?, lastExitStatus: Int?, detail: String?, inspectionReliable: Bool = true) {
        self.plistInstalled = plistInstalled
        self.inspectionReliable = inspectionReliable
        self.jobLoaded = jobLoaded
        self.processRunning = processRunning
        self.processID = processID
        self.lastExitStatus = lastExitStatus
        self.detail = detail
    }

    /// launchctl print is read-only. A loaded/spawn-failed job is deliberately
    /// distinct from a running process and from an authenticated XPC response.
    public static func parse(plistInstalled: Bool, result: HelperCommandResult) -> Self {
        func field(_ name: String) -> String? {
            result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(name + " = ") }.map { String($0.dropFirst(name.count + 3)) }
        }
        let pid = field("pid").flatMap(Int.init)
        let lastExit = field("last exit code").flatMap { Int($0.split(separator: ":", maxSplits: 1)[0]) }
        let loaded = result.exitStatus == 0
        let state = field("state")
        return Self(
            plistInstalled: plistInstalled, jobLoaded: loaded,
            processRunning: loaded && (pid ?? 0) > 0,
            processID: loaded ? pid : nil, lastExitStatus: loaded ? lastExit : nil,
            detail: loaded ? state : String(result.output.prefix(4096)),
            inspectionReliable: loaded || (result.exitStatus == 113 && result.output.contains("Could not find service"))
        )
    }
}

public struct HelperCommandResult: Sendable {
    public let exitStatus: Int32
    public let output: String
    public init(exitStatus: Int32, output: String) { self.exitStatus = exitStatus; self.output = output }
}

public protocol HelperCommandRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> HelperCommandResult
}

public enum LocalDaemonAction: String, Sendable { case install, remove }

public enum LocalDaemonManager {
    public static let appPath = "/Applications/RunAnyways.app"
    public static let embeddedHelperPath = appPath + "/Contents/Library/HelperTools/RunAnywaysHelper"
    public static let helperPath = "/Library/PrivilegedHelperTools/com.runanyways.RunAnywaysHelper"
    public static let scriptPath = appPath + "/Contents/Resources/manage-helper.sh"
    public static let installedPlistPath = "/Library/LaunchDaemons/com.runanyways.RunAnywaysHelper.plist"

    public static func inspect(runner: any HelperCommandRunning = SystemHelperCommandRunner()) -> LocalDaemonStatus {
        var metadata = stat()
        let plistInstalled = lstat(installedPlistPath, &metadata) == 0 &&
            (metadata.st_mode & S_IFMT) == S_IFREG && metadata.st_uid == 0 && (metadata.st_mode & 0o022) == 0
        do {
            let result = try runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"), arguments: ["print", "system/\(RunAnywaysServiceIdentity.machServiceName)"], timeout: 5)
            return LocalDaemonStatus.parse(plistInstalled: plistInstalled, result: result)
        } catch {
            return LocalDaemonStatus(plistInstalled: plistInstalled, jobLoaded: false, processRunning: false, processID: nil, lastExitStatus: nil, detail: error.localizedDescription, inspectionReliable: false)
        }
    }

    /// Only fixed enum actions become shell text, and only the sealed script in
    /// the protected installed bundle can receive administrator authorization.
    public static func bootstrapShell(for action: LocalDaemonAction) -> String {
        // fstat an opened inode before executing it: /Applications itself is
        // admin-writable, so checking a path before the authorization prompt is
        // insufficient. Every component here is fixed by this executable.
        """
        exec 3< '\(scriptPath)'; \
        [ "$(/usr/bin/stat -L -f %u /dev/fd/3)" = 0 ] || exit 1; \
        [ "$(/usr/bin/stat -L -f %HT /dev/fd/3)" = "Regular File" ] || exit 1; \
        script_mode=$(/usr/bin/stat -L -f %Lp /dev/fd/3); \
        [ "$((8#$script_mode & 0022))" -eq 0 ] || exit 1; \
        exec /bin/bash /dev/fd/3 \(action.rawValue)
        """
    }

    public static func authorizationScript(for action: LocalDaemonAction) -> String {
        let shell = bootstrapShell(for: action)
        let quoted = "'" + shell.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let command = "/bin/bash -c " + quoted
        let appleScriptText = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(appleScriptText)\" with administrator privileges"
    }

    public static func perform(_ action: LocalDaemonAction) async throws {
        let appURL = URL(fileURLWithPath: appPath, isDirectory: true)
        try RunAnywaysPeerTrust.validateProtectedAppLocation(appURL)
        guard try HelperInstallationBackend.configured(in: appURL) == .localDaemon else {
            throw RunAnywaysIPCError.invalidInstallation("This app uses Service Management rather than the local daemon installer.")
        }
        _ = try RunAnywaysPeerTrust.requirement(for: RunAnywaysServiceIdentity.helperURL(in: appURL), expectedIdentifier: RunAnywaysServiceIdentity.helperBundleIdentifier, enclosingAppURL: appURL)
        let script = authorizationScript(for: action)
        let result = try await Task.detached(priority: .userInitiated) {
            try SystemHelperCommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], timeout: 180)
        }.value
        guard result.exitStatus == 0 else {
            throw RunAnywaysIPCError.invalidInstallation(result.output.isEmpty ? "The administrator did not complete the helper installation." : result.output)
        }
    }
}

public struct SystemHelperCommandRunner: HelperCommandRunning {
    public init() {}
    public func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> HelperCommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = CommandOutput()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            throw RunAnywaysIPCError.xpc("The helper installation command timed out.")
        }
        return HelperCommandResult(exitStatus: process.terminationStatus, output: String(data: output.data, encoding: .utf8) ?? "")
    }
    private final class CommandOutput: @unchecked Sendable { var data = Data() }
}
