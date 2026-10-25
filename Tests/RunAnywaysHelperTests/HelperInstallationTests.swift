import Foundation
import XCTest
import RunAnywaysIPC

final class HelperInstallationTests: XCTestCase {
    func testExplicitBackendMetadataSeparatesLocalAndDistributionBuilds() throws {
        XCTAssertEqual(try backend(mode: "localDaemon", team: ""), .localDaemon)
        XCTAssertEqual(try backend(mode: "serviceManagement", team: "ABCDE12345"), .serviceManagement)
        XCTAssertThrowsError(try backend(mode: "serviceManagement", team: ""))
        XCTAssertThrowsError(try backend(mode: "localDaemon", team: "ABCDE12345"))
        XCTAssertThrowsError(try backend(mode: "unknown", team: ""))
        XCTAssertThrowsError(try backend(mode: nil, team: ""))
    }

    func testActualLaunchPlistsUseOnlyTheirExpectedFixedBackend() throws {
        let local = try plist("com.runanyways.RunAnywaysHelper.local.plist")
        let managed = try plist("com.runanyways.RunAnywaysHelper.plist")
        XCTAssertTrue(HelperInstallationBackend.localDaemon.validatesLaunchDaemonPlist(local))
        XCTAssertFalse(HelperInstallationBackend.serviceManagement.validatesLaunchDaemonPlist(local))
        XCTAssertTrue(HelperInstallationBackend.serviceManagement.validatesLaunchDaemonPlist(managed))
        XCTAssertFalse(HelperInstallationBackend.localDaemon.validatesLaunchDaemonPlist(managed))
        XCTAssertGreaterThanOrEqual(local["ExitTimeOut"] as? Int ?? 0, 15)
        XCTAssertGreaterThanOrEqual(managed["ExitTimeOut"] as? Int ?? 0, 15)

        for mutation: [String: Any] in [
            ["ProgramArguments": ["/tmp/untrusted-helper"]],
            ["ProgramArguments": [LocalDaemonManager.helperPath, "--arbitrary"]],
            ["BundleProgram": "Contents/Library/HelperTools/RunAnywaysHelper"],
            ["SpawnConstraint": [:]],
            ["EnvironmentVariables": ["DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib"]],
            ["UserName": "nobody"],
            ["MachServices": [RunAnywaysServiceIdentity.machServiceName: true, "unrelated": true]]
        ] {
            XCTAssertFalse(HelperInstallationBackend.localDaemon.validatesLaunchDaemonPlist(local.merging(mutation) { _, value in value }))
        }
    }

