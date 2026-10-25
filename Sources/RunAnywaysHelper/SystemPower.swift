import Darwin
import Foundation
import IOKit
import IOKit.ps
import RunAnywaysIPC

public struct HelperSensorReading: Equatable, Sendable {
    public let lidIsClosed: Bool?
    public let batteryPercentage: Int?
    public let powerSource: HelperPowerSource
    public let thermalCondition: HelperThermalCondition

    public init(
        lidIsClosed: Bool?,
        batteryPercentage: Int?,
        powerSource: HelperPowerSource,
        thermalCondition: HelperThermalCondition
    ) {
        self.lidIsClosed = lidIsClosed
        self.batteryPercentage = batteryPercentage
        self.powerSource = powerSource
        self.thermalCondition = thermalCondition
    }
}

/// System operations used by the coordinator. The protocol keeps privileged
/// mutations out of deterministic tests.
public protocol HelperPowerSystem: AnyObject {
    func readSleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
    func sleepDisplays() throws
    func readSensors() throws -> HelperSensorReading
}

/// Production power implementation. The only process launched here is the
/// fixed `/usr/bin/pmset` executable with `disablesleep` or `displaysleepnow`.
/// It never writes saved brightness settings.
public final class SystemPower: HelperPowerSystem {
    public init() {}

    public func readSleepDisabled() throws -> Bool {
        guard let value = try rootDomainProperty("SleepDisabled") else {
            // macOS omits SleepDisabled when the override is off.
            return false
        }
        guard let number = value as? NSNumber else {
            throw SystemPowerError.invalidPowerProperty("SleepDisabled")
        }
        return number.boolValue
    }

    public func setSleepDisabled(_ disabled: Bool) throws {
        try runPMSet(arguments: ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    public func sleepDisplays() throws {
        try runPMSet(arguments: ["displaysleepnow"])
    }

    public func readSensors() throws -> HelperSensorReading {
        let lidIsClosed: Bool?
        if let value = try rootDomainProperty("AppleClamshellState") as? NSNumber {
            lidIsClosed = value.boolValue
        } else {
            lidIsClosed = nil
        }

        let (batteryPercentage, powerSource) = readPowerSource()
        return HelperSensorReading(
            lidIsClosed: lidIsClosed,
            batteryPercentage: batteryPercentage,
            powerSource: powerSource,
            thermalCondition: Self.thermalCondition(ProcessInfo.processInfo.thermalState)
        )
    }

    private func rootDomainProperty(_ key: String) throws -> CFTypeRef? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { throw SystemPowerError.rootDomainUnavailable }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private func runPMSet(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            throw SystemPowerError.pmsetUnavailable
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            throw SystemPowerError.pmsetTimedOut
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw SystemPowerError.pmsetFailed
        }
    }

    private func readPowerSource() -> (Int?, HelperPowerSource) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, .unknown)
        }

        var batteryPercentage: Int?
        var powerSource = HelperPowerSource.unknown
        for source in sources {
            guard let unmanagedDescription = IOPSGetPowerSourceDescription(info, source),
                  let description = unmanagedDescription.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else {
                continue
            }

            if let state = description[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSACPowerValue {
                    powerSource = .ac
                } else if state == kIOPSBatteryPowerValue {
                    powerSource = .battery
                }
            }

            guard batteryPercentage == nil,
                  let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.intValue > 0 else {
                continue
            }
            batteryPercentage = min(100, max(0, Int((Double(current.intValue) / Double(maximum.intValue) * 100).rounded(.down))))
        }
        return (batteryPercentage, powerSource)
    }

    private static func thermalCondition(_ state: ProcessInfo.ThermalState) -> HelperThermalCondition {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}

public enum SystemPowerError: Error, LocalizedError {
    case rootDomainUnavailable
    case invalidPowerProperty(String)
    case pmsetUnavailable
    case pmsetFailed
    case pmsetTimedOut

    public var errorDescription: String? {
        switch self {
        case .rootDomainUnavailable: "The system power management root domain is unavailable."
        case .invalidPowerProperty(let key): "The system power property \(key) is invalid."
        case .pmsetUnavailable: "Could not start the system power policy command."
        case .pmsetFailed: "macOS did not accept the sleep policy change."
        case .pmsetTimedOut: "The system power policy command did not finish within three seconds."
        }
    }
}
