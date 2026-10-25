import Darwin
import Foundation
import Security
import ServiceManagement
import RunAnywaysCore
import RunAnywaysIPC

struct HelperSetupInspection {
    let resources: HelperSetupResources
    let installationBackend: HelperInstallationBackend?
    let backendConfigurationError: String?
    let appURL: URL
    let appBundleIdentifier: String?
    let appSignature: CodeSignatureInspection
    let appExecutableSignature: CodeSignatureInspection
    let helperExecutableURL: URL
    let helperSignature: CodeSignatureInspection
    let installedLocalHelperExecutableURL: URL?
    let installedLocalHelperPresent: Bool?
    let installedLocalHelperRootOwned: Bool?
    let installedLocalHelperWritableByGroupOrOther: Bool?
    let installedLocalHelperSignature: CodeSignatureInspection?
    let launchDaemonPlistURL: URL
    let launchDaemonPlistPresent: Bool
    let launchDaemonPlistValid: Bool
    let protectedLocationValid: Bool
    let peerTrustError: String?
    let resourceErrors: [String]

    var detailMessage: String? {
        if !resourceErrors.isEmpty { return resourceErrors.joined(separator: " ") }
        return peerTrustError
    }

    var jsonObject: [String: Any] {
        [
            "app": [
                "path": appURL.path,
                "bundleIdentifier": appBundleIdentifier as Any? ?? NSNull(),
                "signature": appSignature.jsonObject,
                "mainExecutable": appExecutableSignature.jsonObject
            ],
            "helper": [
                "path": helperExecutableURL.path,
                "present": resources.helperExecutablePresent,
                "signature": helperSignature.jsonObject,
                "embeddedPath": helperExecutableURL.path,
                "embeddedPresent": resources.helperExecutablePresent,
                "embeddedSignature": helperSignature.jsonObject
            ],
            "installedLocalHelper": installedLocalHelperExecutableURL.map { url in
                [
                    "path": url.path,
                    "present": installedLocalHelperPresent as Any? ?? NSNull(),
                    "rootOwned": installedLocalHelperRootOwned as Any? ?? NSNull(),
                    "writableByGroupOrOther": installedLocalHelperWritableByGroupOrOther as Any? ?? NSNull(),
                    "signature": installedLocalHelperSignature?.jsonObject as Any? ?? NSNull()
                ] as [String: Any]
            } as Any? ?? NSNull(),
            "launchDaemon": [
                "plistPath": launchDaemonPlistURL.path,
                "plistPresent": launchDaemonPlistPresent,
                "plistValid": launchDaemonPlistValid,
                "machService": RunAnywaysServiceIdentity.machServiceName
            ],
            "installationBackend": installationBackend?.rawValue as Any? ?? NSNull(),
            "resourceChecks": [
                "helperExecutablePresent": resources.helperExecutablePresent,
                "launchDaemonPlistPresent": resources.launchDaemonPlistPresent,
                "metadataValid": resources.metadataValid,
                "backendConfigurationError": backendConfigurationError as Any? ?? NSNull(),
                "protectedLocationValid": protectedLocationValid,
                "peerTrustError": peerTrustError as Any? ?? NSNull(),
                "errors": resourceErrors
            ]
        ]
    }
}

struct CodeSignatureInspection {
    let valid: Bool
    let identifier: String?
    let teamIdentifier: String?
    let cdhash: String?
    let status: Int32

    var jsonObject: [String: Any] {
        [
            "valid": valid,
            "identifier": identifier as Any? ?? NSNull(),
            "teamIdentifier": teamIdentifier as Any? ?? NSNull(),
            "cdhash": cdhash as Any? ?? NSNull(),
            "status": status
        ]
    }

