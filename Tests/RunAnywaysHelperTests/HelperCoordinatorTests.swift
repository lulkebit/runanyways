import XCTest
import RunAnywaysCore
import RunAnywaysHelper
import RunAnywaysIPC

final class HelperCoordinatorTests: XCTestCase {
    func testArmedPauseResumeAndDisplaySleepOnEveryLidClosure() throws {
        let fixture = Fixture(lidClosed: false)
        try fixture.coordinator.startSession(ownerToken: "owner", seconds: 60, unlimited: false, cutoff: 20)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .armed)
        XCTAssertTrue(fixture.coordinator.fetchStatus().protectionVerified)

        fixture.clock.now = 5
        fixture.coordinator.tick(at: 5)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.remainingSeconds, 60)

        fixture.power.reading = fixture.reading(lidClosed: true)
        fixture.clock.now = 10
        try fixture.coordinator.heartbeat(ownerToken: "owner")
        _ = fixture.coordinator.fetchStatus() // Status polling must not consume the pending lid edge.
        fixture.coordinator.tick(at: 10)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .running)
        XCTAssertEqual(fixture.power.displaySleepCount, 1)

        fixture.clock.now = 20
        try fixture.coordinator.heartbeat(ownerToken: "owner")
        fixture.coordinator.tick(at: 20)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.remainingSeconds, 50)

        fixture.power.reading = fixture.reading(lidClosed: false)
        fixture.clock.now = 25
        try fixture.coordinator.heartbeat(ownerToken: "owner")
        _ = fixture.coordinator.fetchStatus()
        fixture.coordinator.tick(at: 25)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .paused)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.remainingSeconds, 45)

        fixture.clock.now = 35
        try fixture.coordinator.heartbeat(ownerToken: "owner")
        fixture.coordinator.tick(at: 35)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.remainingSeconds, 45)

        fixture.power.reading = fixture.reading(lidClosed: true)
        fixture.clock.now = 40
        try fixture.coordinator.heartbeat(ownerToken: "owner")
        _ = fixture.coordinator.fetchStatus()
        fixture.coordinator.tick(at: 40)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .running)
        XCTAssertEqual(fixture.power.displaySleepCount, 2)

        fixture.clock.now = 45
        fixture.coordinator.tick(at: 45)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.remainingSeconds, 40)
        try fixture.coordinator.stopSession(ownerToken: "owner")
        XCTAssertFalse(fixture.power.sleepDisabled)
    }

    func testTimerExpiryRestoresWithoutHeartbeat() throws {
        let fixture = Fixture(lidClosed: true)
        try fixture.coordinator.startSession(ownerToken: "owner", seconds: 5, unlimited: false, cutoff: 20)
        fixture.clock.now = 4.9
        fixture.coordinator.tick(at: 4.9)
        XCTAssertTrue(fixture.power.sleepDisabled)

        fixture.clock.now = 5
        fixture.coordinator.tick(at: 5)

        let status = fixture.coordinator.fetchStatus()
        XCTAssertEqual(status.session.state, .ended)
        XCTAssertEqual(status.session.endReason, .expired)
        XCTAssertFalse(status.protectionVerified)
        XCTAssertFalse(fixture.power.sleepDisabled)
        XCTAssertNil(fixture.journal.originalValue)
    }

    func testOnlyOwnerCanMutateOrExtendLeaseAndLeaseExpiryRestores() throws {
        let fixture = Fixture(lidClosed: false)
        try fixture.coordinator.startSession(ownerToken: "owner-1", seconds: 90, unlimited: false, cutoff: 20)

        XCTAssertThrowsError(try fixture.coordinator.startSession(ownerToken: "owner-2", seconds: 90, unlimited: false, cutoff: 20))
        XCTAssertThrowsError(try fixture.coordinator.heartbeat(ownerToken: "owner-2"))
        XCTAssertThrowsError(try fixture.coordinator.extendSession(ownerToken: "owner-2", seconds: 10))
        XCTAssertThrowsError(try fixture.coordinator.stopSession(ownerToken: "owner-2"))
        XCTAssertTrue(fixture.power.sleepDisabled)

        fixture.clock.now = HelperCoordinator.ownerLeaseDuration
        fixture.coordinator.tick(at: fixture.clock.now)
        let status = fixture.coordinator.fetchStatus()
        XCTAssertEqual(status.session.state, .ended)
        XCTAssertEqual(status.session.endReason, .stopped)
        XCTAssertFalse(fixture.power.sleepDisabled)
    }

    func testRefusesSleepOverrideOwnedByAnotherTool() {
        let fixture = Fixture(lidClosed: false, sleepDisabled: true)
        XCTAssertThrowsError(try fixture.coordinator.startSession(ownerToken: "owner", seconds: 60, unlimited: false, cutoff: 20))
        XCTAssertTrue(fixture.power.sleepDisabled)
        XCTAssertEqual(fixture.power.setValues, [])
        XCTAssertNil(fixture.journal.originalValue)
    }

    func testRestoreFailureKeepsJournalAndStopRetries() throws {
        let fixture = Fixture(lidClosed: false)
        try fixture.coordinator.startSession(ownerToken: "owner", seconds: 60, unlimited: false, cutoff: 20)
        fixture.power.failNextRestore = true

        try fixture.coordinator.stopSession(ownerToken: "owner")
        XCTAssertTrue(fixture.power.sleepDisabled)
        XCTAssertEqual(fixture.journal.originalValue, false)
        XCTAssertNotNil(fixture.coordinator.fetchStatus().lastErrorMessage)

        try fixture.coordinator.stopSession(ownerToken: "owner")
        XCTAssertFalse(fixture.power.sleepDisabled)
        XCTAssertNil(fixture.journal.originalValue)
        XCTAssertNil(fixture.coordinator.fetchStatus().lastErrorMessage)
    }

    func testStartupRecoversJournalBeforeAcceptingSessions() throws {
        let fixture = Fixture(lidClosed: false, sleepDisabled: true, journalValue: false)
        XCTAssertFalse(fixture.power.sleepDisabled)
        XCTAssertNil(fixture.journal.originalValue)

        try fixture.coordinator.startSession(ownerToken: "owner", seconds: 60, unlimited: false, cutoff: 20)
        XCTAssertTrue(fixture.coordinator.fetchStatus().protectionVerified)
    }

    func testExtensionAtExpirationFinalizesAndRestoresDespiteThrownError() throws {
        let fixture = Fixture(lidClosed: true)
        try fixture.coordinator.startSession(ownerToken: "owner", seconds: 5, unlimited: false, cutoff: 20)
        fixture.clock.now = 5

        XCTAssertThrowsError(try fixture.coordinator.extendSession(ownerToken: "owner", seconds: 10))
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .ended)
        XCTAssertFalse(fixture.power.sleepDisabled)
        XCTAssertNil(fixture.journal.originalValue)
    }

    func testInvalidInputsDoNotAcquireSleepOverride() {
        let fixture = Fixture(lidClosed: false)
        XCTAssertThrowsError(try fixture.coordinator.startSession(ownerToken: "owner", seconds: .nan, unlimited: false, cutoff: 20))
        XCTAssertThrowsError(try fixture.coordinator.startSession(ownerToken: "owner", seconds: 60, unlimited: false, cutoff: 51))
        XCTAssertEqual(fixture.power.setValues, [])
        XCTAssertNil(fixture.journal.originalValue)
    }
    func testLateHeartbeatAndExtensionCannotReviveExpiredLeaseBeforeTick() throws {
        for heartbeat in [true, false] {
            let fixture = Fixture(lidClosed: false)
            try fixture.start()
            fixture.clock.now = HelperCoordinator.ownerLeaseDuration
            XCTAssertFalse(fixture.coordinator.fetchStatus().protectionVerified)
            if heartbeat {
                XCTAssertThrowsError(try fixture.coordinator.heartbeat(ownerToken: "owner"))
            } else {
                XCTAssertThrowsError(try fixture.coordinator.extendSession(ownerToken: "owner", seconds: 10))
            }
            XCTAssertFalse(fixture.power.sleepDisabled)
            XCTAssertNil(fixture.journal.originalValue)
            fixture.coordinator.tick(at: fixture.clock.now + 1)
            XCTAssertEqual(fixture.power.setValues, [true, false])
            try fixture.coordinator.startSession(ownerToken: "new-owner", seconds: 30, unlimited: false, cutoff: 20)
        }
    }

    func testHeartbeatAtCountdownExpiryRestoresWithoutTick() throws {
        let fixture = Fixture(lidClosed: true)
        try fixture.start(seconds: 5)
        fixture.clock.now = 5
        XCTAssertThrowsError(try fixture.coordinator.heartbeat(ownerToken: "owner"))
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.endReason, .expired)
        XCTAssertFalse(fixture.power.sleepDisabled)
    }

    func testSuccessfulExtensionDoesNotExtendHeartbeatLease() throws {
        let fixture = Fixture(lidClosed: true)
        try fixture.start(seconds: 60)
        fixture.clock.now = 19
        try fixture.coordinator.extendSession(ownerToken: "owner", seconds: 10)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.remainingSeconds, 51)
        fixture.clock.now = 25
        fixture.coordinator.tick(at: 25)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .ended)
        XCTAssertFalse(fixture.power.sleepDisabled)
        fixture.coordinator.tick(at: 26)
        XCTAssertEqual(fixture.power.setValues, [true, false])
    }

    func testAutomaticRestorationRetryReleasesOwnerForNewSession() throws {
        let fixture = Fixture(lidClosed: false)
        try fixture.start()
        fixture.power.failNextRestore = true
        try fixture.coordinator.stopSession(ownerToken: "owner")
        XCTAssertFalse(fixture.coordinator.fetchStatus().session.isActive)
        fixture.clock.now = 1
        fixture.coordinator.tick(at: 1)
        XCTAssertFalse(fixture.power.sleepDisabled)
        XCTAssertNil(fixture.journal.originalValue)
        try fixture.coordinator.startSession(ownerToken: "another", seconds: 30, unlimited: false, cutoff: 20)
    }

    func testTransientStartupRestoreFailureRetriesButCorruptJournalFailsClosed() throws {
        let reading = HelperSensorReading(lidIsClosed: false, batteryPercentage: 100, powerSource: .ac, thermalCondition: .nominal)
        let power = MockPowerSystem(reading: reading, sleepDisabled: true)
        let journal = MockJournal(originalValue: false)
        power.failNextRestore = true
        let coordinator = HelperCoordinator(power: power, journal: journal, clock: TestClock(now: 0))
        XCTAssertEqual(journal.originalValue, false)
        coordinator.tick(at: 1)
        XCTAssertFalse(power.sleepDisabled)
        XCTAssertNil(journal.originalValue)
        try coordinator.startSession(ownerToken: "owner", seconds: 60, unlimited: false, cutoff: 20)

        let corruptPower = MockPowerSystem(reading: reading, sleepDisabled: true)
        let corruptJournal = MockJournal(originalValue: false)
        corruptJournal.failRead = true
        let corrupt = HelperCoordinator(power: corruptPower, journal: corruptJournal, clock: TestClock(now: 0))
        corrupt.tick(at: 1)
        XCTAssertThrowsError(try corrupt.startSession(ownerToken: "owner", seconds: 60, unlimited: false, cutoff: 20))
        XCTAssertTrue(corruptPower.setValues.isEmpty)
        XCTAssertEqual(corruptJournal.originalValue, false)
    }

    func testSafetyReadingsRejectStartAndRestoreActiveSessions() throws {
        let unsafeReadings: [HelperSensorReading] = [
            .init(lidIsClosed: nil, batteryPercentage: 90, powerSource: .ac, thermalCondition: .nominal),
            .init(lidIsClosed: false, batteryPercentage: 90, powerSource: .unknown, thermalCondition: .nominal),
            .init(lidIsClosed: false, batteryPercentage: nil, powerSource: .battery, thermalCondition: .nominal),
            .init(lidIsClosed: false, batteryPercentage: 101, powerSource: .battery, thermalCondition: .nominal),
            .init(lidIsClosed: false, batteryPercentage: 90, powerSource: .ac, thermalCondition: .unknown),
            .init(lidIsClosed: false, batteryPercentage: 90, powerSource: .ac, thermalCondition: .serious),
            .init(lidIsClosed: false, batteryPercentage: 90, powerSource: .ac, thermalCondition: .critical),
            .init(lidIsClosed: false, batteryPercentage: 20, powerSource: .battery, thermalCondition: .nominal)
        ]
        for reading in unsafeReadings {
            let fixture = Fixture(lidClosed: false)
            fixture.power.reading = reading
            XCTAssertThrowsError(try fixture.start())
            XCTAssertTrue(fixture.power.setValues.isEmpty)
            fixture.power.reading = fixture.reading(lidClosed: false)
            try fixture.start()
            fixture.power.reading = reading
            fixture.clock.now = 1
            fixture.coordinator.tick(at: 1)
            XCTAssertFalse(fixture.coordinator.fetchStatus().session.isActive)
            XCTAssertFalse(fixture.power.sleepDisabled)
            XCTAssertNil(fixture.journal.originalValue)
            fixture.coordinator.tick(at: 2)
            XCTAssertEqual(fixture.power.setValues, [true, false])
        }
    }

    func testACRemovalContinuesUntilBatteryCutoffAndUnlimitedStillHasLease() throws {
        let fixture = Fixture(lidClosed: true)
        try fixture.coordinator.startSession(ownerToken: "owner", seconds: 0, unlimited: true, cutoff: 20)
        fixture.power.reading = .init(lidIsClosed: true, batteryPercentage: 21, powerSource: .battery, thermalCondition: .fair)
        fixture.clock.now = 10
        fixture.coordinator.tick(at: 10)
        XCTAssertTrue(fixture.coordinator.fetchStatus().protectionVerified)
        XCTAssertNil(fixture.coordinator.fetchStatus().session.remainingSeconds)
        fixture.clock.now = 20
        fixture.coordinator.tick(at: 20)
        XCTAssertFalse(fixture.power.sleepDisabled)
    }

    func testAcquisitionReadbackDisplayAndJournalFailuresNeverLeaveProtectionClaimed() throws {
        for failure in 0..<4 {
            let fixture = Fixture(lidClosed: true)
            switch failure {
            case 0: fixture.power.failAcquire = true
            case 1: fixture.power.ignoreAcquire = true
            case 2: fixture.power.failDisplaySleep = true
            default: fixture.journal.failRecord = true
            }
            XCTAssertThrowsError(try fixture.start())
            XCTAssertFalse(fixture.coordinator.fetchStatus().protectionVerified)
            XCTAssertFalse(fixture.power.sleepDisabled)
            XCTAssertNil(fixture.journal.originalValue)
            fixture.coordinator.tick(at: 1)
            XCTAssertFalse(fixture.power.sleepDisabled)
            if failure == 3 { XCTAssertTrue(fixture.power.setValues.isEmpty) }
        }
    }

    func testRestoreReadbackOrJournalClearFailureRetainsJournalAndRetries() throws {
        for failReadback in [true, false] {
            let fixture = Fixture(lidClosed: false)
            try fixture.start()
            if failReadback { fixture.power.ignoreRestore = true }
            else { fixture.journal.failClear = true }
            try fixture.coordinator.stopSession(ownerToken: "owner")
            XCTAssertEqual(fixture.journal.originalValue, false)
            XCTAssertFalse(fixture.coordinator.fetchStatus().protectionVerified)
            fixture.power.ignoreRestore = false
            fixture.journal.failClear = false
            fixture.coordinator.tick(at: 1)
            XCTAssertNil(fixture.journal.originalValue)
            XCTAssertFalse(fixture.power.sleepDisabled)
            try fixture.coordinator.startSession(ownerToken: "another", seconds: 30, unlimited: false, cutoff: 20)
        }
    }

    func testPendingRestorationPreventsReacquisitionAndShutdownRetriesAreBounded() throws {
        let fixture = Fixture(lidClosed: false)
        try fixture.start()
        fixture.power.failRestore = true
        try fixture.coordinator.stopSession(ownerToken: "owner")
        XCTAssertThrowsError(try fixture.coordinator.startSession(ownerToken: "another", seconds: 30, unlimited: false, cutoff: 20))
        fixture.coordinator.tick(at: 1)
        XCTAssertEqual(fixture.power.setValues.filter { $0 }.count, 1)
        let beforeShutdown = fixture.power.setValues.count
        fixture.coordinator.shutdown()
        XCTAssertLessThanOrEqual(fixture.power.setValues.count - beforeShutdown, 3)
        XCTAssertEqual(fixture.journal.originalValue, false)
        XCTAssertFalse(fixture.coordinator.fetchStatus().session.isActive)
        fixture.power.failRestore = false
        fixture.coordinator.tick(at: 2)
        XCTAssertFalse(fixture.power.sleepDisabled)
    }

    func testDisconnectAndClockFailureCannotReacquireUnjournaledOverride() throws {
        for invalidTime in [Double.nan, -1, 0] {
            let fixture = Fixture(lidClosed: false)
            try fixture.start()
            fixture.clock.now = 5
            fixture.coordinator.tick(at: 5)
            fixture.coordinator.tick(at: invalidTime)
            XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .failed)
            XCTAssertFalse(fixture.power.sleepDisabled)
            fixture.coordinator.tick(at: 6)
            XCTAssertEqual(fixture.power.setValues, [true, false])
        }
        let fixture = Fixture(lidClosed: false)
        try fixture.start()
        fixture.coordinator.connectionInvalidated(ownerToken: "stranger")
        XCTAssertTrue(fixture.power.sleepDisabled)
        fixture.coordinator.connectionInvalidated(ownerToken: "owner")
        fixture.coordinator.tick(at: 1)
        XCTAssertEqual(fixture.power.setValues, [true, false])
        XCTAssertThrowsError(try fixture.coordinator.heartbeat(ownerToken: "owner"))
    }

    func testJournalIsDurableBeforeAcquisitionAndRepeatedLidTicksDoNotSleepDisplaysAgain() throws {
        let fixture = Fixture(lidClosed: true)
        fixture.power.onSet = { disabled in
            if disabled { XCTAssertEqual(fixture.journal.originalValue, false) }
        }
        try fixture.start()
        XCTAssertEqual(fixture.power.displaySleepCount, 1)
        for time in [1.0, 1.5, 2.0] {
            fixture.clock.now = time
            _ = fixture.coordinator.fetchStatus()
            fixture.coordinator.tick(at: time)
        }
        XCTAssertEqual(fixture.power.displaySleepCount, 1)
        XCTAssertEqual(fixture.coordinator.fetchStatus().session.remainingSeconds, 58)
    }

    func testMissingOwnedJournalIsRecreatedBeforeRestoreButUnownedPolicyIsUntouched() throws {
        let fixture = Fixture(lidClosed: false)
        try fixture.start()
        fixture.journal.originalValue = nil
        fixture.power.failNextRestore = true
        try fixture.coordinator.stopSession(ownerToken: "owner")
        XCTAssertTrue(fixture.power.sleepDisabled)
        XCTAssertEqual(fixture.journal.originalValue, false)
        fixture.coordinator.tick(at: 1)
        XCTAssertFalse(fixture.power.sleepDisabled)
        XCTAssertNil(fixture.journal.originalValue)
        let unowned = Fixture(lidClosed: false, sleepDisabled: true)
        unowned.coordinator.tick(at: 1)
        unowned.coordinator.shutdown()
        XCTAssertTrue(unowned.power.sleepDisabled)
        XCTAssertTrue(unowned.power.setValues.isEmpty)
    }

    func testPolicyRepairRecreatesMissingJournalBeforeReapplyingOverride() throws {
        let fixture = Fixture(lidClosed: false)
        try fixture.start()
        fixture.power.sleepDisabled = false
        fixture.journal.originalValue = nil
        fixture.power.onSet = { disabled in
            if disabled { XCTAssertEqual(fixture.journal.originalValue, false) }
        }
        fixture.coordinator.tick(at: 1)
        XCTAssertTrue(fixture.power.sleepDisabled)
        XCTAssertEqual(fixture.journal.originalValue, false)
        try fixture.coordinator.stopSession(ownerToken: "owner")
        XCTAssertFalse(fixture.power.sleepDisabled)
    }

    func testSensorReadAndPolicyVerificationFailuresRestoreWithoutReacquisition() throws {
        for failSensors in [true, false] {
            let fixture = Fixture(lidClosed: false)
            try fixture.start()
            if failSensors { fixture.power.failSensors = true }
            else {
                fixture.power.sleepDisabled = false
                fixture.power.failAcquire = true
            }
            fixture.coordinator.tick(at: 1)
            XCTAssertEqual(fixture.coordinator.fetchStatus().session.state, .failed)
            XCTAssertFalse(fixture.power.sleepDisabled)
            XCTAssertNil(fixture.journal.originalValue)
            let attempts = fixture.power.setValues.count
            fixture.coordinator.tick(at: 2)
            XCTAssertEqual(fixture.power.setValues.count, attempts)
        }
    }

}

