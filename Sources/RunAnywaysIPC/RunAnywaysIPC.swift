import Foundation
import Darwin
import Security
import RunAnywaysCore

/// The fixed IPC surface exported by the privileged LaunchDaemon.
///
/// The wire format deliberately stays at JSON `Data` and strings so the XPC
/// interface does not expose application-defined Objective-C classes.
@objc public protocol RunAnywaysHelperProtocol {
    func fetchStatus(withReply reply: @escaping (Data?, String?) -> Void)
    func startSession(seconds: Double, unlimited: Bool, cutoff: Int, withReply reply: @escaping (Data?, String?) -> Void)
    func extendSession(seconds: Double, withReply reply: @escaping (Data?, String?) -> Void)
    func stopSession(withReply reply: @escaping (Data?, String?) -> Void)
    func heartbeat(withReply reply: @escaping (Data?, String?) -> Void)
}

public enum HelperPowerSource: String, Codable, Equatable, Sendable {
    case battery
    case ac
    case unknown
}

public enum HelperThermalCondition: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// A complete helper-authoritative status message returned for every successful
/// command. `protectionVerified` is true only after the helper read back the
/// active system sleep policy from IOPMrootDomain.
public struct HelperStatusSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let session: SessionSnapshot
    public let protectionVerified: Bool
    public let lidIsClosed: Bool
    public let batteryPercentage: Int?
    public let powerSource: HelperPowerSource
    public let thermalCondition: HelperThermalCondition
    public let lastErrorMessage: String?

    public init(
        schemaVersion: Int = 1,
        session: SessionSnapshot,
        protectionVerified: Bool,
        lidIsClosed: Bool,
        batteryPercentage: Int?,
        powerSource: HelperPowerSource,
        thermalCondition: HelperThermalCondition,
        lastErrorMessage: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.session = session
        self.protectionVerified = protectionVerified
        self.lidIsClosed = lidIsClosed
        self.batteryPercentage = batteryPercentage
        self.powerSource = powerSource
        self.thermalCondition = thermalCondition
        self.lastErrorMessage = lastErrorMessage
    }

    public static func decode(_ data: Data) throws -> HelperStatusSnapshot {
        try JSONDecoder().decode(HelperStatusSnapshot.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

public enum RunAnywaysServiceIdentity {
    public static let appBundleIdentifier = "com.runanyways.RunAnyways"
    public static let helperBundleIdentifier = "com.runanyways.RunAnywaysHelper"
    public static let machServiceName = "com.runanyways.RunAnywaysHelper"
    public static let launchDaemonPlistName = "com.runanyways.RunAnywaysHelper.plist"

    public static func helperURL(in appBundleURL: URL) -> URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("HelperTools", isDirectory: true)
            .appendingPathComponent("RunAnywaysHelper", isDirectory: false)
    }

}

public enum RunAnywaysIPCError: Error, LocalizedError {
    case invalidInstallation(String)
    case xpc(String)
    case helper(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidInstallation(let message), .xpc(let message), .helper(let message):
            return message
        case .invalidResponse:
            return "The helper returned an invalid status response."
        }
    }
}

/// Builds the code-signing requirement for a peer and validates the installed
/// bundle before using it. Signed builds pin the expected identifier and team.
/// A local ad-hoc build pins the actual CDHash, but only when the enclosing app
/// is installed in a root-owned, non-writable `/Applications` location. This
/// intentionally excludes a user-writable build tree from privileged IPC.
public enum RunAnywaysPeerTrust {
    private static let teamInfoKey = "RunAnywaysSigningTeamID"

