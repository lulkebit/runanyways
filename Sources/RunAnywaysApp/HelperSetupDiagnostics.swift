import Darwin
import Foundation
import Security
import ServiceManagement
import RunAnywaysCore
import RunAnywaysIPC

struct HelperSetupInspection {
    let resources: HelperSetupResources
    let appURL: URL
    let appBundleIdentifier: String?
    let appSignature: CodeSignatureInspection
    let appExecutableSignature: CodeSignatureInspection
    let helperExecutableURL: URL
    let helperSignature: CodeSignatureInspection
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
                "signature": helperSignature.jsonObject
            ],
            "launchDaemon": [
                "plistPath": launchDaemonPlistURL.path,
                "plistPresent": launchDaemonPlistPresent,
                "plistValid": launchDaemonPlistValid,
                "machService": RunAnywaysServiceIdentity.machServiceName
            ],
            "resourceChecks": [
                "helperExecutablePresent": resources.helperExecutablePresent,
                "launchDaemonPlistPresent": resources.launchDaemonPlistPresent,
                "metadataValid": resources.metadataValid,
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
        let daemonPlistURL = standardizedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchDaemons", isDirectory: true)
            .appendingPathComponent(RunAnywaysServiceIdentity.launchDaemonPlistName)
        let appExecutableURL = standardizedAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("RunAnyways")
        let appBundleIdentifier = Bundle(url: standardizedAppURL)?.bundleIdentifier
        let appSignature = CodeSignatureInspection.inspect(at: standardizedAppURL)
        let appExecutableSignature = CodeSignatureInspection.inspect(at: appExecutableURL)
        let helperSignature = CodeSignatureInspection.inspect(at: helperURL)
        let helperPresent = isExecutableRegularFile(helperURL)
        let plistPresent = isRegularFile(daemonPlistURL)
        let plistValid = plistPresent && validLaunchDaemonPlist(at: daemonPlistURL)
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

        let metadataValid = appBundleIdentifier == RunAnywaysServiceIdentity.appBundleIdentifier &&
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
            appURL: standardizedAppURL,
            appBundleIdentifier: appBundleIdentifier,
            appSignature: appSignature,
            appExecutableSignature: appExecutableSignature,
            helperExecutableURL: helperURL,
            helperSignature: helperSignature,
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

    private static func validLaunchDaemonPlist(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any],
              dictionary["Label"] as? String == RunAnywaysServiceIdentity.machServiceName,
              dictionary["BundleProgram"] as? String == "Contents/Library/HelperTools/RunAnywaysHelper",
              dictionary["UserName"] as? String == "root",
              dictionary["RunAtLoad"] as? Bool == true,
              let machServices = dictionary["MachServices"] as? [String: Any],
              machServices[RunAnywaysServiceIdentity.machServiceName] as? Bool == true else {
            return false
        }
        return true
    }
}

enum HelperSetupCommandLine {
    static func runIfRequested(
        arguments: [String],
        appURL: URL,
        service: SMAppService
    ) -> Int32? {
        let statusRequested = arguments.contains("--helper-status")
        let registerRequested = arguments.contains("--register-helper")
        guard statusRequested || registerRequested else { return nil }

        let inspection = HelperSetupDiagnostics.inspect(appURL: appURL)
        if (statusRequested && registerRequested) || (registerRequested && arguments.contains("--preview")) {
            let message = statusRequested && registerRequested
                ? "Choose either --helper-status or --register-helper, not both."
                : "--register-helper cannot be combined with --preview."
            let conflictReport: [String: Any] = [
                "schemaVersion": 1,
                "mode": "invalid-command-line",
                "serviceManagement": [
                    "statusRawValue": service.status.rawValue,
                    "status": statusName(service.status)
                ],
                "inspection": inspection.jsonObject,
                "registrationAttempted": false,
                "error": ["domain": "RunAnywaysCommandLine", "code": 2, "message": message]
            ]
            printJSON(conflictReport)
            return 2
        }
        var report: [String: Any] = [
            "schemaVersion": 1,
            "mode": registerRequested ? "register-helper" : "helper-status",
            "serviceManagement": [
                "statusRawValue": service.status.rawValue,
                "status": statusName(service.status),
                "plistName": RunAnywaysServiceIdentity.launchDaemonPlistName,
                "machService": RunAnywaysServiceIdentity.machServiceName
            ],
            "inspection": inspection.jsonObject
        ]

        guard registerRequested else {
            printJSON(report)
            return 0
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
            "message": nsError.localizedDescription
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
