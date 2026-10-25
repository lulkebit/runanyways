import Foundation

/// The lifecycle of a single sleep-protection session.
public enum SessionState: String, Codable, CaseIterable, Sendable {
    case idle
    /// Waiting for the lid to close before consuming the selected duration.
    case armed
    /// The lid is closed and the selected duration is being consumed.
    case running
    /// The lid was opened; the remaining duration is held until the next close.
    case paused
    case ended
    case failed
}

public enum SessionEndReason: String, Codable, Sendable {
    case stopped
    case expired
    case lowBattery
    case thermalPressure
}

public enum SessionError: Error, Equatable, LocalizedError, Sendable {
    case invalidTimestamp
    case timestampMovedBackwards
    case invalidDuration
    case invalidCutoff
    case invalidTransition
    case unlimitedCannotBeExtended
    case durationLimitExceeded
    case emptyFailureMessage

    public var errorDescription: String? {
        switch self {
        case .invalidTimestamp:
            return "The monotonic timestamp must be a finite, nonnegative number."
        case .timestampMovedBackwards:
            return "Monotonic timestamps cannot move backwards."
        case .invalidDuration:
            return "A timed session must have a positive duration."
        case .invalidCutoff:
            return "The battery cutoff must be between 5% and 50%."
        case .invalidTransition:
            return "The session cannot perform that action in its current state."
        case .unlimitedCannotBeExtended:
            return "An unlimited session cannot be extended."
        case .durationLimitExceeded:
            return "The requested duration exceeds the session limit."
        case .emptyFailureMessage:
            return "A failure message cannot be empty."
        }
    }
}

/// A transport-friendly point-in-time view of a Session.
///
/// `remainingSeconds == nil` denotes an unlimited session. A helper should create this
/// value only after it has checked its current power-policy state; the menu-bar app must
/// not treat the session state by itself as proof that sleep protection is active.
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public let state: SessionState
    public let remainingSeconds: TimeInterval?
    public let cutoffPercentage: Int
    public let endReason: SessionEndReason?
    public let failureMessage: String?

    public init(
        state: SessionState,
        remainingSeconds: TimeInterval?,
        cutoffPercentage: Int,
        endReason: SessionEndReason? = nil,
        failureMessage: String? = nil
    ) {
        self.state = state
        self.remainingSeconds = remainingSeconds
        self.cutoffPercentage = cutoffPercentage
        self.endReason = endReason
        self.failureMessage = failureMessage
    }

    public var isUnlimited: Bool { remainingSeconds == nil && state != .idle }
    public var isActive: Bool {
        state == .armed || state == .running || state == .paused
    }
    public var canExtend: Bool { isActive && !isUnlimited }
}

/// Pure session lifecycle and countdown state.
///
/// The caller supplies timestamps from a monotonic clock (for example
/// `ProcessInfo.processInfo.systemUptime`). No timers, system calls, or wall-clock dates
/// are used here, which keeps state transitions deterministic and testable.
public struct Session: Equatable, Sendable {
    public static let defaultCutoffPercentage = 20
    public static let minimumCutoffPercentage = 5
    public static let maximumCutoffPercentage = 50
    public static let maximumDuration: TimeInterval = 24 * 60 * 60

    public private(set) var state: SessionState = .idle
    public private(set) var remainingSeconds: TimeInterval?
    public private(set) var cutoffPercentage = Self.defaultCutoffPercentage
    public private(set) var endReason: SessionEndReason?
    public private(set) var failureMessage: String?

    /// Timestamp of the latest state transition or countdown checkpoint.
    private var lastTimestamp: TimeInterval?

    public init() {}

    /// Arms a new session. `seconds == nil` means unlimited.
    /// If the lid is already closed, countdown starts immediately; otherwise it waits
    /// in `.armed` until `lidDidClose(at:)` is received.
    public mutating func start(
        seconds: TimeInterval?,
        cutoffPercentage: Int = Self.defaultCutoffPercentage,
        lidIsClosed: Bool,
        at timestamp: TimeInterval
    ) throws {
        try validateTimestamp(timestamp)
        guard state == .idle || state == .ended || state == .failed else {
            throw SessionError.invalidTransition
        }
        try Self.validateCutoff(cutoffPercentage)
        if let seconds {
            try Self.validateDuration(seconds)
        }

        state = lidIsClosed ? .running : .armed
        remainingSeconds = seconds
        self.cutoffPercentage = cutoffPercentage
        endReason = nil
        failureMessage = nil
        lastTimestamp = timestamp
    }

    /// Consumes elapsed time and pauses the countdown when the lid opens.
    public mutating func lidDidOpen(at timestamp: TimeInterval) throws {
        try checkpoint(at: timestamp)
        guard state == .running else { return }
        state = .paused
        lastTimestamp = timestamp
    }

