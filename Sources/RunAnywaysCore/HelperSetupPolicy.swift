/// ServiceManagement lifecycle state represented without importing AppKit or
/// ServiceManagement, so the registration decision stays deterministic.
public enum HelperSetupState: String, Codable, Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

/// File and signature checks needed before exposing a helper registration action.
public struct HelperSetupResources: Codable, Equatable, Sendable {
    public let helperExecutablePresent: Bool
    public let launchDaemonPlistPresent: Bool
    public let metadataValid: Bool

    public init(
        helperExecutablePresent: Bool,
        launchDaemonPlistPresent: Bool,
        metadataValid: Bool
    ) {
        self.helperExecutablePresent = helperExecutablePresent
        self.launchDaemonPlistPresent = launchDaemonPlistPresent
        self.metadataValid = metadataValid
    }

    public var areUsable: Bool {
        helperExecutablePresent && launchDaemonPlistPresent && metadataValid
    }
}

public enum HelperSetupDecision: String, Codable, Equatable, Sendable {
    case enabled
    case requiresApproval
    case register
    case installLocalDaemon
    case repairLocalDaemon
    case unavailable
    case unknown
}

public enum HelperSetupBackend: String, Codable, Equatable, Sendable {
    case serviceManagement
    case localDaemon
}

public enum HelperSetupPolicy {
    public static func decision(
        for state: HelperSetupState,
        resources: HelperSetupResources
    ) -> HelperSetupDecision {
        guard resources.areUsable else { return .unavailable }
        return switch state {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered, .notFound: .register
        case .unknown: .unknown
        }
    }

    public static func decision(
        backend: HelperSetupBackend,
        serviceManagementState: HelperSetupState,
        resources: HelperSetupResources,
        localDaemonPlistInstalled: Bool = false,
        localDaemonJobLoaded: Bool = false
    ) -> HelperSetupDecision {
        guard resources.areUsable else { return .unavailable }
        guard backend == .localDaemon else {
            return decision(for: serviceManagementState, resources: resources)
        }
        if localDaemonJobLoaded && localDaemonPlistInstalled { return .enabled }
        return localDaemonPlistInstalled ? .repairLocalDaemon : .installLocalDaemon
    }
}

public struct HelperRecoveryState: Codable, Equatable, Sendable {
    public let isReachable: Bool
    public let hasKnownActiveSession: Bool
    public let helperReportsRestorationFailure: Bool

    public init(
        isReachable: Bool,
        hasKnownActiveSession: Bool,
        helperReportsRestorationFailure: Bool
    ) {
        self.isReachable = isReachable
        self.hasKnownActiveSession = hasKnownActiveSession
        self.helperReportsRestorationFailure = helperReportsRestorationFailure
    }
}

public enum HelperRecoveryAction: String, Codable, Equatable, Sendable {
    case none
    case retryConnection
    case retryRestore
}

public enum HelperRecoveryPolicy {
    public static func action(for state: HelperRecoveryState) -> HelperRecoveryAction {
        if state.helperReportsRestorationFailure { return .retryRestore }
        guard !state.isReachable else { return .none }
        return state.hasKnownActiveSession ? .retryRestore : .retryConnection
    }

    public static func requiresCleanupBeforeTeardown(_ state: HelperRecoveryState) -> Bool {
        state.hasKnownActiveSession || state.helperReportsRestorationFailure
    }

    public static func canRepairOrRemoveHelper(_ state: HelperRecoveryState) -> Bool {
        !requiresCleanupBeforeTeardown(state)
    }
}