    public static func requirement(
        for peerURL: URL,
        expectedIdentifier: String,
        enclosingAppURL: URL
    ) throws -> String {
        let appURL = enclosingAppURL.standardizedFileURL.resolvingSymlinksInPath()
        try validateProtectedAppLocation(appURL)
        _ = try HelperInstallationBackend.configured(in: appURL)
        let appInfo = try signingInformation(at: appURL)
        let appTeam = (Bundle(url: appURL)?.infoDictionary?[teamInfoKey] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        guard appInfo.identifier == RunAnywaysServiceIdentity.appBundleIdentifier else {
            throw RunAnywaysIPCError.invalidInstallation("The containing app has an unexpected code signature.")
        }

        let peerInfo = try signingInformation(at: peerURL.standardizedFileURL)
        guard peerInfo.identifier == expectedIdentifier else {
            throw RunAnywaysIPCError.invalidInstallation("The embedded helper has an unexpected code signature.")
        }

        if let appTeam {
            guard appTeam.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
                throw RunAnywaysIPCError.invalidInstallation("The configured signing team identifier is malformed.")
            }
            guard appInfo.teamIdentifier == appTeam, peerInfo.teamIdentifier == appTeam else {
                throw RunAnywaysIPCError.invalidInstallation("The app and helper are not signed by the configured development team.")
            }
            let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(appTeam)\" and identifier \"\(expectedIdentifier)\""
            try validateRequirementSyntax(requirement)
            return requirement
        }

        guard let cdhash = peerInfo.cdhash else {
            throw RunAnywaysIPCError.invalidInstallation("The ad-hoc signed helper has no verifiable code hash.")
        }
        let requirement = "cdhash H\"\(cdhash)\""
        try validateRequirementSyntax(requirement)
        return requirement
    }

    public static func validateProtectedAppLocation(_ appURL: URL) throws {
        let resolved = appURL.resolvingSymlinksInPath().standardizedFileURL.path
        let allowedPaths = ["/Applications/RunAnyways.app", "/System/Volumes/Data/Applications/RunAnyways.app"]
        guard allowedPaths.contains(resolved) else {
            throw RunAnywaysIPCError.invalidInstallation(
                "For local ad-hoc builds, install the app at /Applications/RunAnyways.app before registering the privileged helper."
            )
        }

        var info = stat()
        guard lstat(resolved, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == 0,
              (info.st_mode & 0o022) == 0 else {
            throw RunAnywaysIPCError.invalidInstallation(
                "The installed app must be a root-owned directory that is not writable by group or other users."
            )
        }

        let manager = FileManager.default
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: resolved, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
            throw RunAnywaysIPCError.invalidInstallation("Could not inspect the installed app contents.")
        }
        for case let itemURL as URL in enumerator {
            var itemInfo = stat()
            guard lstat(itemURL.path, &itemInfo) == 0,
                  itemInfo.st_uid == 0,
                  (itemInfo.st_mode & 0o022) == 0 else {
                throw RunAnywaysIPCError.invalidInstallation("The installed app contains files writable by an unprivileged user.")
            }
            let kind = itemInfo.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else {
                throw RunAnywaysIPCError.invalidInstallation("The installed app contains a symlink or special file.")
            }
        }
        if enumerationError != nil {
            throw RunAnywaysIPCError.invalidInstallation("Could not inspect every item in the installed app.")
        }
    }

    private static func validateRequirementSyntax(_ requirement: String) throws {
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &parsed)
        guard status == errSecSuccess, parsed != nil else {
            throw RunAnywaysIPCError.invalidInstallation("The peer code-signing requirement is malformed.")
        }
    }

    private static func signingInformation(at url: URL) throws -> SigningInformation {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw RunAnywaysIPCError.invalidInstallation("Code at \(url.path) is not signed.")
        }

        let validation = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard validation == errSecSuccess else {
            throw RunAnywaysIPCError.invalidInstallation("Code signature validation failed for \(url.lastPathComponent).")
        }

        var rawInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation)
        guard infoStatus == errSecSuccess, let rawInformation,
              let dictionary = rawInformation as? [String: Any] else {
            throw RunAnywaysIPCError.invalidInstallation("Could not read the code-signing identity for \(url.lastPathComponent).")
        }

        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let hash = (dictionary[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        guard let identifier else {
            throw RunAnywaysIPCError.invalidInstallation("The code signature has no identifier.")
        }
        return SigningInformation(identifier: identifier, teamIdentifier: team, cdhash: hash)
    }

    private struct SigningInformation {
        let identifier: String
        let teamIdentifier: String?
        let cdhash: String?
    }
}