    static func inspect(at url: URL) -> CodeSignatureInspection {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard createStatus == errSecSuccess, let code else {
            return CodeSignatureInspection(valid: false, identifier: nil, teamIdentifier: nil, cdhash: nil, status: createStatus)
        }

        let validationStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        var rawInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &rawInformation)
        let values = (infoStatus == errSecSuccess ? rawInformation as? [String: Any] : nil)
        let hash = (values?[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        return CodeSignatureInspection(
            valid: validationStatus == errSecSuccess,
            identifier: values?[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: values?[kSecCodeInfoTeamIdentifier as String] as? String,
            cdhash: hash,
            status: validationStatus == errSecSuccess ? infoStatus : validationStatus
        )
    }
}

enum HelperSetupDiagnostics {
    static func inspect(appURL: URL) -> HelperSetupInspection {
        let standardizedAppURL = appURL.standardizedFileURL
        let helperURL = RunAnywaysServiceIdentity.helperURL(in: standardizedAppURL)
        let installationBackend: HelperInstallationBackend?
        let backendConfigurationError: String?
        do {
            installationBackend = try HelperInstallationBackend.configured(in: standardizedAppURL)
            backendConfigurationError = nil
        } catch {
            installationBackend = nil
            backendConfigurationError = error.localizedDescription
        }
        let daemonPlistURL = (installationBackend ?? .serviceManagement).embeddedPlistURL(in: standardizedAppURL)
        let appExecutableURL = standardizedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("RunAnyways")
        let appBundleIdentifier = Bundle(url: standardizedAppURL)?.bundleIdentifier
        let appSignature = CodeSignatureInspection.inspect(at: standardizedAppURL)
        let appExecutableSignature = CodeSignatureInspection.inspect(at: appExecutableURL)
        let helperSignature = CodeSignatureInspection.inspect(at: helperURL)
        let helperPresent = isExecutableRegularFile(helperURL)
        let installedLocalHelperExecutableURL = installationBackend == .localDaemon
            ? URL(fileURLWithPath: LocalDaemonManager.helperPath)
            : nil
        let installedLocalHelperMetadata = installedLocalHelperExecutableURL.flatMap(executableFileMetadata)
        let installedLocalHelperSignature = installedLocalHelperMetadata == nil
            ? nil
            : installedLocalHelperExecutableURL.map(CodeSignatureInspection.inspect(at:))
        let plistPresent = isRegularFile(daemonPlistURL)
        let plistValid = plistPresent && validLaunchDaemonPlist(
            at: daemonPlistURL,
            backend: installationBackend ?? .serviceManagement
        )
        let protectedLocationValid: Bool
        do {
            try RunAnywaysPeerTrust.validateProtectedAppLocation(standardizedAppURL)
            protectedLocationValid = true
        } catch {
            protectedLocationValid = false
        }

        var peerTrustError: String?
        do {
            _ = try RunAnywaysPeerTrust.requirement(
                for: helperURL,
                expectedIdentifier: RunAnywaysServiceIdentity.helperBundleIdentifier,
                enclosingAppURL: standardizedAppURL
            )
        } catch {
            peerTrustError = error.localizedDescription
        }

        var errors: [String] = []
        if appBundleIdentifier != RunAnywaysServiceIdentity.appBundleIdentifier {
            errors.append("The app bundle identifier is missing or unexpected.")
        }
        if let backendConfigurationError {
            errors.append(backendConfigurationError)
        }
        if !helperPresent { errors.append("The embedded helper executable is missing, not a regular file, or not executable.") }
        if !plistPresent { errors.append("The embedded LaunchDaemon plist is missing.") }
        else if !plistValid { errors.append("The LaunchDaemon plist is malformed or does not describe the expected service.") }
        if !appSignature.valid { errors.append("The app bundle code signature is invalid (status \(appSignature.status)).") }
        if !appExecutableSignature.valid || appExecutableSignature.identifier != RunAnywaysServiceIdentity.appBundleIdentifier {
            errors.append("The app executable signature is invalid or has an unexpected identifier (status \(appExecutableSignature.status)).")
        }
        if !helperSignature.valid || helperSignature.identifier != RunAnywaysServiceIdentity.helperBundleIdentifier {
            errors.append("The helper signature is invalid or has an unexpected identifier (status \(helperSignature.status)).")
        }
        if !protectedLocationValid {
            errors.append("The app is not installed at the protected /Applications location required by the helper.")
        }
        if let peerTrustError { errors.append(peerTrustError) }

        let metadataValid = installationBackend != nil &&
            appBundleIdentifier == RunAnywaysServiceIdentity.appBundleIdentifier &&
            plistValid && appSignature.valid && appExecutableSignature.valid &&
            appExecutableSignature.identifier == RunAnywaysServiceIdentity.appBundleIdentifier &&
            helperSignature.valid && helperSignature.identifier == RunAnywaysServiceIdentity.helperBundleIdentifier &&
            protectedLocationValid && peerTrustError == nil
        let resources = HelperSetupResources(
            helperExecutablePresent: helperPresent,
            launchDaemonPlistPresent: plistPresent,
            metadataValid: metadataValid
        )
        return HelperSetupInspection(
            resources: resources,
            installationBackend: installationBackend,
            backendConfigurationError: backendConfigurationError,
            appURL: standardizedAppURL,
            appBundleIdentifier: appBundleIdentifier,
            appSignature: appSignature,
            appExecutableSignature: appExecutableSignature,
            helperExecutableURL: helperURL,
            helperSignature: helperSignature,
            installedLocalHelperExecutableURL: installedLocalHelperExecutableURL,
            installedLocalHelperPresent: installedLocalHelperExecutableURL.map { _ in installedLocalHelperMetadata != nil },
            installedLocalHelperRootOwned: installedLocalHelperMetadata.map { $0.owner == 0 },
            installedLocalHelperWritableByGroupOrOther: installedLocalHelperMetadata.map { ($0.mode & 0o022) != 0 },
            installedLocalHelperSignature: installedLocalHelperSignature,
            launchDaemonPlistURL: daemonPlistURL,
            launchDaemonPlistPresent: plistPresent,
            launchDaemonPlistValid: plistValid,
            protectedLocationValid: protectedLocationValid,
            peerTrustError: peerTrustError,
            resourceErrors: errors
        )
    }

    private static func isExecutableRegularFile(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 &&
            (metadata.st_mode & S_IFMT) == S_IFREG &&
            access(url.path, X_OK) == 0
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFREG
    }

    private static func executableFileMetadata(_ url: URL) -> (owner: uid_t, mode: mode_t)? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              access(url.path, X_OK) == 0 else { return nil }
        return (metadata.st_uid, metadata.st_mode)
    }

    private static func validLaunchDaemonPlist(at url: URL, backend: HelperInstallationBackend) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else {
            return false
        }
        return backend.validatesLaunchDaemonPlist(dictionary)
    }
}