    func testPrivilegedScriptConstructsTheSameFixedLaunchDefinition() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/manage-helper.sh"))
        let start = try XCTUnwrap(script.range(of: "<<'RUNANYWAYS_LOCAL_PLIST'\n"))
        let end = try XCTUnwrap(script.range(of: "\nRUNANYWAYS_LOCAL_PLIST", range: start.upperBound..<script.endIndex))
        let stagedData = Data(script[start.upperBound..<end.lowerBound].utf8)
        let staged = try XCTUnwrap(PropertyListSerialization.propertyList(from: stagedData, options: [], format: nil) as? [String: Any])
        XCTAssertTrue(HelperInstallationBackend.localDaemon.validatesLaunchDaemonPlist(staged))
        XCTAssertEqual(staged as NSDictionary, try plist("com.runanyways.RunAnywaysHelper.local.plist") as NSDictionary)
    }

    func testLoadedFailedJobIsNotReportedAsRunningOrAbsent() {
        let status = LocalDaemonStatus.parse(plistInstalled: false, result: .init(exitStatus: 0, output: """
        system/com.runanyways.RunAnywaysHelper = {
          state = spawn scheduled
          last exit code = 78: EX_CONFIG
          job state = spawn failed
        }
        """))
        XCTAssertTrue(status.inspectionReliable)
        XCTAssertTrue(status.jobLoaded)
        XCTAssertFalse(status.processRunning)
        XCTAssertNil(status.processID)
        XCTAssertEqual(status.lastExitStatus, 78)
        XCTAssertFalse(status.isInstalled)
    }

    func testJobStateRequiresRunningStateAndRealPIDAndDistinguishesInspectionFailure() {
        let running = LocalDaemonStatus.parse(plistInstalled: true, result: .init(exitStatus: 0, output: "state = running\npid = 1234\nlast exit code = 0"))
        XCTAssertTrue(running.processRunning)
        XCTAssertEqual(running.processID, 1234)
        XCTAssertTrue(running.isInstalled)
        let noPID = LocalDaemonStatus.parse(plistInstalled: true, result: .init(exitStatus: 0, output: "state = running"))
        XCTAssertFalse(noPID.processRunning)
        let starting = LocalDaemonStatus.parse(plistInstalled: true, result: .init(exitStatus: 0, output: "state = starting\npid = 1234"))
        XCTAssertTrue(starting.processRunning)
        let absent = LocalDaemonStatus.parse(plistInstalled: false, result: .init(exitStatus: 113, output: "Could not find service \"com.runanyways.RunAnywaysHelper\" in domain for system"))
        XCTAssertTrue(absent.inspectionReliable)
        XCTAssertFalse(absent.jobLoaded)
        let denied = LocalDaemonStatus.parse(plistInstalled: true, result: .init(exitStatus: 1, output: "Operation not permitted"))
        XCTAssertFalse(denied.inspectionReliable)
        XCTAssertFalse(denied.processRunning)
    }

    func testInspectionUsesOnlyTheReadOnlyFixedLaunchctlCommand() {
        let runner = RecordingRunner()
        let status = LocalDaemonManager.inspect(runner: runner)
        XCTAssertEqual(runner.executable?.path, "/bin/launchctl")
        XCTAssertEqual(runner.arguments, ["print", "system/com.runanyways.RunAnywaysHelper"])
        XCTAssertEqual(runner.timeout, 5)
        XCTAssertTrue(status.inspectionReliable)
        XCTAssertFalse(status.processRunning)
    }

    func testAdministratorCommandAcceptsOnlyFixedActionsAndProtectedResource() {
        for action in [LocalDaemonAction.install, .remove] {
            let shell = LocalDaemonManager.bootstrapShell(for: action)
            XCTAssertTrue(shell.contains("exec 3< '/Applications/RunAnyways.app/Contents/Resources/manage-helper.sh'"))
            XCTAssertTrue(shell.contains("stat -L -f %u /dev/fd/3"))
            XCTAssertTrue(shell.contains("stat -L -f %HT /dev/fd/3"))
            XCTAssertTrue(shell.contains("exec /bin/bash /dev/fd/3 \(action.rawValue)"))
            let syntax = try? SystemHelperCommandRunner().run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["-n", "-c", shell], timeout: 5)
            XCTAssertEqual(syntax?.exitStatus, 0)
            XCTAssertTrue(LocalDaemonManager.authorizationScript(for: action).hasSuffix("with administrator privileges"))
        }
        XCTAssertEqual(HelperInstallationBackend.localDaemon.embeddedPlistURL(in: URL(fileURLWithPath: LocalDaemonManager.appPath)).path, "/Applications/RunAnyways.app/Contents/Library/LaunchDaemons/com.runanyways.RunAnywaysHelper.local.plist")
    }

    func testCommandRunnerKillsItsOwnUnresponsiveChildWithinBoundedTime() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SystemHelperCommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; exec /bin/sleep 10"], timeout: 0.05
        ))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
    }

    private func backend(mode: String?, team: String) throws -> HelperInstallationBackend {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("app")
        defer { try? FileManager.default.removeItem(at: directory) }
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.runanyways.TestFixture", "RunAnywaysSigningTeamID": team]
        if let mode { info[HelperInstallationBackend.infoKey] = mode }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return try HelperInstallationBackend.configured(in: directory)
    }

    private func plist(_ name: String) throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources").appendingPathComponent(name))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any])
    }
}

private final class RecordingRunner: HelperCommandRunning, @unchecked Sendable {
    var executable: URL?
    var arguments: [String]?
    var timeout: TimeInterval?
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> HelperCommandResult {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        return .init(exitStatus: 0, output: "state = spawn scheduled\nlast exit code = 78: EX_CONFIG")
    }
}
