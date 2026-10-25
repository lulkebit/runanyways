import Foundation
import RunAnywaysCore
import RunAnywaysIPC

public protocol HelperMonotonicClock: AnyObject {
    var now: TimeInterval { get }
}

public final class ProcessUptimeClock: HelperMonotonicClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public final class HelperCoordinator {
    public static let ownerLeaseDuration: TimeInterval = 20
    public static let pollInterval: TimeInterval = 0.5

    private let lock = NSRecursiveLock()
    private let power: HelperPowerSystem
    private let journal: SleepOverrideJournal
    private let clock: HelperMonotonicClock
    private var session = Session()
    private var owner: String?
    private var leaseDeadline: TimeInterval?
    private var lastReading: HelperSensorReading?
    private var policyOwned = false
    private var ownedOriginalValue: Bool?
    private var restorationPending = false
    private var journalUnavailable = false
    private var lastErrorMessage: String?
    private var sessionTimestamp: TimeInterval = 0

    public init(
        power: HelperPowerSystem,
        journal: SleepOverrideJournal,
        clock: HelperMonotonicClock = ProcessUptimeClock()
    ) {
        self.power = power
        self.journal = journal
        self.clock = clock

        // A journal read failure cannot safely establish the original policy.
        // Driver/readback failures after a successful read remain retryable.
        do {
            ownedOriginalValue = try journal.recordedOriginalValue()
            restorationPending = ownedOriginalValue != nil
        } catch {
            restorationPending = true
            journalUnavailable = true
            lastErrorMessage = error.localizedDescription
        }
        if restorationPending && !journalUnavailable {
            do { try attemptRestoration() }
            catch { lastErrorMessage = error.localizedDescription }
        }
        lastReading = try? power.readSensors()
    }