enum HelperSetupCommandLine {
    private static let commandFlags = [
        "--helper-status", "--register-helper", "--probe-helper", "--unregister-managed-helper"
    ]

    static func runIfRequested(
        arguments: [String],
        appURL: URL,
        service: SMAppService
    ) async -> Int32? {
        let registerRequested = arguments.contains("--register-helper")
        let probeRequested = arguments.contains("--probe-helper")
        let unregisterRequested = arguments.contains("--unregister-managed-helper")
        let requested = commandFlags.filter(arguments.contains)
        guard !requested.isEmpty else { return nil }

        let inspection = HelperSetupDiagnostics.inspect(appURL: appURL)
        if requested.count != 1 || arguments.contains("--preview") {
            let message = requested.count != 1
                ? "Choose one helper command at a time."
                : "Helper commands cannot be combined with --preview."
            printJSON([
                "schemaVersion": 1,
                "mode": "invalid-command-line",
                "inspection": inspection.jsonObject,
                "registrationAttempted": false,
                "unregistrationAttempted": false,
                "error": ["domain": "RunAnywaysCommandLine", "code": 2, "message": message]
            ])
            return 2
        }

        if probeRequested {
            return await probeHelper(inspection: inspection, appURL: appURL, service: service)
        }
        if unregisterRequested {
            return await unregisterManagedHelper(inspection: inspection, appURL: appURL, service: service)
        }

        var report: [String: Any] = [
            "schemaVersion": 1,
            "mode": registerRequested ? "register-helper" : "helper-status",
            "installationBackend": inspection.installationBackend?.rawValue as Any? ?? NSNull(),
            "serviceManagement": [
                "statusRawValue": service.status.rawValue,
                "status": statusName(service.status),
                "plistName": RunAnywaysServiceIdentity.launchDaemonPlistName,
                "machService": RunAnywaysServiceIdentity.machServiceName
            ],
            "inspection": inspection.jsonObject
        ]

        if inspection.installationBackend == .localDaemon {
            report["backendStatus"] = localDaemonStatusObject(LocalDaemonManager.inspect())
        }

        guard registerRequested else {
            printJSON(report)
            return 0
        }

        guard inspection.installationBackend == .serviceManagement else {
            report["registrationAttempted"] = false
            report["registrationError"] = [
                "domain": "RunAnywaysInstallationBackend",
                "code": 1,
                "message": "This local build uses the administrator-managed LaunchDaemon installer."
            ]
            printJSON(report)
            return 1
        }

        do {
            try RunAnywaysPeerTrust.validateProtectedAppLocation(appURL)
        } catch {
            report["registrationAttempted"] = false
            report["registrationError"] = errorObject(error)
            printJSON(report)
            return 1
        }
        guard inspection.resources.areUsable else {
            report["registrationAttempted"] = false
            report["registrationError"] = [
                "domain": "RunAnywaysSetupPreflight",
                "code": 1,
                "message": inspection.detailMessage ?? "The embedded helper resources are not valid."
            ]
            printJSON(report)
            return 1
        }

        report["registrationAttempted"] = true
        do {
            try service.register()
            report["registrationError"] = NSNull()
        } catch {
            report["registrationError"] = errorObject(error)
        }
        report["serviceManagement"] = [
            "statusRawValue": service.status.rawValue,
            "status": statusName(service.status),
            "plistName": RunAnywaysServiceIdentity.launchDaemonPlistName,
            "machService": RunAnywaysServiceIdentity.machServiceName
        ]
        printJSON(report)
        if service.status == .enabled || service.status == .requiresApproval {
            return 0
        }
        return 1
    }

