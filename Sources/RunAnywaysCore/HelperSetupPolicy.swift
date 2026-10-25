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
    case unavailable
    case unknown
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
}