    public func fetchStatus() -> HelperStatusSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot(at: validNow())
    }

    public func startSession(
        ownerToken: String,
        seconds: Double,
        unlimited: Bool,
        cutoff: Int
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        let now = try checkedNow()
        try validateStartRequest(seconds: seconds, unlimited: unlimited, cutoff: cutoff)
        guard !journalUnavailable else {
            throw HelperCoordinatorError.recoveryUnavailable(lastErrorMessage ?? "The recovery journal is unavailable.")
        }
        if restorationPending {
            try attemptRestoration()
        }
        guard !restorationPending else {
            throw HelperCoordinatorError.restorationPending(lastErrorMessage ?? "Sleep policy restoration is pending.")
        }
        guard owner == nil else {
            if owner == ownerToken {
                throw HelperCoordinatorError.sessionAlreadyOwned
            }
            throw HelperCoordinatorError.anotherConnectionOwnsSession
        }

        let reading = try power.readSensors()
        let lidIsClosed = try validatedLidState(reading, cutoff: cutoff)

        // SleepDisabled belongs to another tool unless this helper has a journal.
        // Refuse before writing the journal or invoking pmset.
        guard try !power.readSleepDisabled() else {
            throw HelperCoordinatorError.sleepAlreadyDisabled
        }
        try journal.record(originalValue: false)
        ownedOriginalValue = false
        restorationPending = true
        do {
            try power.setSleepDisabled(true)
            guard try power.readSleepDisabled() else {
                throw HelperCoordinatorError.sleepPolicyNotApplied
            }
            if lidIsClosed {
                try power.sleepDisplays()
            }
            policyOwned = true
            restorationPending = false
            try session.start(
                seconds: unlimited ? nil : seconds,
                cutoffPercentage: cutoff,
                lidIsClosed: lidIsClosed,
                at: now
            )
            sessionTimestamp = now
            owner = ownerToken
            leaseDeadline = now + Self.ownerLeaseDuration
            lastReading = reading
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            try? attemptRestoration()
            throw error
        }
    }

    public func extendSession(ownerToken: String, seconds: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = try checkedNow()
        try checkpointOwnedSession(ownerToken, at: now)
        do {
            try session.extend(by: seconds, at: now)
            lastErrorMessage = nil
        } catch {
            // Session.extend checkpoints before validating the request. If the
            // old time expired at this instant, restore even though extension
            // returns an invalid-transition error.
            if !isSessionActive {
                closeAfterSessionEnd(at: now, reason: .expired)
            }
            throw error
        }
    }

    public func stopSession(ownerToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = try checkedNow()

        if let owner, owner != ownerToken {
            throw HelperCoordinatorError.anotherConnectionOwnsSession
        }
        if isSessionActive {
            try requireOwner(ownerToken)
            closeAfterSessionEnd(at: now, reason: .stopped)
        } else if restorationPending {
            // A new authenticated client may retry cleanup after the old owner
            // disconnected; this cannot start or extend a session.
            try attemptRestoration()
        }
    }

    public func heartbeat(ownerToken: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let now = try checkedNow()
        try checkpointOwnedSession(ownerToken, at: now)
        leaseDeadline = now + Self.ownerLeaseDuration
        lastErrorMessage = nil
    }

    public func connectionInvalidated(ownerToken: String) {
        lock.lock()
        defer { lock.unlock() }
        guard owner == ownerToken else { return }
        let now = validNow()
        if isSessionActive {
            closeAfterSessionEnd(at: now, reason: .stopped)
        }
        owner = nil
        leaseDeadline = nil
        if restorationPending { try? attemptRestoration() }
    }

    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if isSessionActive {
            closeAfterSessionEnd(at: validNow(), reason: .stopped)
        }
        // A terminating daemon cannot wait for the polling timer. Keep retries
        // bounded; the durable journal remains for the next launch if all fail.
        for _ in 0..<2 where restorationPending {
            try? attemptRestoration()
        }
        owner = nil
        leaseDeadline = nil
    }

    /// Poll on a monotonic timer. Lid state, battery cutoff, thermal pressure,
    /// lease expiration, and the applied sleep policy are all checked here.
    public func tick(at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard timestamp.isFinite, timestamp >= 0 else {
            if isSessionActive {
                failAndRestore("The helper clock returned an invalid timestamp.", at: sessionTimestamp)
            } else {
                lastErrorMessage = "The helper clock returned an invalid timestamp."
            }
            return
        }

        if restorationPending { try? attemptRestoration() }
        guard !journalUnavailable, !restorationPending else { return }
        guard isSessionActive else {
            lastReading = try? power.readSensors()
            return
        }

        if let leaseDeadline, timestamp >= leaseDeadline {
            closeAfterSessionEnd(at: timestamp, reason: .stopped)
            return
        }
        do {
            try session.advance(to: timestamp)
            sessionTimestamp = timestamp
        } catch {
            failAndRestore("The helper session clock failed: \(error.localizedDescription)", at: timestamp)
            return
        }
        guard isSessionActive else {
            closeAfterSessionEnd(at: timestamp, reason: session.endReason ?? .expired)
            return
        }

        let reading: HelperSensorReading
        let lidIsClosed: Bool
        do {
            reading = try power.readSensors()
            lidIsClosed = try validatedLidState(reading, cutoff: session.cutoffPercentage)
        } catch HelperCoordinatorError.thermalPressure {
            closeAfterSessionEnd(at: timestamp, reason: .thermalPressure)
            return
        } catch HelperCoordinatorError.lowBattery {
            closeAfterSessionEnd(at: timestamp, reason: .lowBattery)
            return
        } catch {
            failAndRestore("Could not verify lid or power safety: \(error.localizedDescription)", at: timestamp)
            return
        }

        if !lidIsClosed, session.state == .running {
            do { try session.lidDidOpen(at: timestamp) }
            catch { failAndRestore("Could not pause after lid opening: \(error.localizedDescription)", at: timestamp); return }
        } else if lidIsClosed, session.state == .armed || session.state == .paused {
            do { try power.sleepDisplays() }
            catch { failAndRestore("Could not put displays to sleep on lid closure: \(error.localizedDescription)", at: timestamp); return }
            do { try session.lidDidClose(at: timestamp) }
            catch { failAndRestore("Could not resume after lid closure: \(error.localizedDescription)", at: timestamp); return }
        }

        do {
            if try !power.readSleepDisabled() {
                // Repairing an externally changed policy is another mutation:
                // ensure it still has a durable recovery record first.
                if try journal.recordedOriginalValue() == nil {
                    guard let original = ownedOriginalValue else {
                        throw HelperCoordinatorError.recoveryUnavailable("The owned original sleep policy is unavailable.")
                    }
                    try journal.record(originalValue: original)
                }
                try power.setSleepDisabled(true)
                guard try power.readSleepDisabled() else {
                    throw HelperCoordinatorError.sleepPolicyNotApplied
                }
            }
            policyOwned = true
            lastErrorMessage = nil
        } catch {
            failAndRestore("The sleep policy could not be verified: \(error.localizedDescription)", at: timestamp)
            return
        }
        lastReading = reading
    }

    private func closeAfterSessionEnd(at timestamp: TimeInterval, reason: SessionEndReason) {
        let cleanupTimestamp = max(sessionTimestamp, timestamp)
        if isSessionActive {
            do {
                try session.end(reason: reason, at: cleanupTimestamp)
            } catch {
                // Expiration may checkpoint the state to ended before throwing.
                // Any other error must also leave the session inactive before
                // restoration, so a later poll cannot reacquire the override.
                if isSessionActive {
                    try? session.fail(error.localizedDescription, at: cleanupTimestamp)
                }
            }
            sessionTimestamp = cleanupTimestamp
        }
        do { try attemptRestoration() }
        catch {
            lastErrorMessage = "Session ended, but sleep policy restoration is pending: \(error.localizedDescription)"
        }
    }

    private func failAndRestore(_ message: String, at timestamp: TimeInterval) {
        let cleanupTimestamp = max(sessionTimestamp, timestamp)
        try? session.fail(message, at: cleanupTimestamp)
        sessionTimestamp = cleanupTimestamp
        lastErrorMessage = message
        do { try attemptRestoration() }
        catch {
            lastErrorMessage = "\(message) Sleep policy restoration is pending: \(error.localizedDescription)"
        }
    }

    private func attemptRestoration() throws {
        guard !journalUnavailable else {
            throw HelperCoordinatorError.recoveryUnavailable(lastErrorMessage ?? "The helper journal is unavailable.")
        }
        let originalValue: Bool?
        do { originalValue = try journal.recordedOriginalValue() }
        catch {
            restorationPending = true
            journalUnavailable = true
            throw error
        }
        guard let original = originalValue ?? ownedOriginalValue else {
            restorationPending = false
            policyOwned = false
            owner = nil
            leaseDeadline = nil
            return
        }
        restorationPending = true
        ownedOriginalValue = original
        if originalValue == nil {
            // Retain recovery across a daemon crash even if an owned journal
            // disappeared. A fresh daemon with no record never guesses ownership.
            try journal.record(originalValue: original)
        }
        try power.setSleepDisabled(original)
        guard try power.readSleepDisabled() == original else {
            throw HelperCoordinatorError.sleepPolicyNotRestored
        }
        try journal.clear()
        ownedOriginalValue = nil
        restorationPending = false
        policyOwned = false
        owner = nil
        leaseDeadline = nil
        lastErrorMessage = nil
    }

    private func makeSnapshot(at timestamp: TimeInterval) -> HelperStatusSnapshot {
        let sensorReading = (try? power.readSensors()) ?? lastReading
        let snapshot: SessionSnapshot
        do { snapshot = try session.snapshot(at: timestamp) }
        catch {
            return HelperStatusSnapshot(
                session: SessionSnapshot(state: .failed, remainingSeconds: 0, cutoffPercentage: session.cutoffPercentage, failureMessage: error.localizedDescription),
                protectionVerified: false,
                lidIsClosed: sensorReading?.lidIsClosed ?? false,
                batteryPercentage: sensorReading?.batteryPercentage,
                powerSource: sensorReading?.powerSource ?? .unknown,
                thermalCondition: sensorReading?.thermalCondition ?? .unknown,
                lastErrorMessage: lastErrorMessage ?? error.localizedDescription
            )
        }
        let overrideVerified = (try? power.readSleepDisabled()) == true
        return HelperStatusSnapshot(
            session: snapshot,
            protectionVerified: overrideVerified && policyOwned && snapshot.isActive && !restorationPending && (leaseDeadline.map { timestamp < $0 } ?? false),
            lidIsClosed: sensorReading?.lidIsClosed ?? false,
            batteryPercentage: sensorReading?.batteryPercentage,
            powerSource: sensorReading?.powerSource ?? .unknown,
            thermalCondition: sensorReading?.thermalCondition ?? .unknown,
            lastErrorMessage: lastErrorMessage
        )
    }

    private func validateStartRequest(seconds: Double, unlimited: Bool, cutoff: Int) throws {
        guard (Session.minimumCutoffPercentage...Session.maximumCutoffPercentage).contains(cutoff) else {
            throw SessionError.invalidCutoff
        }
        if unlimited {
            guard seconds == 0 else { throw SessionError.invalidDuration }
        } else {
            guard seconds.isFinite, seconds > 0 else { throw SessionError.invalidDuration }
            guard seconds <= Session.maximumDuration else { throw SessionError.durationLimitExceeded }
        }
    }

    /// Check lifetime before accepting any request that could prolong a session.
    /// Ownership is checked first so an unrelated connection cannot mutate it.
    private func checkpointOwnedSession(_ token: String, at timestamp: TimeInterval) throws {
        try requireOwner(token)
        if let leaseDeadline, timestamp >= leaseDeadline {
            closeAfterSessionEnd(at: timestamp, reason: .stopped)
            throw HelperCoordinatorError.ownerLeaseExpired
        }
        guard isSessionActive && !restorationPending else {
            throw SessionError.invalidTransition
        }
        do {
            try session.advance(to: timestamp)
            sessionTimestamp = timestamp
        } catch {
            failAndRestore("The helper session clock failed: \(error.localizedDescription)", at: timestamp)
            throw error
        }
        guard isSessionActive else {
            closeAfterSessionEnd(at: timestamp, reason: session.endReason ?? .expired)
            throw SessionError.invalidTransition
        }
    }

    private func validatedLidState(_ reading: HelperSensorReading, cutoff: Int) throws -> Bool {
        guard let lidIsClosed = reading.lidIsClosed else { throw HelperCoordinatorError.lidStateUnavailable }
        guard reading.thermalCondition != .unknown else { throw HelperCoordinatorError.thermalStateUnavailable }
        if reading.thermalCondition == .serious || reading.thermalCondition == .critical {
            throw HelperCoordinatorError.thermalPressure
        }
        guard reading.powerSource != .unknown else { throw HelperCoordinatorError.powerSourceUnavailable }
        if reading.powerSource == .battery {
            guard let battery = reading.batteryPercentage, (0...100).contains(battery) else {
                throw HelperCoordinatorError.batteryStateUnavailable
            }
            if battery <= cutoff { throw HelperCoordinatorError.lowBattery(battery, cutoff) }
        }
        return lidIsClosed
    }

    private func requireOwner(_ token: String) throws {
        guard owner == token else {
            if owner == nil { throw HelperCoordinatorError.noSessionOwner }
            throw HelperCoordinatorError.anotherConnectionOwnsSession
        }
    }

    private func checkedNow() throws -> TimeInterval {
        let timestamp = clock.now
        guard timestamp.isFinite, timestamp >= 0 else { throw SessionError.invalidTimestamp }
        return timestamp
    }

    private func validNow() -> TimeInterval {
        let timestamp = clock.now
        return timestamp.isFinite && timestamp >= 0 ? max(timestamp, sessionTimestamp) : sessionTimestamp
    }

    private var isSessionActive: Bool {
        session.state == .armed || session.state == .running || session.state == .paused
    }
}

