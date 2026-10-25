import Darwin
import Dispatch
import Foundation
import os
import RunAnywaysIPC

private final class HelperService: NSObject, RunAnywaysHelperProtocol {
    private let coordinator: HelperCoordinator
    private let ownerToken: String

    init(coordinator: HelperCoordinator, ownerToken: String) {
        self.coordinator = coordinator
        self.ownerToken = ownerToken
    }

    func fetchStatus(withReply reply: @escaping (Data?, String?) -> Void) {
        reply(try? coordinator.fetchStatus().encoded(), nil)
    }

    func startSession(seconds: Double, unlimited: Bool, cutoff: Int, withReply reply: @escaping (Data?, String?) -> Void) {
        perform(reply) {
            try coordinator.startSession(ownerToken: ownerToken, seconds: seconds, unlimited: unlimited, cutoff: cutoff)
        }
    }

    func extendSession(seconds: Double, withReply reply: @escaping (Data?, String?) -> Void) {
        perform(reply) {
            try coordinator.extendSession(ownerToken: ownerToken, seconds: seconds)
        }
    }

    func stopSession(withReply reply: @escaping (Data?, String?) -> Void) {
        perform(reply) {
            try coordinator.stopSession(ownerToken: ownerToken)
        }
    }

    func heartbeat(withReply reply: @escaping (Data?, String?) -> Void) {
        perform(reply) {
            try coordinator.heartbeat(ownerToken: ownerToken)
        }
    }

    private func perform(_ reply: @escaping (Data?, String?) -> Void, action: () throws -> Void) {
        do {
            try action()
            let data = try coordinator.fetchStatus().encoded()
            reply(data, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let coordinator: HelperCoordinator

    init(coordinator: HelperCoordinator) {
        self.coordinator = coordinator
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let token = UUID().uuidString
        let service = HelperService(coordinator: coordinator, ownerToken: token)
        connection.exportedInterface = NSXPCInterface(with: RunAnywaysHelperProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { [weak coordinator] in
            coordinator?.connectionInvalidated(ownerToken: token)
        }
        connection.interruptionHandler = { [weak coordinator] in
            coordinator?.connectionInvalidated(ownerToken: token)
        }
        connection.resume()
        return true
    }
}

@main
private enum RunAnywaysHelperMain {
    private static let logger = Logger(subsystem: "com.runanyways.RunAnywaysHelper", category: "Lifecycle")
    static func main() {
        logger.notice("Helper process entered main.")
        guard getuid() == 0 else {
            writeError("RunAnywaysHelper must run as root.\n")
            exit(EXIT_FAILURE)
        }

        // SMAppService registers this daemon from the fixed app location. Use
        // that location explicitly instead of trusting launchd's argv[0].
        let appURL = URL(fileURLWithPath: "/Applications/RunAnyways.app", isDirectory: true)
        let appExecutable = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("RunAnyways", isDirectory: false)

        let peerRequirement: String
        do {
            peerRequirement = try RunAnywaysPeerTrust.requirement(
                for: appExecutable,
                expectedIdentifier: RunAnywaysServiceIdentity.appBundleIdentifier,
                enclosingAppURL: appURL
            )
        } catch {
            writeError("RunAnywaysHelper rejected its containing app: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }

        let journal: FileSleepOverrideJournal
        do {
            journal = try FileSleepOverrideJournal()
        } catch {
            writeError("RunAnywaysHelper could not secure its recovery journal: \(error.localizedDescription)\n")
            exit(EXIT_FAILURE)
        }

        let coordinator = HelperCoordinator(power: SystemPower(), journal: journal)
        let delegate = ListenerDelegate(coordinator: coordinator)
        let listener = NSXPCListener(machServiceName: RunAnywaysServiceIdentity.machServiceName)
        listener.setConnectionCodeSigningRequirement(peerRequirement)
        listener.delegate = delegate

        let timerQueue = DispatchQueue(label: "com.runanyways.helper.poll", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + HelperCoordinator.pollInterval, repeating: HelperCoordinator.pollInterval, leeway: .milliseconds(100))
        timer.setEventHandler {
            coordinator.tick(at: ProcessInfo.processInfo.systemUptime)
        }
        timer.resume()

        let signalQueue = DispatchQueue(label: "com.runanyways.helper.signals", qos: .utility)
        var signalSources: [DispatchSourceSignal] = []
        for signalNumber in [SIGTERM, SIGINT] {
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler {
                coordinator.shutdown()
                listener.invalidate()
                exit(EXIT_SUCCESS)
            }
            source.resume()
            signalSources.append(source)
        }

        listener.resume()
        logger.notice("Authenticated Mach service listener is ready.")
        // A named Mach-service listener returns from resume(). Keep the process,
        // delegate, timer, and signal sources alive for launchd requests.
        withExtendedLifetime((listener, delegate, timer, signalSources)) {
            dispatchMain()
        }
    }

    private static func writeError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        FileHandle.standardError.write(Data(message.utf8))
    }
}
