import AppKit
import Combine
import Darwin
import ServiceManagement
import SwiftUI
import RunAnywaysIPC

@main
private enum RunAnywaysLauncher {
    @MainActor
    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        let renderDirectory: URL?
        do {
            renderDirectory = try parsePreviewRenderDirectory(arguments)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
        if renderDirectory != nil &&
            (arguments.contains("--helper-status") || arguments.contains("--register-helper")) {
            FileHandle.standardError.write(Data("--render-preview cannot be combined with helper status or registration commands.\n".utf8))
            exit(2)
        }

        let service = SMAppService.daemon(plistName: RunAnywaysServiceIdentity.launchDaemonPlistName)
        if let exitCode = HelperSetupCommandLine.runIfRequested(
            arguments: arguments,
            appURL: Bundle.main.bundleURL,
            service: service
        ) {
            exit(exitCode)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate(previewRenderDirectory: renderDirectory)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    private static func parsePreviewRenderDirectory(_ arguments: [String]) throws -> URL? {
        let renderFlags = arguments.indices.filter { arguments[$0] == "--render-preview" }
        guard renderFlags.count <= 1 else {
            throw PreviewCommandError("Use --render-preview only once.")
        }
        guard let flagIndex = renderFlags.first else { return nil }
        guard arguments.contains("--preview") else {
            throw PreviewCommandError("--render-preview requires --preview; preview mode never contacts the helper.")
        }
        let pathIndex = arguments.index(after: flagIndex)
        guard pathIndex < arguments.endIndex,
              !arguments[pathIndex].hasPrefix("--") else {
            throw PreviewCommandError("Pass an output directory after --render-preview.")
        }
        return URL(fileURLWithPath: arguments[pathIndex], isDirectory: true).standardizedFileURL
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let previewRenderDirectory: URL?
    private var model: AppModel?
    private var statusPopoverController: StatusPopoverController?

    init(previewRenderDirectory: URL?) {
        self.previewRenderDirectory = previewRenderDirectory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        model.start()

        let controller = StatusPopoverController(model: model)
        statusPopoverController = controller

        guard model.isPreview else { return }
        DispatchQueue.main.async { [weak controller] in
            controller?.showPreview(renderDirectory: self.previewRenderDirectory)
        }
    }
}

private struct PreviewCommandError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}
