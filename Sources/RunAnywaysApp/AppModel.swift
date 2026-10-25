import Foundation
import AppKit
import ServiceManagement
import SwiftUI
import RunAnywaysCore
import RunAnywaysIPC

enum SessionLengthChoice: String, CaseIterable, Identifiable, Hashable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case twoHours
    case custom
    case unlimited

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes: return "30 min"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .custom: return "Custom"
        case .unlimited: return "Unlimited"
        }
    }

    func seconds(customMinutes: Int) -> TimeInterval? {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .twoHours: return 2 * 60 * 60
        case .custom: return TimeInterval(min(max(customMinutes, 1), 24 * 60)) * 60
        case .unlimited: return nil
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let helperPlistName = RunAnywaysServiceIdentity.launchDaemonPlistName
    private static let protectionFreshnessLimit: TimeInterval = 15

    @Published private(set) var helperStatus: HelperStatusSnapshot?
    @Published private(set) var setupStatus = SMAppService.daemon(plistName: RunAnywaysServiceIdentity.launchDaemonPlistName).status
    @Published private(set) var lastError: String?
    @Published private(set) var commandError: String?
    @Published private(set) var serviceActionMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var nowUptime = ProcessInfo.processInfo.systemUptime
    @Published var selectedLength: SessionLengthChoice = .thirtyMinutes
    @Published var customMinutes = 90
    @Published var cutoffPercentage: Int = {
        let saved = UserDefaults.standard.integer(forKey: "cutoffPercentage")
        return (Session.minimumCutoffPercentage...Session.maximumCutoffPercentage).contains(saved)
            ? saved
            : Session.defaultCutoffPercentage
    }()

    let isPreview = ProcessInfo.processInfo.arguments.contains("--preview")

    private var client: RunAnywaysHelperClient?
    private var heartbeatTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private let helperService = SMAppService.daemon(plistName: RunAnywaysServiceIdentity.launchDaemonPlistName)
    private let helperInspection = HelperSetupDiagnostics.inspect(appURL: Bundle.main.bundleURL)
    private var lastStatusUptime: TimeInterval?
    private var didStart = false
    private var sessionActivity: NSObjectProtocol?
    private let installIssue: String? = {
        do {
            try RunAnywaysPeerTrust.validateProtectedAppLocation(Bundle.main.bundleURL)
            return nil
        } catch {
            return "\(error.localizedDescription) To install a local build, run ./scripts/install-local.sh from the source folder, then open /Applications/RunAnyways.app."
        }
    }()

    deinit {
        heartbeatTask?.cancel()
        clockTask?.cancel()
        if let sessionActivity {
            ProcessInfo.processInfo.endActivity(sessionActivity)
        }
    }

    func start() {
        guard !isPreview, !didStart else { return }
        didStart = true
        refreshSetupStatus()
        Task { await refreshStatus() }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.nowUptime = ProcessInfo.processInfo.systemUptime
            }
        }
    }

    private var helperSetupState: HelperSetupState {
        switch setupStatus {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    private var helperSetupDecision: HelperSetupDecision {
        HelperSetupPolicy.decision(for: helperSetupState, resources: helperInspection.resources)
    }

    var hasRegisteredHelper: Bool { helperSetupDecision == .enabled }
    var needsHelperApproval: Bool { helperSetupDecision == .requiresApproval }
    var helperSetupAllowsRegistration: Bool { helperSetupDecision == .register && installIssue == nil }
    var canRegisterHelper: Bool {
        !isPreview && !isBusy && helperSetupAllowsRegistration
    }
    var canQuit: Bool { !isBusy }
    var hasActiveSession: Bool { helperStatus?.session.isActive == true }
    var protectionIsVerified: Bool { helperStatus?.protectionVerified == true }
    var hasRestoreError: Bool { lastError != nil || helperStatus?.lastErrorMessage != nil }

    var hasVerifiedProtection: Bool {
        guard hasRegisteredHelper,
              protectionIsVerified,
              helperStatus?.lastErrorMessage == nil,
              let session = helperStatus?.session,
              session.isActive else {
            return false
        }
        guard let lastStatusUptime,
              nowUptime - lastStatusUptime <= Self.protectionFreshnessLimit,
              lastError == nil else {
            return false
        }
        if session.state == .running,
           session.remainingSeconds != nil,
           displayedRemainingSeconds == 0 {
            return false
        }
        return true
    }

    var canStartSession: Bool {
        !isPreview && !isBusy && installIssue == nil && hasRegisteredHelper && !hasActiveSession &&
            lastError == nil && helperStatus?.lastErrorMessage == nil &&
            (selectedLength != .custom || (1...24 * 60).contains(customMinutes)) &&
            (Session.minimumCutoffPercentage...Session.maximumCutoffPercentage).contains(cutoffPercentage)
    }

    var canExtendSession: Bool {
        !isPreview && !isBusy && installIssue == nil && hasRegisteredHelper && hasVerifiedProtection &&
            helperStatus?.session.canExtend == true
    }

    var canStopSession: Bool {
        !isPreview && !isBusy && hasRegisteredHelper &&
            (hasActiveSession || helperStatus?.lastErrorMessage != nil || lastError != nil)
    }

    var canRetryRestore: Bool {
        helperStatus?.lastErrorMessage != nil || lastError != nil
    }

    var canDisableHelper: Bool {
        !isPreview && !isBusy && installIssue == nil && hasRegisteredHelper && !hasActiveSession &&
            !protectionIsVerified && helperStatus != nil &&
            helperStatus?.lastErrorMessage == nil && lastError == nil
    }

    var displayedRemainingSeconds: TimeInterval? {
        guard let session = helperStatus?.session,
              let remaining = session.remainingSeconds else {
            return nil
        }
        guard session.state == .running, let lastStatusUptime else { return remaining }
        return max(0, remaining - max(0, nowUptime - lastStatusUptime))
    }

    var menuBarSymbol: String {
        guard hasVerifiedProtection, let session = helperStatus?.session else {
            return isPreview ? "eye" : "moon.zzz"
        }
        switch session.state {
        case .running: return "bolt.fill"
        case .paused: return "pause.circle.fill"
        case .armed: return "clock.fill"
        case .idle, .ended, .failed: return "moon.zzz"
        }
    }

    var menuBarTitle: String? {
        guard hasVerifiedProtection, let session = helperStatus?.session else {
            return nil
        }
        if session.remainingSeconds == nil { return "∞" }
        guard let seconds = displayedRemainingSeconds else { return nil }
        let minutes = max(0, Int(ceil(seconds / 60)))
        return "\(minutes)m"
    }

    var menuBarAccessibilityLabel: String {
        guard hasVerifiedProtection, let session = helperStatus?.session else {
            return isPreview ? "RunAnyways preview; protection is off" : "RunAnyways; protection is not verified"
        }
        switch session.state {
        case .running:
            return session.remainingSeconds == nil
                ? "RunAnyways is keeping the Mac awake with no time limit"
                : "RunAnyways is keeping the Mac awake; \(Self.formattedDuration(displayedRemainingSeconds ?? 0)) remaining"
        case .paused:
            return "RunAnyways is paused while the lid is open"
        case .armed:
            return "RunAnyways is ready for the lid to close"
        case .idle, .ended, .failed:
            return "RunAnyways; no active protection"
        }
    }

    var mainStatusTitle: String {
        if isPreview { return "Preview" }
        guard let snapshot = helperStatus else {
            return hasRegisteredHelper ? "Connecting to helper…" : "Helper setup needed"
        }
        if snapshot.lastErrorMessage != nil { return "Sleep restore needs attention" }
        let session = snapshot.session
        guard session.isActive else {
            switch session.state {
            case .failed:
                return "Protection stopped"
            case .ended:
                switch session.endReason {
                case .lowBattery: return "Stopped at battery cutoff"
                case .thermalPressure: return "Stopped for thermal pressure"
                case .expired: return "Session complete"
                case .stopped, .none: return "Session stopped"
                }
            case .idle, .armed, .running, .paused:
                return "Ready for a session"
            }
        }
        guard hasVerifiedProtection else { return "Protection not verified" }
        switch session.state {
        case .armed: return "Ready when the lid closes"
        case .running: return "Keeping your Mac awake"
        case .paused: return "Paused while the lid is open"
        case .idle, .ended, .failed: return "Ready for a session"
        }
    }

    var mainStatusDetail: String {
        if isPreview { return "This preview does not contact or enable the helper." }
        if let installIssue, !hasRegisteredHelper { return installIssue }
        guard let snapshot = helperStatus else {
            if needsHelperApproval { return "Approve RunAnyways in System Settings to continue." }
            if canRegisterHelper { return "Enable the background helper to use lid-close protection." }
            if let helperSetupMessage { return helperSetupMessage }
            return lastError ?? "Waiting for the background helper to respond."
        }
        let session = snapshot.session
        if let helperError = snapshot.lastErrorMessage {
            return "\(helperError) Use Retry sleep restore, then verify that normal sleep is back on."
        }
        if session.isActive && !hasVerifiedProtection {
            return "The helper has not verified the sleep setting. No active protection is claimed."
        }
        switch session.state {
        case .armed: return "The countdown starts when the lid closes."
        case .running:
            if session.remainingSeconds == nil { return "Unlimited session · \(powerSourceDescription)" }
            return "\(Self.formattedDuration(displayedRemainingSeconds ?? 0)) left · \(powerSourceDescription)"
        case .paused: return "The countdown resumes the next time the lid closes."
        case .ended:
            if let reason = session.endReason {
                switch reason {
                case .lowBattery:
                    return "Battery reached \(session.cutoffPercentage)% · normal sleep restored."
                case .thermalPressure:
                    return "Normal sleep restored due to thermal pressure."
                case .expired:
                    return "The selected time elapsed · normal sleep restored."
                case .stopped:
                    return "Normal sleep restored."
                }
            }
            return "Normal sleep restored."
        case .failed:
            return session.failureMessage ?? snapshot.lastErrorMessage ?? lastError ?? "The helper stopped protection."
        case .idle:
            return "Choose a duration, then close the lid to start the countdown."
        }
    }

    var powerSourceDescription: String {
        switch helperStatus?.powerSource {
        case .battery: return "Battery"
        case .ac: return "Power adapter"
        case .unknown, .none: return "Power source unknown"
        }
    }

    var thermalNotice: (text: String, isWarning: Bool)? {
        switch helperStatus?.thermalCondition {
        case .serious: return ("Thermal pressure: serious", true)
        case .critical: return ("Thermal pressure: critical", true)
        case .fair: return ("Thermal pressure: fair", false)
        case .nominal, .unknown, .none: return nil
        }
    }

    var batteryDescription: String? {
        guard let percentage = helperStatus?.batteryPercentage else { return nil }
        return "Battery \(percentage)%"
    }

    var helperSetupDescription: String {
        if installIssue != nil { return "Install in /Applications first" }
        switch helperSetupDecision {
        case .enabled: return "Background helper enabled"
        case .requiresApproval: return "Approval required in System Settings"
        case .register: return "Background helper not enabled"
        case .unavailable: return "Helper resources need repair"
        case .unknown: return "Helper status unavailable"
        }
    }

    var helperSetupMessage: String? {
        if let installIssue { return installIssue }
        switch helperSetupDecision {
        case .requiresApproval:
            return "Approve RunAnyways in System Settings to continue."
        case .register:
            return setupStatus == .notFound
                ? "macOS has not registered this service yet. Enable the helper to continue."
                : "Enable the background helper to use lid-close protection."
        case .unavailable:
            return helperInspection.detailMessage ?? "The helper executable or LaunchDaemon plist is missing or invalid. Rebuild and install RunAnyways again."
        case .enabled, .unknown:
            return nil
        }
    }

    var helperResourcesUnavailable: Bool { helperSetupDecision == .unavailable }

    func registerHelper() {
        guard canRegisterHelper, beginMutation() else { return }
        defer { isBusy = false }
        lastError = nil
        commandError = nil
        serviceActionMessage = nil
        do {
            try helperService.register()
            refreshSetupStatus()
            switch helperSetupDecision {
            case .requiresApproval:
                serviceActionMessage = "macOS registered the helper. Approve it in System Settings before starting a session."
            case .enabled:
                serviceActionMessage = "Helper enabled. Waiting for its verified status…"
                Task { await refreshStatus() }
            case .register:
                serviceActionMessage = "macOS returned from registration but still reports no registered service. Use the read-only helper diagnostics from Terminal for details."
            case .unavailable:
                serviceActionMessage = helperInspection.detailMessage ?? "The embedded helper resources are not valid. Rebuild and install RunAnyways again."
            case .unknown:
                serviceActionMessage = "macOS returned an unrecognized helper status. Use the read-only helper diagnostics from Terminal for details."
            }
        } catch {
            refreshSetupStatus()
            let nsError = error as NSError
            var detail = "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
            if let reason = nsError.localizedFailureReason { detail += " \(reason)" }
            if let suggestion = nsError.localizedRecoverySuggestion { detail += " \(suggestion)" }
            if setupStatus == .requiresApproval {
                serviceActionMessage = "macOS requires approval before the helper can run. \(detail)"
            } else {
                serviceActionMessage = "macOS did not register the helper. \(detail)"
            }
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func unregisterHelper() {
        guard canDisableHelper, beginMutation() else { return }
        Task {
            defer { isBusy = false }
            do {
                let restoredStatus = try await helperClient().stopSession()
                accept(restoredStatus)
                guard !restoredStatus.session.isActive,
                      !restoredStatus.protectionVerified,
                      restoredStatus.lastErrorMessage == nil else {
                    lastError = "The helper has not confirmed that normal sleep is restored."
                    return
                }
                try await helperService.unregister()
                refreshSetupStatus()
                helperStatus = nil
                lastStatusUptime = nil
                serviceActionMessage = "Background helper disabled."
                lastError = nil
                commandError = nil
            } catch {
                await handleAsyncError(error)
            }
        }
    }

    func quit() {
        guard !isBusy else { return }
        guard !isPreview else {
            NSApp.terminate(nil)
            return
        }
        guard hasActiveSession || canRetryRestore else {
            NSApp.terminate(nil)
            return
        }
        guard beginMutation() else { return }
        Task {
            defer { isBusy = false }
            do {
                let restoredStatus = try await helperClient().stopSession()
                accept(restoredStatus)
                guard !restoredStatus.session.isActive,
                      !restoredStatus.protectionVerified,
                      restoredStatus.lastErrorMessage == nil else {
                    lastError = "Normal sleep was not confirmed; RunAnyways is staying open so you can retry."
                    return
                }
                NSApp.terminate(nil)
            } catch {
                await handleAsyncError(error)
            }
        }
    }

    func startSession() {
        guard canStartSession, beginMutation() else { return }
        UserDefaults.standard.set(cutoffPercentage, forKey: "cutoffPercentage")
        let seconds = selectedLength.seconds(customMinutes: customMinutes)
        Task {
            defer { isBusy = false }
            do {
                accept(try await helperClient().startSession(seconds: seconds, cutoffPercentage: cutoffPercentage))
                lastError = nil
                commandError = nil
                serviceActionMessage = nil
            } catch {
                await handleAsyncError(error)
            }
        }
    }

    func extendSession() {
        guard canExtendSession, beginMutation() else { return }
        Task {
            defer { isBusy = false }
            do {
                accept(try await helperClient().extendSession(seconds: 15 * 60))
                lastError = nil
                commandError = nil
            } catch {
                await handleAsyncError(error)
            }
        }
    }

    func stopSession() {
        guard canStopSession, beginMutation() else { return }
        Task {
            defer { isBusy = false }
            do {
                accept(try await helperClient().stopSession())
                lastError = nil
                commandError = nil
            } catch {
                await handleAsyncError(error)
            }
        }
    }

    func refreshSetupStatus() {
        setupStatus = helperService.status
        guard hasRegisteredHelper else {
            client?.invalidate()
            client = nil
            helperStatus = nil
            lastStatusUptime = nil
            endSessionActivity()
            return
        }
    }

    private func refreshStatus() async {
        refreshSetupStatus()
        guard hasRegisteredHelper else { return }
        do {
            let status: HelperStatusSnapshot
            if helperStatus?.session.isActive == true {
                status = try await helperClient().heartbeat()
            } else {
                status = try await helperClient().fetchStatus()
            }
            accept(status)
            lastError = nil
        } catch {
            if case RunAnywaysIPCError.helper(let message) = error {
                do {
                    let status = try await helperClient().fetchStatus()
                    accept(status)
                    lastError = nil
                    commandError = status.session.isActive ? message : nil
                } catch {
                    handleTransportError(error)
                }
            } else {
                await handleAsyncError(error)
            }
        }
    }

    private func helperClient() throws -> RunAnywaysHelperClient {
        if let client { return client }
        let newClient = try RunAnywaysHelperClient()
        client = newClient
        return newClient
    }

    private func accept(_ status: HelperStatusSnapshot) {
        helperStatus = status
        lastStatusUptime = ProcessInfo.processInfo.systemUptime
        if status.session.isActive {
            beginSessionActivity()
        } else {
            endSessionActivity()
        }
    }

    private func show(_ error: Error) {
        handleTransportError(error)
    }

    private func handleTransportError(_ error: Error) {
        lastError = error.localizedDescription
        commandError = nil
        client?.invalidate()
        client = nil
        helperStatus = nil
        lastStatusUptime = nil
        endSessionActivity()
    }

    private func handleAsyncError(_ error: Error) async {
        if case RunAnywaysIPCError.helper(let message) = error {
            commandError = message
            do {
                let status = try await helperClient().fetchStatus()
                accept(status)
                lastError = nil
            } catch {
                handleTransportError(error)
            }
            return
        }
        handleTransportError(error)
    }

    private func beginMutation() -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        commandError = nil
        return true
    }

    private func beginSessionActivity() {
        guard sessionActivity == nil else { return }
        sessionActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Maintain an active RunAnyways session"
        )
    }

    private func endSessionActivity() {
        guard let sessionActivity else { return }
        ProcessInfo.processInfo.endActivity(sessionActivity)
        self.sessionActivity = nil
    }

    static func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
