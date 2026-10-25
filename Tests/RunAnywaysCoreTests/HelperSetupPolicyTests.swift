import XCTest
@testable import RunAnywaysCore

final class HelperSetupPolicyTests: XCTestCase {
    func testNotFoundCanRegisterWhenEmbeddedResourcesAreValid() {
        XCTAssertEqual(
            HelperSetupPolicy.decision(for: .notFound, resources: validResources),
            .register
        )
    }

    func testNotFoundWithMissingHelperIsUnavailable() {
        let resources = HelperSetupResources(
            helperExecutablePresent: false,
            launchDaemonPlistPresent: true,
            metadataValid: true
        )
        XCTAssertEqual(HelperSetupPolicy.decision(for: .notFound, resources: resources), .unavailable)
    }

    func testNotFoundWithMissingDaemonPlistIsUnavailable() {
        let resources = HelperSetupResources(
            helperExecutablePresent: true,
            launchDaemonPlistPresent: false,
            metadataValid: true
        )
        XCTAssertEqual(HelperSetupPolicy.decision(for: .notFound, resources: resources), .unavailable)
    }

    func testNotFoundWithInvalidMetadataIsUnavailable() {
        let resources = HelperSetupResources(
            helperExecutablePresent: true,
            launchDaemonPlistPresent: true,
            metadataValid: false
        )
        XCTAssertEqual(HelperSetupPolicy.decision(for: .notFound, resources: resources), .unavailable)
    }

    func testRequiresApprovalRemainsAnApprovalState() {
        XCTAssertEqual(
            HelperSetupPolicy.decision(for: .requiresApproval, resources: validResources),
            .requiresApproval
        )
    }

    func testNotRegisteredCanRegisterAndEnabledStaysEnabled() {
        XCTAssertEqual(
            HelperSetupPolicy.decision(for: .notRegistered, resources: validResources),
            .register
        )
        XCTAssertEqual(
            HelperSetupPolicy.decision(for: .enabled, resources: validResources),
            .enabled
        )
    }

    func testLocalDaemonSetupDistinguishesInstallRepairAndEnabled() {
        XCTAssertEqual(
            HelperSetupPolicy.decision(
                backend: .localDaemon,
                serviceManagementState: .notFound,
                resources: validResources
            ),
            .installLocalDaemon
        )
        XCTAssertEqual(
            HelperSetupPolicy.decision(
                backend: .localDaemon,
                serviceManagementState: .notFound,
                resources: validResources,
                localDaemonPlistInstalled: true
            ),
            .repairLocalDaemon
        )
        XCTAssertEqual(
            HelperSetupPolicy.decision(
                backend: .localDaemon,
                serviceManagementState: .enabled,
                resources: validResources,
                localDaemonPlistInstalled: true,
                localDaemonJobLoaded: true
            ),
            .enabled
        )
    }

    func testInitialConnectionFailureDoesNotOfferSleepRestoreAndAllowsQuitOrRepair() {
        let state = HelperRecoveryState(
            isReachable: false,
            hasKnownActiveSession: false,
            helperReportsRestorationFailure: false
        )
        XCTAssertEqual(HelperRecoveryPolicy.action(for: state), .retryConnection)
        XCTAssertFalse(HelperRecoveryPolicy.requiresCleanupBeforeTeardown(state))
        XCTAssertTrue(HelperRecoveryPolicy.canRepairOrRemoveHelper(state))
    }

    func testHelperReportedRestoreFailureKeepsRestoreRecoveryAndBlocksRepair() {
        let state = HelperRecoveryState(
            isReachable: true,
            hasKnownActiveSession: false,
            helperReportsRestorationFailure: true
        )
        XCTAssertEqual(HelperRecoveryPolicy.action(for: state), .retryRestore)
        XCTAssertTrue(HelperRecoveryPolicy.requiresCleanupBeforeTeardown(state))
        XCTAssertFalse(HelperRecoveryPolicy.canRepairOrRemoveHelper(state))
    }

    func testLostConnectionDuringPreviouslyKnownActiveSessionRequiresCleanup() {
        let state = HelperRecoveryState(
            isReachable: false,
            hasKnownActiveSession: true,
            helperReportsRestorationFailure: false
        )
        XCTAssertEqual(HelperRecoveryPolicy.action(for: state), .retryRestore)
        XCTAssertTrue(HelperRecoveryPolicy.requiresCleanupBeforeTeardown(state))
        XCTAssertFalse(HelperRecoveryPolicy.canRepairOrRemoveHelper(state))
    }

    func testReachableHealthyActiveSessionUsesNormalStopControls() {
        let state = HelperRecoveryState(
            isReachable: true,
            hasKnownActiveSession: true,
            helperReportsRestorationFailure: false
        )
        XCTAssertEqual(HelperRecoveryPolicy.action(for: state), .none)
        XCTAssertTrue(HelperRecoveryPolicy.requiresCleanupBeforeTeardown(state))
    }

    private var validResources: HelperSetupResources {
        HelperSetupResources(helperExecutablePresent: true, launchDaemonPlistPresent: true, metadataValid: true)
    }
}