private struct Fixture {
    let clock: TestClock
    let power: MockPowerSystem
    let journal: MockJournal
    let coordinator: HelperCoordinator

    init(lidClosed: Bool, sleepDisabled: Bool = false, journalValue: Bool? = nil) {
        clock = TestClock(now: 0)
        power = MockPowerSystem(reading: HelperSensorReading(
            lidIsClosed: lidClosed,
            batteryPercentage: 100,
            powerSource: .ac,
            thermalCondition: .nominal
        ), sleepDisabled: sleepDisabled)
        journal = MockJournal(originalValue: journalValue)
        coordinator = HelperCoordinator(power: power, journal: journal, clock: clock)
    }

    func start(seconds: Double = 60) throws {
        try coordinator.startSession(ownerToken: "owner", seconds: seconds, unlimited: false, cutoff: 20)
    }

    func reading(lidClosed: Bool) -> HelperSensorReading {
        HelperSensorReading(lidIsClosed: lidClosed, batteryPercentage: 100, powerSource: .ac, thermalCondition: .nominal)
    }
}

private final class TestClock: HelperMonotonicClock {
    var now: TimeInterval
    init(now: TimeInterval) { self.now = now }
}

private final class MockPowerSystem: HelperPowerSystem {
    var reading: HelperSensorReading
    var sleepDisabled: Bool
    var failNextRestore = false
    var failRestore = false
    var failAcquire = false
    var ignoreAcquire = false
    var ignoreRestore = false
    var failDisplaySleep = false
    var failSensors = false
    var onSet: ((Bool) -> Void)?
    var displaySleepCount = 0
    var setValues: [Bool] = []

