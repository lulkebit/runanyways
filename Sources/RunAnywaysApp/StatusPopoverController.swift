import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

@MainActor
final class StatusPopoverController: NSObject, NSPopoverDelegate {
    private static let contentWidth: CGFloat = 340

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var hostingController: NSHostingController<RunAnywaysPopover>!
    private var modelObservation: AnyCancellable?
    private var previewAnchorWindow: NSWindow?
    private var previewAnchorKind = "statusItem"

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let hostingController = NSHostingController(rootView: RunAnywaysPopover(model: model))
        if #available(macOS 13.0, *) {
            hostingController.sizingOptions = [.preferredContentSize]
        }
        self.hostingController = hostingController
        popover.contentViewController = hostingController
        updatePopoverContentSize()

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        updateStatusItem()

        modelObservation = model.objectWillChange.sink { [weak self] in
            // ObservableObject publishes before the value changes. Read the
            // final values on the next main-queue turn for a coherent label.
            DispatchQueue.main.async { [weak self] in
                self?.updateStatusItem()
            }
        }
    }

    func showPopover() {
        guard !popover.isShown, statusItemButtonIsReady, let button = statusItem.button else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        popover.appearance = NSApp.effectiveAppearance
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func showPreview(renderDirectory: URL?) {
        showPreviewWhenReady(renderDirectory: renderDirectory, attemptsRemaining: 20)
    }

    private func showPreviewWhenReady(renderDirectory: URL?, attemptsRemaining: Int) {
        guard statusItem.button != nil else {
            if let renderDirectory {
                showPreviewInOwnedWindow(renderDirectory: renderDirectory)
            } else {
                finishPreviewFailure("The menu bar status item was not created.")
            }
            return
        }
        guard statusItemButtonIsReady else {
            guard attemptsRemaining > 0 else {
                if let renderDirectory {
                    showPreviewInOwnedWindow(renderDirectory: renderDirectory)
                } else {
                    finishPreviewFailure("The menu bar status item did not attach to a window.")
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.showPreviewWhenReady(
                    renderDirectory: renderDirectory,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        showPopover()
        guard let renderDirectory else { return }
        renderPreviewWhenReady(
            renderDirectory: renderDirectory,
            attemptsRemaining: 20,
            allowPreviewAnchor: true
        )
    }

    private func showPreviewInOwnedWindow(renderDirectory: URL) {
        previewAnchorKind = "temporaryPreviewWindow"
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        anchorWindow.isReleasedWhenClosed = false
        anchorWindow.isOpaque = false
        anchorWindow.backgroundColor = .clear
        anchorWindow.alphaValue = 0.01
        anchorWindow.level = .floating
        anchorWindow.orderFrontRegardless()
        previewAnchorWindow = anchorWindow

        guard let anchor = anchorWindow.contentView else {
            finishPreviewFailure("The preview anchor window has no content view.")
            return
        }
        popover.appearance = NSApp.effectiveAppearance
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        renderPreviewWhenReady(renderDirectory: renderDirectory, attemptsRemaining: 20)
    }

    private func renderPreviewWhenReady(
        renderDirectory: URL,
        attemptsRemaining: Int,
        allowPreviewAnchor: Bool = false
    ) {
        if allowPreviewAnchor, !popover.isShown {
            showPopover()
        }
        guard popover.isShown, hostingController.view.window != nil else {
            guard attemptsRemaining > 0 else {
                if allowPreviewAnchor {
                    showPreviewInOwnedWindow(renderDirectory: renderDirectory)
                    return
                }
                finishPreviewFailure("The native popover did not become visible.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.renderPreviewWhenReady(
                    renderDirectory: renderDirectory,
                    attemptsRemaining: attemptsRemaining - 1,
                    allowPreviewAnchor: allowPreviewAnchor
                )
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            do {
                try self.renderPreview(to: renderDirectory)
                self.finishPreviewSuccess(renderDirectory)
            } catch {
                self.finishPreviewFailure(error.localizedDescription)
            }
        }
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let label = model.menuBarAccessibilityLabel
        let image = NSImage(
            systemSymbolName: model.menuBarSymbol,
            accessibilityDescription: label
        )
        image?.isTemplate = true
        button.image = image
        button.title = model.menuBarTitle.map { " \($0)" } ?? ""
        button.imagePosition = model.menuBarTitle == nil ? .imageOnly : .imageLeading
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private var statusItemButtonIsReady: Bool {
        guard statusItem.isVisible,
              let button = statusItem.button,
              let window = button.window else {
            return false
        }
        return window.isVisible &&
            !button.isHiddenOrHasHiddenAncestor &&
            button.bounds.width > 0 &&
            button.bounds.height > 0
    }

    private func updatePopoverContentSize() {
        let proposed = hostingController.sizeThatFits(
            in: CGSize(width: Self.contentWidth, height: 2_000)
        )
        guard proposed.width.isFinite, proposed.height.isFinite,
              proposed.width > 0, proposed.height > 0 else {
            return
        }

        // Assigning the host before measuring gives the popover an exact first
        // size; sizingOptions then tracks disclosure and status text changes.
        popover.contentSize = NSSize(
            width: Self.contentWidth,
            height: ceil(proposed.height)
        )
    }

    private func renderPreview(to directory: URL) throws {
        guard popover.isShown,
              let window = hostingController.view.window,
              let contentView = window.contentView else {
            throw PreviewRenderError.popoverUnavailable
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var appearanceRecords: [PreviewAppearanceRecord] = []
        let originalAppearance = window.appearance
        let originalPopoverAppearance = popover.appearance

        for previewAppearance in PreviewAppearance.allCases {
            let (name, appearanceName, filename) = previewAppearance.descriptor
            guard let appearance = NSAppearance(named: appearanceName) else {
                throw PreviewRenderError.appearanceUnavailable(name)
            }
            popover.appearance = appearance
            window.appearance = appearance
            window.contentView?.needsDisplay = true
            window.contentView?.needsLayout = true
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()

            // Give SwiftUI and the native visual effect view one render turn
            // after the appearance changes before snapshotting the owned window.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
            window.displayIfNeeded()

            let panelView = contentView.superview ?? contentView
            let bounds = panelView.bounds
            guard bounds.width > 0, bounds.height > 0,
                  let bitmap = panelView.bitmapImageRepForCachingDisplay(in: bounds) else {
                throw PreviewRenderError.snapshotUnavailable(name)
            }
            panelView.cacheDisplay(in: bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw PreviewRenderError.snapshotUnavailable(name)
            }
            try png.write(to: directory.appendingPathComponent(filename), options: .atomic)

            appearanceRecords.append(
                PreviewAppearanceRecord(
                    appearance: name,
                    image: filename,
                    contentSize: PreviewSize(popover.contentSize),
                    windowFrame: PreviewRect(window.frame),
                    panelViewBounds: PreviewRect(panelView.bounds),
                    windowContentBounds: PreviewRect(contentView.bounds),
                    hostingViewBounds: PreviewRect(hostingController.view.bounds),
                    hostingSafeAreaInsets: PreviewInsets(hostingController.view.safeAreaInsets),
                    preferredContentSize: PreviewSize(hostingController.preferredContentSize),
                    backingScale: window.backingScaleFactor
                )
            )
        }

        window.appearance = originalAppearance
        popover.appearance = originalPopoverAppearance
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()

        let metadata = PreviewRenderMetadata(
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            anchor: previewAnchorKind,
            statusItem: statusItemDiagnostics,
            appearances: appearanceRecords
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: directory.appendingPathComponent("popover-geometry.json"), options: .atomic)
    }

    private func finishPreviewSuccess(_ directory: URL) {
        print("Rendered native popover preview to \(directory.path)")
        fflush(stdout)
        Darwin.exit(EXIT_SUCCESS)
    }

    private func finishPreviewFailure(_ message: String) {
        let details = "\(statusItemDiagnostics) popoverShown=\(popover.isShown), hostingWindow=\(hostingController.view.window != nil)"
        FileHandle.standardError.write(Data("Preview render failed: \(message) (\(details))\n".utf8))
        fflush(stderr)
        Darwin.exit(EXIT_FAILURE)
    }

    private var statusItemDiagnostics: StatusItemDiagnostics {
        let button = statusItem.button
        let window = button?.window
        return StatusItemDiagnostics(
            visible: statusItem.isVisible,
            hasButton: button != nil,
            buttonIsHidden: button?.isHiddenOrHasHiddenAncestor ?? true,
            buttonBounds: PreviewRect(button?.bounds ?? .zero),
            hasWindow: window != nil,
            windowIsVisible: window?.isVisible ?? false,
            windowFrame: PreviewRect(window?.frame ?? .zero),
            windowOnActiveSpace: window?.isOnActiveSpace ?? false,
            applicationIsActive: NSApp.isActive
        )
    }
}

private enum PreviewAppearance: CaseIterable {
    case light
    case dark

    var descriptor: (String, NSAppearance.Name, String) {
        switch self {
        case .light: ("light", .aqua, "popover-light.png")
        case .dark: ("dark", .darkAqua, "popover-dark.png")
        }
    }
}

private struct PreviewRenderMetadata: Encodable {
    let operatingSystemVersion: String
    let anchor: String
    let statusItem: StatusItemDiagnostics
    let appearances: [PreviewAppearanceRecord]
}

private struct StatusItemDiagnostics: Encodable {
    let visible: Bool
    let hasButton: Bool
    let buttonIsHidden: Bool
    let buttonBounds: PreviewRect
    let hasWindow: Bool
    let windowIsVisible: Bool
    let windowFrame: PreviewRect
    let windowOnActiveSpace: Bool
    let applicationIsActive: Bool
}

private struct PreviewAppearanceRecord: Encodable {
    let appearance: String
    let image: String
    let contentSize: PreviewSize
    let windowFrame: PreviewRect
    let panelViewBounds: PreviewRect
    let windowContentBounds: PreviewRect
    let hostingViewBounds: PreviewRect
    let hostingSafeAreaInsets: PreviewInsets
    let preferredContentSize: PreviewSize
    let backingScale: CGFloat
}

private struct PreviewSize: Encodable {
    let width: CGFloat
    let height: CGFloat

    init(_ size: NSSize) {
        width = size.width
        height = size.height
    }
}

private struct PreviewRect: Encodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: NSRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

private struct PreviewInsets: Encodable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    init(_ insets: NSEdgeInsets) {
        top = insets.top
        left = insets.left
        bottom = insets.bottom
        right = insets.right
    }
}

private enum PreviewRenderError: LocalizedError {
    case popoverUnavailable
    case appearanceUnavailable(String)
    case snapshotUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .popoverUnavailable:
            "The native popover is not visible yet."
        case .appearanceUnavailable(let name):
            "The \(name) appearance is unavailable."
        case .snapshotUnavailable(let name):
            "The \(name) popover snapshot could not be created."
        }
    }
}