/// Async client for the fixed helper API. Construct only from the signed app
/// bundle so the helper connection is pinned to its embedded executable.
public final class RunAnywaysHelperClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let stateLock = NSLock()
    private var isInvalidated = false

    public init() throws {
        let appURL = Bundle.main.bundleURL
        let helperURL = RunAnywaysServiceIdentity.helperURL(in: appURL)
        let requirement = try RunAnywaysPeerTrust.requirement(
            for: helperURL,
            expectedIdentifier: RunAnywaysServiceIdentity.helperBundleIdentifier,
            enclosingAppURL: appURL
        )
        let connection = NSXPCConnection(machServiceName: RunAnywaysServiceIdentity.machServiceName, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: RunAnywaysHelperProtocol.self)
        connection.resume()
        self.connection = connection
    }

    deinit {
        connection.invalidate()
    }

    public func fetchStatus() async throws -> HelperStatusSnapshot {
        try await request { $0.fetchStatus(withReply: $1) }
    }

    public func startSession(seconds: TimeInterval?, cutoffPercentage: Int) async throws -> HelperStatusSnapshot {
        try await request {
            $0.startSession(seconds: seconds ?? 0, unlimited: seconds == nil, cutoff: cutoffPercentage, withReply: $1)
        }
    }

    public func extendSession(seconds: TimeInterval) async throws -> HelperStatusSnapshot {
        try await request { $0.extendSession(seconds: seconds, withReply: $1) }
    }

    public func stopSession() async throws -> HelperStatusSnapshot {
        try await request { $0.stopSession(withReply: $1) }
    }

    public func heartbeat() async throws -> HelperStatusSnapshot {
        try await request { $0.heartbeat(withReply: $1) }
    }

    public func invalidate() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isInvalidated else { return }
        isInvalidated = true
        connection.invalidate()
    }

    private func request(
        _ invoke: @escaping (RunAnywaysHelperProtocol, @escaping (Data?, String?) -> Void) -> Void
    ) async throws -> HelperStatusSnapshot {
        let invalidated = connectionIsInvalidated()
        guard !invalidated else { throw RunAnywaysIPCError.xpc("The helper connection has been invalidated.") }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperStatusSnapshot, Error>) in
            let gate = CompletionGate()
            let timeout = DispatchWorkItem {
                guard gate.claim() else { return }
                continuation.resume(throwing: RunAnywaysIPCError.xpc("The helper did not respond within 10 seconds."))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeout)

            let complete: (Result<HelperStatusSnapshot, Error>) -> Void = { result in
                guard gate.claim() else { return }
                timeout.cancel()
                continuation.resume(with: result)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                // Preserve NSCocoaErrorDomain/code and debugDescription so the
                // installed diagnostic CLI can distinguish launch/auth failures.
                complete(.failure(error))
            }
            guard let helper = proxy as? RunAnywaysHelperProtocol else {
                complete(.failure(RunAnywaysIPCError.xpc("The helper connection is unavailable.")))
                return
            }
            invoke(helper) { data, error in
                if let error {
                    complete(.failure(RunAnywaysIPCError.helper(error)))
                } else if let data, let snapshot = try? HelperStatusSnapshot.decode(data) {
                    complete(.success(snapshot))
                } else {
                    complete(.failure(RunAnywaysIPCError.invalidResponse))
                }
            }
        }
    }

    private func connectionIsInvalidated() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isInvalidated
    }

    private final class CompletionGate {
        private let lock = NSLock()
        private var completed = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}
