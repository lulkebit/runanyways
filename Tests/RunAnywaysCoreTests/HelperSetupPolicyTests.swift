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

    private var validResources: HelperSetupResources {
        HelperSetupResources(helperExecutablePresent: true, launchDaemonPlistPresent: true, metadataValid: true)
    }
}
