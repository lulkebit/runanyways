import Foundation
import XCTest
@testable import RunAnywaysCore

final class SessionTests: XCTestCase {
    func testTimedSessionArmsThenConsumesOnlyWhileLidIsClosed() throws {
        var session = Session()
        try session.start(seconds: 600, cutoffPercentage: 20, lidIsClosed: false, at: 100)

        XCTAssertEqual(session.state, .armed)
        XCTAssertEqual(try session.snapshot(at: 500).remainingSeconds, 600)

        try session.lidDidClose(at: 500)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(try session.snapshot(at: 650).remainingSeconds, 450)

        try session.lidDidOpen(at: 700)
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.remainingSeconds, 400)
        XCTAssertEqual(try session.snapshot(at: 1_000).remainingSeconds, 400)

        try session.lidDidClose(at: 1_000)
        try session.advance(to: 1_250)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.remainingSeconds, 150)
    }

    func testExpirationOccursAtExactBoundary() throws {
        var session = Session()
        try session.start(seconds: 60, lidIsClosed: true, at: 10)

        let projected = try session.snapshot(at: 70)
        XCTAssertEqual(projected.state, .ended)
        XCTAssertEqual(projected.remainingSeconds, 0)
        XCTAssertEqual(projected.endReason, .expired)

        try session.advance(to: 70)
        XCTAssertEqual(session.state, .ended)
        XCTAssertEqual(session.endReason, .expired)
    }

    func testRepeatedLidNotificationsDoNotResetOrDoubleCount() throws {
        var session = Session()
        try session.start(seconds: 120, lidIsClosed: false, at: 0)
        try session.lidDidClose(at: 10)
        try session.lidDidClose(at: 10)
        try session.lidDidOpen(at: 40)
        try session.lidDidOpen(at: 50)

        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.remainingSeconds, 90)

        try session.lidDidClose(at: 100)
        try session.lidDidClose(at: 130)
        XCTAssertEqual(session.state, .running)
        XCTAssertEqual(session.remainingSeconds, 60)

        try session.lidDidOpen(at: 160)
        XCTAssertEqual(session.state, .paused)
        XCTAssertEqual(session.remainingSeconds, 30)
    }

    func testUnlimitedSessionDoesNotCountDownAndCannotBeExtended() throws {
        var session = Session()
        try session.start(seconds: nil, cutoffPercentage: 30, lidIsClosed: true, at: 42)

        XCTAssertNil(try session.snapshot(at: 10_000).remainingSeconds)
        XCTAssertEqual(try session.snapshot(at: 10_000).state, .running)
        XCTAssertThrowsError(try session.extend(by: 60, at: 10_000)) {
            XCTAssertEqual($0 as? SessionError, .unlimitedCannotBeExtended)
        }
    }

    func testExtensionAddsTimeAndIsBoundedByMaximum() throws {
        var session = Session()
        try session.start(seconds: 300, lidIsClosed: false, at: 0)
        try session.extend(by: 120, at: 30)
        XCTAssertEqual(session.remainingSeconds, 420)

        XCTAssertThrowsError(try session.extend(by: Session.maximumDuration, at: 30)) {
            XCTAssertEqual($0 as? SessionError, .durationLimitExceeded)
        }
        XCTAssertEqual(session.remainingSeconds, 420)
    }

    func testExtensionCheckpointsRunningTimeAndCannotReviveExpiredSession() throws {
        var session = Session()
        try session.start(seconds: 120, lidIsClosed: true, at: 10)
        try session.extend(by: 60, at: 40)
        XCTAssertEqual(session.remainingSeconds, 150)

        XCTAssertThrowsError(try session.extend(by: 60, at: 250)) {
            XCTAssertEqual($0 as? SessionError, .invalidTransition)
        }
        XCTAssertEqual(session.state, .ended)
        XCTAssertEqual(session.remainingSeconds, 0)
        XCTAssertEqual(session.endReason, .expired)
    }

    func testBatteryAndThermalStopsEndSessionWithReason() throws {
        var lowBatterySession = Session()
        try lowBatterySession.start(seconds: 3_600, lidIsClosed: true, at: 1)
        try lowBatterySession.end(reason: .lowBattery, at: 121)
        XCTAssertEqual(lowBatterySession.state, .ended)
        XCTAssertEqual(lowBatterySession.endReason, .lowBattery)
        XCTAssertEqual(lowBatterySession.remainingSeconds, 3_480)

        var thermalSession = Session()
        try thermalSession.start(seconds: 3_600, lidIsClosed: false, at: 0)
        try thermalSession.end(reason: .thermalPressure, at: 5)
        XCTAssertEqual(thermalSession.endReason, .thermalPressure)
        XCTAssertEqual(thermalSession.remainingSeconds, 3_600)
    }

    func testValidationRejectsInvalidInputsAndBackwardTime() throws {
        var session = Session()
        XCTAssertThrowsError(try session.start(seconds: 0, lidIsClosed: false, at: 0)) {
            XCTAssertEqual($0 as? SessionError, .invalidDuration)
        }
        XCTAssertThrowsError(try session.start(seconds: -1, lidIsClosed: false, at: 0)) {
            XCTAssertEqual($0 as? SessionError, .invalidDuration)
        }
        XCTAssertThrowsError(try session.start(seconds: .nan, lidIsClosed: false, at: 0)) {
            XCTAssertEqual($0 as? SessionError, .invalidDuration)
        }
        XCTAssertThrowsError(try session.start(seconds: 60, cutoffPercentage: 4, lidIsClosed: false, at: 0)) {
            XCTAssertEqual($0 as? SessionError, .invalidCutoff)
        }
        XCTAssertThrowsError(try session.start(seconds: 60, cutoffPercentage: 51, lidIsClosed: false, at: 0)) {
            XCTAssertEqual($0 as? SessionError, .invalidCutoff)
        }
        XCTAssertThrowsError(try session.start(seconds: 60, lidIsClosed: false, at: .infinity)) {
            XCTAssertEqual($0 as? SessionError, .invalidTimestamp)
        }

        try session.start(seconds: 60, lidIsClosed: true, at: 10)
        XCTAssertThrowsError(try session.advance(to: 9)) {
            XCTAssertEqual($0 as? SessionError, .timestampMovedBackwards)
        }
        XCTAssertThrowsError(try session.extend(by: 0, at: 11)) {
            XCTAssertEqual($0 as? SessionError, .invalidDuration)
        }
        XCTAssertThrowsError(try session.extend(by: .nan, at: 11)) {
            XCTAssertEqual($0 as? SessionError, .invalidDuration)
        }
        XCTAssertThrowsError(try session.extend(by: Session.maximumDuration, at: 11)) {
            XCTAssertEqual($0 as? SessionError, .durationLimitExceeded)
        }
    }

    func testEndedSessionCanBeStartedAgainAndSnapshotEncodes() throws {
        var session = Session()
        try session.start(seconds: 60, lidIsClosed: false, at: 1)
        try session.end(at: 2)
        try session.start(seconds: nil, cutoffPercentage: 25, lidIsClosed: false, at: 3)

        let snapshot = try session.snapshot(at: 4)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: encoded)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.state, .armed)
        XCTAssertNil(decoded.remainingSeconds)
        XCTAssertEqual(decoded.cutoffPercentage, 25)
    }
}