    init(reading: HelperSensorReading, sleepDisabled: Bool) {
        self.reading = reading
        self.sleepDisabled = sleepDisabled
    }

    func readSleepDisabled() throws -> Bool { sleepDisabled }

    func setSleepDisabled(_ disabled: Bool) throws {
        setValues.append(disabled)
        onSet?(disabled)
        if disabled && failAcquire { throw MockError.restoreFailed }
        if !disabled && failRestore { throw MockError.restoreFailed }
        if !disabled && failNextRestore {
            failNextRestore = false
            throw MockError.restoreFailed
        }
        if disabled && ignoreAcquire || !disabled && ignoreRestore { return }
        sleepDisabled = disabled
    }

    func sleepDisplays() throws {
        if failDisplaySleep { throw MockError.restoreFailed }
        displaySleepCount += 1
    }
    func readSensors() throws -> HelperSensorReading {
        if failSensors { throw MockError.restoreFailed }
        return reading
    }
}

private final class MockJournal: SleepOverrideJournal {
    var originalValue: Bool?
    var failRead = false
    var failRecord = false
    var failClear = false

    init(originalValue: Bool?) { self.originalValue = originalValue }
    func recordedOriginalValue() throws -> Bool? {
        if failRead { throw JournalError.invalidContents }
        return originalValue
    }
    func record(originalValue: Bool) throws {
        if failRecord { throw MockError.restoreFailed }
        self.originalValue = originalValue
    }
    func clear() throws {
        if failClear { throw MockError.restoreFailed }
        originalValue = nil
    }
}

private enum MockError: Error {
    case restoreFailed
}