    private static func probeHelper(
        inspection: HelperSetupInspection,
        appURL: URL,
        service: SMAppService
    ) async -> Int32 {
        let backendStatus = await inspectBackendStatus()
        let result = await readHelperStatus()
        let safeToUnload = result.status.map {
            !$0.session.isActive && !$0.protectionVerified && $0.lastErrorMessage == nil
        } ?? false
        var report: [String: Any] = [
            "schemaVersion": 1,
            "mode": "probe-helper",
            "installationBackend": inspection.installationBackend?.rawValue as Any? ?? NSNull(),
            "reachable": result.status != nil,
            "helperStatus": result.status.map(snapshotObject) ?? NSNull(),
            "safeToUnload": safeToUnload,
            "backendStatus": backendStatus,
            "serviceManagement": [
                "statusRawValue": service.status.rawValue,
                "status": statusName(service.status),
                "plistName": RunAnywaysServiceIdentity.launchDaemonPlistName
            ],
            "inspection": inspection.jsonObject
        ]
        if let error = result.error { report["error"] = errorObject(error) }
        printJSON(report)
        return result.status == nil ? 1 : 0
    }

    private static func unregisterManagedHelper(
        inspection: HelperSetupInspection,
        appURL: URL,
        service: SMAppService
    ) async -> Int32 {
        var report: [String: Any] = [
            "schemaVersion": 1,
            "mode": "unregister-managed-helper",
            "installationBackend": inspection.installationBackend?.rawValue as Any? ?? NSNull(),
            "serviceManagement": [
                "statusRawValue": service.status.rawValue,
                "status": statusName(service.status),
                "plistName": RunAnywaysServiceIdentity.launchDaemonPlistName
            ],
            "inspection": inspection.jsonObject,
            "unregistrationAttempted": false
        ]

        guard inspection.installationBackend == .localDaemon else {
            report["error"] = [
                "domain": "RunAnywaysInstallationBackend",
                "code": 1,
                "message": "Managed helper migration is available only from a local-daemon build."
            ]
            printJSON(report)
            return 1
        }
        do {
            try RunAnywaysPeerTrust.validateProtectedAppLocation(appURL)
        } catch {
            report["error"] = errorObject(error)
            printJSON(report)
            return 1
        }
        guard inspection.resources.areUsable else {
            report["error"] = [
                "domain": "RunAnywaysSetupPreflight",
                "code": 1,
                "message": inspection.detailMessage ?? "The installed app's helper resources are not valid."
            ]
            printJSON(report)
            return 1
        }
        guard service.status == .enabled || service.status == .requiresApproval else {
            report["unregistrationAttempted"] = false
            report["result"] = "No managed Service Management registration is present."
            printJSON(report)
            return 0
        }

        let backendStatus = await inspectBackendStatus()
        let probe = await readHelperStatus()
        report["backendStatus"] = backendStatus
        report["reachable"] = probe.status != nil
        report["helperStatus"] = probe.status.map(snapshotObject) ?? NSNull()
        if let error = probe.error { report["probeError"] = errorObject(error) }

        if let status = probe.status {
            guard !status.session.isActive,
                  !status.protectionVerified,
                  status.lastErrorMessage == nil else {
                report["error"] = [
                    "domain": "RunAnywaysUnsafeRemoval",
                    "code": 1,
                    "message": "The helper reports an active session or pending sleep restoration. Stop the session and verify normal sleep before migration."
                ]
                printJSON(report)
                return 1
            }
        } else if !backendConfirmsNoRunningProcess(backendStatus) {
            report["error"] = [
                "domain": "RunAnywaysUnsafeRemoval",
                "code": 1,
                "message": "The helper could not be queried and launchd does not confirm that its process is stopped."
            ]
            printJSON(report)
            return 1
        }

        report["unregistrationAttempted"] = true
        do {
            try await service.unregister()
            let finalStatus = await waitForUnregistered(service)
            report["serviceManagement"] = [
                "statusRawValue": finalStatus.rawValue,
                "status": statusName(finalStatus),
                "plistName": RunAnywaysServiceIdentity.launchDaemonPlistName
            ]
            report["unregistrationError"] = NSNull()
            let completed = finalStatus == .notRegistered || finalStatus == .notFound
            report["unregistered"] = completed
            if !completed {
                report["error"] = [
                    "domain": "RunAnywaysServiceManagement",
                    "code": 1,
                    "message": "Service Management did not confirm that the old registration was removed."
                ]
            }
            printJSON(report)
            return completed ? 0 : 1
        } catch {
            report["unregistrationError"] = errorObject(error)
            printJSON(report)
            return 1
        }
    }

