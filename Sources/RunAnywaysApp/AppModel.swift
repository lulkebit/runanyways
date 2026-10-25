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
    @Published private(set) var connectionError: String?
    @Published private(set) var localDaemonStatus: LocalDaemonStatus?
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
    private let installationBackend = try? HelperInstallationBackend.configured(in: Bundle.main.bundleURL)
    private let backendConfigurationError: String? = {
        do {
            _ = try HelperInstallationBackend.configured(in: Bundle.main.bundleURL)
            return nil
        } catch {
            return error.localizedDescription
        }
    }()
    private var lastStatusUptime: TimeInterval?
    private var didStart = false
    private var didAttemptConnection = false
    private var knownSessionNeedsCleanup = false
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
        guard let installationBackend,
              let policyBackend = HelperSetupBackend(rawValue: installationBackend.rawValue) else {
            return .unavailable
        }
        return HelperSetupPolicy.decision(
            backend: policyBackend,
            serviceManagementState: helperSetupState,
            resources: helperInspection.resources,
            localDaemonPlistInstalled: localDaemonStatus?.plistInstalled ?? false,
            localDaemonJobLoaded: localDaemonStatus?.jobLoaded ?? false
        )
    }

    var hasRegisteredHelper: Bool { helperSetupDecision == .enabled }
    var isLocalDaemonBackend: Bool { installationBackend == .localDaemon }
    var needsHelperApproval: Bool {
        installationBackend == .serviceManagement && helperSetupDecision == .requiresApproval
    }
    var helperSetupAllowsRegistration: Bool {
        installationBackend == .serviceManagement && helperSetupDecision == .register && installIssue == nil
    }
    var canRegisterHelper: Bool {
        !isPreview && !isBusy && helperSetupAllowsRegistration && !requiresCleanupBeforeTeardown
    }
    var canQuit: Bool { !isBusy }
    var hasActiveSession: Bool { helperStatus?.session.isActive == true }
    var protectionIsVerified: Bool { helperStatus?.protectionVerified == true }
    var hasRestoreError: Bool { helperStatus?.lastErrorMessage != nil }
    var lastError: String? { connectionError }
    var isConnectionUnavailable: Bool { connectionError != nil }
    var canRetryConnection: Bool { !isPreview && !isBusy && hasRegisteredHelper && connectionError != nil }

    private var recoveryState: HelperRecoveryState {
        HelperRecoveryState(
            isReachable: helperStatus != nil && connectionError == nil,
            hasKnownActiveSession: knownSessionNeedsCleanup && helperStatus?.session.isActive == true,
            helperReportsRestorationFailure: helperStatus?.lastErrorMessage != nil
        )
    }

    private var requiresCleanupBeforeTeardown: Bool {
        HelperRecoveryPolicy.requiresCleanupBeforeTeardown(recoveryState)
    }

    var hasPendingCleanup: Bool { requiresCleanupBeforeTeardown }

    private var launchdConfirmsNoHelperProcess: Bool {
        guard let status = localDaemonStatus,
              status.inspectionReliable,
              !status.processRunning,
              status.processID == nil else { return false }
        if status.jobLoaded { return status.lastExitStatus != nil }
        let detail = (status.detail ?? "").lowercased()
        return detail.contains("could not find service")
    }

    private var safeNoSessionEvidence: Bool {
        if let helperStatus, connectionError == nil {
            return !helperStatus.session.isActive &&
                !helperStatus.protectionVerified &&
                helperStatus.lastErrorMessage == nil
        }
        return launchdConfirmsNoHelperProcess
    }

    var localHelperActionTitle: String {
        helperSetupDecision == .installLocalDaemon ? "Install local helper" : "Repair helper"
    }

    var canRetryRestore: Bool {
        HelperRecoveryPolicy.action(for: recoveryState) == .retryRestore
    }

    var canRepairHelper: Bool {
        guard !isPreview, !isBusy, installIssue == nil,
              HelperRecoveryPolicy.canRepairOrRemoveHelper(recoveryState) else { return false }
        switch installationBackend {
        case .localDaemon:
            if helperSetupDecision == .installLocalDaemon { return true }
            return (helperSetupDecision == .repairLocalDaemon || helperSetupDecision == .enabled) &&
                safeNoSessionEvidence
        case .serviceManagement:
            return helperSetupDecision == .enabled && connectionError != nil && safeNoSessionEvidence
        case .none:
            return false
        }
    }

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
              connectionError == nil else {
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
            connectionError == nil && helperStatus?.lastErrorMessage == nil &&
            (selectedLength != .custom || (1...24 * 60).contains(customMinutes)) &&
            (Session.minimumCutoffPercentage...Session.maximumCutoffPercentage).contains(cutoffPercentage)
    }

    var canExtendSession: Bool {
        !isPreview && !isBusy && installIssue == nil && hasRegisteredHelper && hasVerifiedProtection &&
            connectionError == nil && helperStatus?.session.canExtend == true
    }

    var canStopSession: Bool {
        !isPreview && !isBusy && (hasActiveSession || canRetryRestore)
    }

    var canDisableHelper: Bool {
        guard !isPreview, !isBusy, installIssue == nil,
              HelperRecoveryPolicy.canRepairOrRemoveHelper(recoveryState) else { return false }
        switch installationBackend {
        case .localDaemon:
            let backendPresent = localDaemonStatus?.plistInstalled == true ||
                helperService.status == .enabled || helperService.status == .requiresApproval
            return backendPresent && safeNoSessionEvidence
        case .serviceManagement:
            return (setupStatus == .enabled || setupStatus == .requiresApproval) && safeNoSessionEvidence
        case .none:
            return false
        }
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
        if connectionError != nil {
            return knownSessionNeedsCleanup ? "Session connection lost" : "Background helper unavailable"
        }
        guard let snapshot = helperStatus else {
            if hasRegisteredHelper && !didAttemptConnection { return "Connecting to helper…" }
            return "Helper setup needed"
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
        if let connectionError {
            if knownSessionNeedsCleanup {
                return "The helper became unreachable during a session. Its last known state is retained; reconnect and stop to confirm normal sleep is restored. \(connectionError)"
            }
            return "The background helper is installed but unavailable. Retry the read-only connection check or repair the helper. \(connectionError)"
        }
        if let installIssue, !hasRegisteredHelper { return installIssue }
        guard let snapshot = helperStatus else {
            if needsHelperApproval { return "Approve RunAnyways in System Settings to continue." }
            if canRegisterHelper { return "Enable the background helper to use lid-close protection." }
            if let helperSetupMessage { return helperSetupMessage }
            return connectionError ?? "Waiting for the background helper to respond."
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
            return session.failureMessage ?? snapshot.lastErrorMessage ?? connectionError ?? "The helper stopped protection."
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
        if connectionError != nil && !knownSessionNeedsCleanup { return "Background helper unavailable" }
        if installationBackend == .localDaemon {
            switch helperSetupDecision {
            case .enabled: return "Local background helper installed"
            case .installLocalDaemon: return "Local background helper not installed"
            case .repairLocalDaemon: return "Local background helper needs repair"
            case .unavailable: return "Helper resources need repair"
            case .requiresApproval, .register, .unknown: return "Local helper setup unavailable"
            }
        }
        switch helperSetupDecision {
        case .enabled: return "Background helper enabled"
        case .requiresApproval: return "Approval required in System Settings"
        case .register: return "Background helper not enabled"
        case .installLocalDaemon, .repairLocalDaemon: return "Local helper setup unavailable"
        case .unavailable: return "Helper resources need repair"
        case .unknown: return "Helper status unavailable"
        }
    }

    var helperSetupMessage: String? {
        if let backendConfigurationError { return backendConfigurationError }
        if let installIssue { return installIssue }
        if connectionError != nil && !knownSessionNeedsCleanup { return connectionError }
        if installationBackend == .localDaemon {
            switch helperSetupDecision {
            case .installLocalDaemon:
                return "Install the local background helper to enable lid-close sessions."
            case .repairLocalDaemon:
                return localDaemonStatus?.detail ?? "The local helper is not loaded. Repair it to continue."
            case .unavailable:
                return helperInspection.detailMessage ?? "The embedded helper resources are missing or invalid. Rebuild and install RunAnyways again."
            case .enabled:
                return localDaemonStatus?.detail
            case .requiresApproval, .register, .unknown:
                return "The local helper installation state could not be determined."
            }
        }
        switch helperSetupDecision {
        case .requiresApproval:
            return "Approve RunAnyways in System Settings to continue."
        case .register:
            return setupStatus == .notFound
                ? "macOS has not registered this service yet. Enable the helper to continue."
                : "Enable the background helper to use lid-close protection."
        case .unavailable:
            return helperInspection.detailMessage ?? "The helper executable or LaunchDaemon plist is missing or invalid. Rebuild and install RunAnyways again."
        case .enabled, .installLocalDaemon, .repairLocalDaemon, .unknown:
            return nil
        }
    }

    var helperResourcesUnavailable: Bool { helperSetupDecision == .unavailable }

    func registerHelper() {
        guard canRegisterHelper, beginMutation() else { return }
        Task {
            defer { isBusy = false }
            connectionError = nil
            commandError = nil
            serviceActionMessage = nil
            do {
                try helperService.register()
                await refreshSetupStatus()
                switch helperSetupDecision {
                case .requiresApproval:
                    serviceActionMessage = "macOS registered the helper. Approve it in System Settings before starting a session."
                case .enabled:
                    serviceActionMessage = "Helper enabled. Waiting for its verified status…"
                    await refreshStatus()
                case .register:
                    serviceActionMessage = "macOS returned from registration but still reports no registered service. Use the read-only helper diagnostics from Terminal for details."
                case .unavailable:
                    serviceActionMessage = helperInspection.detailMessage ?? "The embedded helper resources are not valid. Rebuild and install RunAnyways again."
                case .installLocalDaemon, .repairLocalDaemon:
                    serviceActionMessage = "This build uses the local LaunchDaemon installation path."
                case .unknown:
                    serviceActionMessage = "macOS returned an unrecognized helper status. Use the read-only helper diagnostics from Terminal for details."
                }
            } catch {
                await refreshSetupStatus()
                if helperSetupDecision == .requiresApproval {
                    serviceActionMessage = "macOS requires approval for RunAnyways. Approve the background helper in System Settings before starting a session."
                } else if helperSetupDecision == .enabled {
                    serviceActionMessage = "macOS reports the helper enabled. Checking its authenticated status…"
                    await refreshStatus()
                } else {
                    serviceActionMessage = registrationErrorMessage(error)
                }
            }
        }
    }

    func repairHelper() {
        guard canRepairHelper, beginMutation() else { return }
        Task {
            defer { isBusy = false }
            serviceActionMessage = nil
            commandError = nil
            do {
                switch installationBackend {
                case .localDaemon:
                    try await removeManagedRegistrationForMigration()
                    try await LocalDaemonManager.perform(.install)
                    await refreshSetupStatus()
                    serviceActionMessage = "The local helper installer completed. Checking the helper connection…"
                    await refreshStatus()
                case .serviceManagement:
                    guard helperService.status == .enabled || helperService.status == .requiresApproval else {
                        try helperService.register()
                        await refreshSetupStatus()
                        await refreshStatus()
                        return
                    }
                    try await helperService.unregister()
                    let removed = await waitForManagedUnregistration()
                    guard removed else { throw HelperAppActionError.registrationDidNotChange }
                    try helperService.register()
                    await refreshSetupStatus()
                    serviceActionMessage = "The managed helper registration was repaired. Checking the helper connection…"
                    await refreshStatus()
                case .none:
                    throw HelperAppActionError.backendUnavailable(backendConfigurationError ?? "Helper installation mode is unavailable.")
                }
            } catch {
                await refreshSetupStatus()
                if helperSetupDecision == .requiresApproval {
                    serviceActionMessage = "macOS requires approval for RunAnyways. Approve the background helper in System Settings before starting a session."
                } else {
                    serviceActionMessage = registrationErrorMessage(error)
                }
            }
        }
    }

    func retryConnection() {
        guard canRetryConnection, beginMutation() else { return }
        Task {
            defer { isBusy = false }
            didAttemptConnection = true
            do {
                accept(try await helperClient().fetchStatus())
                commandError = nil
                serviceActionMessage = nil
            } catch {
                await handleAsyncError(error)
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
            if requiresCleanupBeforeTeardown {
                do {
                    let restoredStatus = try await helperClient().stopSession()
                    accept(restoredStatus)
                    guard !restoredStatus.session.isActive,
                          !restoredStatus.protectionVerified,
                          restoredStatus.lastErrorMessage == nil else {
                        serviceActionMessage = "The helper has not confirmed that normal sleep is restored."
                        return
                    }
                } catch {
                    await handleAsyncError(error)
                    return
                }
            }

            do {
                switch installationBackend {
                case .localDaemon:
                    try await removeManagedRegistrationForMigration()
                    if localDaemonStatus?.plistInstalled == true || localDaemonStatus?.jobLoaded == true {
                        try await LocalDaemonManager.perform(.remove)
                    }
                case .serviceManagement:
                    try await helperService.unregister()
                    guard await waitForManagedUnregistration() else {
                        throw HelperAppActionError.registrationDidNotChange
                    }
                case .none:
                    throw HelperAppActionError.backendUnavailable(backendConfigurationError ?? "Helper installation mode is unavailable.")
                }

                await refreshSetupStatus()
                helperStatus = nil
                lastStatusUptime = nil
                knownSessionNeedsCleanup = false
                connectionError = nil
                serviceActionMessage = "Background helper disabled."
                commandError = nil
            } catch {
                serviceActionMessage = registrationErrorMessage(error)
                await refreshSetupStatus()
            }
        }
    }

    func quit() {
        guard !isBusy else { return }
        guard !isPreview else {
            NSApp.terminate(nil)
            return
        }
        guard requiresCleanupBeforeTeardown else {
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
                    serviceActionMessage = "Normal sleep was not confirmed; RunAnyways is staying open so you can retry."
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
                connectionError = nil
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
                connectionError = nil
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
                connectionError = nil
                commandError = nil
            } catch {
                await handleAsyncError(error)
            }
        }
    }

    private func refreshSetupStatus() async {
        setupStatus = helperService.status
        if installationBackend == .localDaemon || connectionError != nil {
            localDaemonStatus = await Task.detached(priority: .utility) {
                LocalDaemonManager.inspect()
            }.value
        }
        guard hasRegisteredHelper else {
            if !knownSessionNeedsCleanup {
                client?.invalidate()
                client = nil
                helperStatus = nil
                lastStatusUptime = nil
                connectionError = nil
                endSessionActivity()
            }
            return
        }
    }

    private func refreshStatus() async {
        await refreshSetupStatus()
        guard hasRegisteredHelper else { return }
        didAttemptConnection = true
        do {
            let status: HelperStatusSnapshot
            if helperStatus?.session.isActive == true {
                status = try await helperClient().heartbeat()
            } else {
                status = try await helperClient().fetchStatus()
            }
            accept(status)
            connectionError = nil
        } catch {
            if case RunAnywaysIPCError.helper(let message) = error {
                do {
                    let status = try await helperClient().fetchStatus()
                    accept(status)
                    connectionError = nil
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
        connectionError = nil
        knownSessionNeedsCleanup = status.session.isActive || status.lastErrorMessage != nil
        if status.session.isActive {
            beginSessionActivity()
        } else {
            endSessionActivity()
        }
    }

    private func handleTransportError(_ error: Error) {
        connectionError = error.localizedDescription
        commandError = nil
        if helperStatus?.session.isActive == true || helperStatus?.lastErrorMessage != nil {
            knownSessionNeedsCleanup = true
        }
        client?.invalidate()
        client = nil
        lastStatusUptime = nil
        endSessionActivity()
    }

    private func handleAsyncError(_ error: Error) async {
        if case RunAnywaysIPCError.helper(let message) = error {
            commandError = message
            do {
                let status = try await helperClient().fetchStatus()
                accept(status)
                connectionError = nil
            } catch {
                handleTransportError(error)
            }
            return
        }
        handleTransportError(error)
    }

    private func registrationErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        var detail = "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
        if let debugDescription = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
            detail += " \(debugDescription)"
        }
        if let reason = nsError.localizedFailureReason { detail += " \(reason)" }
        if let suggestion = nsError.localizedRecoverySuggestion { detail += " \(suggestion)" }
        return detail
    }

    private func removeManagedRegistrationForMigration() async throws {
        guard helperService.status == .enabled || helperService.status == .requiresApproval else { return }
        guard !requiresCleanupBeforeTeardown else {
            throw HelperAppActionError.unsafeMigration("An active session or pending sleep restoration must be resolved first.")
        }

        let hasAuthenticatedIdleStatus: Bool
        if let helperStatus, connectionError == nil {
            hasAuthenticatedIdleStatus = !helperStatus.session.isActive &&
                !helperStatus.protectionVerified &&
                helperStatus.lastErrorMessage == nil
        } else {
            hasAuthenticatedIdleStatus = false
        }
        let localStatus: LocalDaemonStatus
        if let localDaemonStatus {
            localStatus = localDaemonStatus
        } else {
            localStatus = await Task.detached(priority: .utility) {
                LocalDaemonManager.inspect()
            }.value
        }
        let confirmsStopped = localStatus.inspectionReliable &&
            !localStatus.processRunning &&
            localStatus.processID == nil &&
            (localStatus.jobLoaded ? localStatus.lastExitStatus != nil :
                (localStatus.detail ?? "").localizedCaseInsensitiveContains("Could not find service"))
        guard hasAuthenticatedIdleStatus || confirmsStopped else {
            throw HelperAppActionError.unsafeMigration(
                "The old managed helper is unreachable and launchd cannot confirm that its process stopped."
            )
        }

        try await helperService.unregister()
        guard await waitForManagedUnregistration() else {
            throw HelperAppActionError.registrationDidNotChange
        }
    }

    private func waitForManagedUnregistration() async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            let status = helperService.status
            if status == .notRegistered || status == .notFound { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return helperService.status == .notRegistered || helperService.status == .notFound
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

private enum HelperAppActionError: LocalizedError {
    case registrationDidNotChange
    case unsafeMigration(String)
    case backendUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .registrationDidNotChange:
            "Service Management did not confirm that the old helper registration was removed."
        case .unsafeMigration(let detail):
            detail
        case .backendUnavailable(let detail):
            detail
        }
    }
}