    /// Starts or resumes countdown when the lid closes.
    public mutating func lidDidClose(at timestamp: TimeInterval) throws {
        try checkpoint(at: timestamp)
        guard state == .armed || state == .paused else { return }
        state = .running
        lastTimestamp = timestamp
    }

    /// Checkpoints countdown time. The session ends as soon as a finite duration is used up.
    public mutating func advance(to timestamp: TimeInterval) throws {
        try checkpoint(at: timestamp)
    }

    /// Adds a bounded positive duration to an active timed session.
    public mutating func extend(by seconds: TimeInterval, at timestamp: TimeInterval) throws {
        try checkpoint(at: timestamp)
        guard state == .armed || state == .running || state == .paused else {
            throw SessionError.invalidTransition
        }
        guard let remainingSeconds else {
            throw SessionError.unlimitedCannotBeExtended
        }
        try Self.validateDuration(seconds)
        guard remainingSeconds + seconds <= Self.maximumDuration else {
            throw SessionError.durationLimitExceeded
        }
        self.remainingSeconds = remainingSeconds + seconds
        lastTimestamp = timestamp
    }

    /// Ends an active session and records why protection was stopped.
    public mutating func end(
        reason: SessionEndReason = .stopped,
        at timestamp: TimeInterval
    ) throws {
        try checkpoint(at: timestamp)
        guard state == .armed || state == .running || state == .paused else {
            throw SessionError.invalidTransition
        }
        state = .ended
        endReason = reason
        lastTimestamp = timestamp
    }

    /// Records a helper failure and ends the countdown.
    public mutating func fail(_ message: String, at timestamp: TimeInterval) throws {
        try validateTimestamp(timestamp)
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionError.emptyFailureMessage
        }
        if let lastTimestamp, timestamp < lastTimestamp {
            throw SessionError.timestampMovedBackwards
        }
        state = .failed
        remainingSeconds = 0
        endReason = nil
        failureMessage = message
        lastTimestamp = timestamp
    }

    /// Returns the visible state at a monotonic timestamp without mutating this value.
    public func snapshot(at timestamp: TimeInterval) throws -> SessionSnapshot {
        try Self.validateTimestamp(timestamp)
        if let lastTimestamp, timestamp < lastTimestamp {
            throw SessionError.timestampMovedBackwards
        }

        guard state == .running,
              let remainingSeconds,
              let lastTimestamp else {
            return makeSnapshot(state: state, remainingSeconds: remainingSeconds)
        }

        let projected = max(0, remainingSeconds - (timestamp - lastTimestamp))
        if projected == 0 {
            return makeSnapshot(state: .ended, remainingSeconds: 0, endReason: .expired)
        }
        return makeSnapshot(state: state, remainingSeconds: projected)
    }

    private mutating func checkpoint(at timestamp: TimeInterval) throws {
        try validateTimestamp(timestamp)
        if let lastTimestamp, timestamp < lastTimestamp {
            throw SessionError.timestampMovedBackwards
        }

        if state == .running, let remainingSeconds, let lastTimestamp {
            let updated = max(0, remainingSeconds - (timestamp - lastTimestamp))
            self.remainingSeconds = updated
            if updated == 0 {
                state = .ended
                endReason = .expired
            }
        }
        lastTimestamp = timestamp
    }

    private mutating func validateTimestamp(_ timestamp: TimeInterval) throws {
        try Self.validateTimestamp(timestamp)
        if let lastTimestamp, timestamp < lastTimestamp {
            throw SessionError.timestampMovedBackwards
        }
    }

    private func makeSnapshot(
        state: SessionState,
        remainingSeconds: TimeInterval?,
        endReason: SessionEndReason? = nil
    ) -> SessionSnapshot {
        SessionSnapshot(
            state: state,
            remainingSeconds: remainingSeconds,
            cutoffPercentage: cutoffPercentage,
            endReason: endReason ?? self.endReason,
            failureMessage: failureMessage
        )
    }

    private static func validateTimestamp(_ timestamp: TimeInterval) throws {
        guard timestamp.isFinite, timestamp >= 0 else {
            throw SessionError.invalidTimestamp
        }
    }

    private static func validateDuration(_ seconds: TimeInterval) throws {
        guard seconds.isFinite, seconds > 0 else {
            throw SessionError.invalidDuration
        }
        guard seconds <= maximumDuration else {
            throw SessionError.durationLimitExceeded
        }
    }

    private static func validateCutoff(_ percentage: Int) throws {
        guard (minimumCutoffPercentage...maximumCutoffPercentage).contains(percentage) else {
            throw SessionError.invalidCutoff
        }
    }
}