public enum HelperCoordinatorError: Error, LocalizedError {
    case anotherConnectionOwnsSession
    case sessionAlreadyOwned
    case noSessionOwner
    case ownerLeaseExpired
    case sleepAlreadyDisabled
    case sleepPolicyNotApplied
    case sleepPolicyNotRestored
    case lidStateUnavailable
    case powerSourceUnavailable
    case batteryStateUnavailable
    case thermalStateUnavailable
    case thermalPressure
    case lowBattery(Int, Int)
    case recoveryUnavailable(String)
    case restorationPending(String)

    public var errorDescription: String? {
        switch self {
        case .anotherConnectionOwnsSession: "Another helper connection owns the active session."
        case .sessionAlreadyOwned: "This connection already owns an active session."
        case .ownerLeaseExpired: "The connection heartbeat lease expired; start a new session."
        case .noSessionOwner: "This connection does not own a session."
        case .sleepAlreadyDisabled: "Sleep is already disabled by another tool; RunAnyways will not take ownership."
        case .sleepPolicyNotApplied: "The helper could not verify that macOS disabled system sleep."
        case .sleepPolicyNotRestored: "The helper could not verify that macOS restored the original sleep policy."
        case .powerSourceUnavailable: "The helper could not determine whether the Mac is on battery or AC power."
        case .batteryStateUnavailable: "The helper could not determine the remaining battery percentage."
        case .thermalStateUnavailable: "The helper could not determine the thermal condition."
        case .lidStateUnavailable: "The helper could not read the built-in lid state."
        case .thermalPressure: "The session cannot start while thermal pressure is serious or critical."
        case .lowBattery(let current, let cutoff): "Battery is already at \(current)%, at or below the \(cutoff)% cutoff."
        case .recoveryUnavailable(let message): "Helper recovery is unavailable: \(message)"
        case .restorationPending(let message): "Sleep policy restoration is pending: \(message)"
        }
    }
}