    private static func readHelperStatus() async -> (status: HelperStatusSnapshot?, error: Error?) {
        do {
            let client = try RunAnywaysHelperClient()
            defer { client.invalidate() }
            return (try await client.fetchStatus(), nil)
        } catch {
            return (nil, error)
        }
    }

    private static func inspectBackendStatus() async -> [String: Any] {
        let status = await Task.detached(priority: .utility) {
            LocalDaemonManager.inspect()
        }.value
        return localDaemonStatusObject(status)
    }

    private static func backendConfirmsNoRunningProcess(_ object: [String: Any]) -> Bool {
        guard object["inspectionReliable"] as? Bool == true,
              let processRunning = object["processRunning"] as? Bool,
              !processRunning,
              object["processID"] is NSNull || object["processID"] == nil else {
            return false
        }
        guard let loaded = object["jobLoaded"] as? Bool else { return false }
        if loaded {
            return object["lastExitStatus"] is NSNumber
        }
        let detail = (object["detail"] as? String ?? "").lowercased()
        return ["could not find service", "no such process", "service not found"].contains { detail.contains($0) }
    }

    private static func localDaemonStatusObject(_ status: LocalDaemonStatus) -> [String: Any] {
        [
            "plistInstalled": status.plistInstalled,
            "jobLoaded": status.jobLoaded,
            "inspectionReliable": status.inspectionReliable,
            "processRunning": status.processRunning,
            "processID": status.processID as Any? ?? NSNull(),
            "lastExitStatus": status.lastExitStatus as Any? ?? NSNull(),
            "detail": status.detail as Any? ?? NSNull()
        ]
    }

    private static func snapshotObject(_ status: HelperStatusSnapshot) -> Any {
        guard let data = try? status.encoded(),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return NSNull()
        }
        return value
    }

    private static func waitForUnregistered(_ service: SMAppService) async -> SMAppService.Status {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = service.status
            if status == .notRegistered || status == .notFound { return status }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return service.status
    }

    private static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered: "notRegistered"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    private static func errorObject(_ error: Error) -> [String: Any] {
        let nsError = error as NSError
        var value: [String: Any] = [
            "domain": nsError.domain,
            "code": nsError.code,
            "message": nsError.localizedDescription,
            "debugDescription": nsError.userInfo[NSDebugDescriptionErrorKey] as? String ?? String(reflecting: nsError)
        ]
        if let reason = nsError.localizedFailureReason { value["failureReason"] = reason }
        if let suggestion = nsError.localizedRecoverySuggestion { value["recoverySuggestion"] = suggestion }
        return value
    }

    private static func printJSON(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            print("{\"error\":\"Could not encode helper diagnostics as JSON.\"}")
            return
        }
        print(text)
    }
}
