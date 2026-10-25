import SwiftUI
import RunAnywaysCore
import RunAnywaysIPC

struct RunAnywaysPopover: View {
    @ObservedObject var model: AppModel

    private var sessionIsActive: Bool { model.hasActiveSession }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusCard
                .padding(.top, 14)

            if !model.isPreview && !model.hasRegisteredHelper && !model.hasPendingCleanup {
                helperSetup
                    .padding(.top, 12)
            } else {
                sessionControls
                    .padding(.top, 14)
            }

            cutoffControl
                .padding(.top, 14)

            if let error = model.commandError ?? model.helperStatus?.lastErrorMessage ?? model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                    .accessibilityLabel("Helper error: \(error)")
            }

            safetyNote
                .padding(.top, 14)

            footer
                .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 34, height: 34)
                .background(.indigo.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("RunAnyways")
                    .font(.system(size: 14, weight: .semibold))
                Text("Lid-closed session control")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if model.isPreview {
                StatusBadge(title: "Preview", color: .orange, symbol: "eye")
            } else if model.hasRestoreError {
                StatusBadge(title: "Needs attention", color: .orange, symbol: "exclamationmark.triangle.fill")
            } else if model.isConnectionUnavailable {
                StatusBadge(title: "Unavailable", color: .orange, symbol: "wifi.slash")
            } else if model.hasVerifiedProtection {
                StatusBadge(title: "Protected", color: .green, symbol: "checkmark.shield.fill")
            } else {
                StatusBadge(title: "Not active", color: .secondary, symbol: "moon.zzz")
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 26, height: 26)
                    .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.mainStatusTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.mainStatusDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if shouldShowCountdown {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.helperStatus?.session.remainingSeconds == nil
                         ? "∞"
                         : AppModel.formattedDuration(model.displayedRemainingSeconds ?? 0))
                        .font(.system(size: 29, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(model.helperStatus?.session.remainingSeconds == nil ? "unlimited" : "remaining")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let battery = model.batteryDescription {
                        Label(battery, systemImage: "battery.75percent")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                .padding(.leading, 36)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.helperStatus?.session.remainingSeconds == nil
                    ? "Unlimited session"
                    : "\(AppModel.formattedDuration(model.displayedRemainingSeconds ?? 0)) remaining")
            }
        }
        .padding(13)
        .background(statusColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(statusColor.opacity(0.12), lineWidth: 1)
        }
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.canRetryRestore {
                Button(action: model.stopSession) {
                    Label("Retry sleep restore", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)
                .accessibilityHint("Ask the helper to retry restoring normal sleep.")
                .disabled(!model.canStopSession)
            } else if model.canRetryConnection {
                VStack(spacing: 8) {
                    Button(action: model.retryConnection) {
                        Label("Retry connection", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isBusy)
                    .accessibilityHint("Fetch the helper's current status without changing the sleep setting.")

                    Button(action: model.repairHelper) {
                        Label("Repair helper", systemImage: "wrench.and.screwdriver")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!model.canRepairHelper)
                    .accessibilityHint("Repair the installed helper using this build's configured installation method.")
                }
            } else if sessionIsActive {
                HStack(spacing: 8) {
                    Button(action: model.extendSession) {
                        Label("Add 15 min", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(!model.canExtendSession)
                    .accessibilityHint("Adds 15 minutes to the active timed session.")

                    Button(action: model.stopSession) {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .tint(.red)
                    .disabled(!model.canStopSession)
                    .accessibilityHint("Restores normal sleep and ends this session.")
                }
            } else {
                Picker("Session length", selection: $model.selectedLength) {
                    ForEach(SessionLengthChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.isBusy)
                .accessibilityHint("Choose a countdown duration or an unlimited session.")

                if model.selectedLength == .custom {
                    HStack(spacing: 6) {
                        Text("Custom duration")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("Minutes", value: $model.customMinutes, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                            .multilineTextAlignment(.trailing)
                            .disabled(model.isBusy)
                            .accessibilityLabel("Custom duration in minutes")
                        Text("min")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: model.startSession) {
                    Label(startButtonTitle, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canStartSession)
                .accessibilityHint("Arms the helper. The countdown begins when the lid closes.")
            }
        }
    }

    private var helperSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: model.needsHelperApproval ? "gearshape.2.fill" : "lock.shield")
                    .foregroundStyle(.secondary)
                Text(model.helperSetupDescription)
                    .font(.system(size: 11, weight: .medium))
            }

            if model.needsHelperApproval {
                Button(action: model.openApprovalSettings) {
                    Label("Open System Settings", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .accessibilityHint("Approve the RunAnyways background helper in Login Items.")
            } else if model.helperSetupAllowsRegistration {
                Button(action: model.registerHelper) {
                    Label("Enable background helper", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!model.canRegisterHelper)
                .accessibilityHint("Register the helper. macOS may ask you to approve it in System Settings.")
            } else if model.isLocalDaemonBackend && model.canRepairHelper {
                Button(action: model.repairHelper) {
                    Label(model.localHelperActionTitle, systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isBusy)
                .accessibilityHint("Use the administrator-authorized local helper installer.")
            } else if !model.helperResourcesUnavailable {
                Button(action: model.openApprovalSettings) {
                    Label("Review helper settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            if let message = model.serviceActionMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.helperSetupMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
    }

    private var cutoffControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Battery cutoff")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(model.cutoffPercentage)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(model.cutoffPercentage) },
                    set: { model.cutoffPercentage = Int($0.rounded()) }
                ),
                in: Double(Session.minimumCutoffPercentage)...Double(Session.maximumCutoffPercentage),
                step: 5
            )
            .disabled(sessionIsActive || model.isPreview || model.isBusy)
            .accessibilityLabel("Battery cutoff percentage")
            .accessibilityValue("\(model.cutoffPercentage) percent")
            Text(sessionIsActive ? "Applies to the next session." : "Session stops at this level on battery.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var safetyNote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Ventilated desk · stop before packing", systemImage: "wind")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            DisclosureGroup("About lid-close behavior") {
                Text("Sleep stays disabled while a session is armed or paused. The built-in display still sleeps when you close the lid, and the countdown runs only while it is shut. Normal sleep is restored when you stop or the session ends.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
            }
            .font(.system(size: 10, weight: .medium))
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.hasVerifiedProtection ? Color.green : Color.secondary.opacity(0.55))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(model.isPreview ? "Preview only · no helper access" : model.helperSetupDescription)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let notice = model.thermalNotice {
                Text(notice.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(notice.isWarning ? .orange : .secondary)
            }
            if !model.isPreview {
                Menu {
                    Button("Open Login Items…", systemImage: "gearshape") {
                        model.openApprovalSettings()
                    }
                    .disabled(model.isBusy)
                    Button("Disable background helper", systemImage: "xmark.circle", role: .destructive) {
                        model.unregisterHelper()
                    }
                    .disabled(!model.canDisableHelper)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .disabled(model.isBusy)
                .help("Helper settings")
                .accessibilityLabel("Helper settings")

                Button(action: model.quit) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Quit RunAnyways and restore normal sleep")
                .disabled(!model.canQuit)
                .help("Quit RunAnyways")
            }
        }
    }

    private var shouldShowCountdown: Bool {
        model.hasVerifiedProtection && model.helperStatus?.session.isActive == true
    }

    private var startButtonTitle: String {
        model.selectedLength == .unlimited ? "Start unlimited session" : "Start session"
    }

    private var statusSymbol: String {
        if model.hasRestoreError { return "exclamationmark.triangle.fill" }
        if model.isConnectionUnavailable { return "wifi.slash" }
        guard model.hasVerifiedProtection, let session = model.helperStatus?.session else {
            return model.isPreview ? "eye" : "moon.zzz"
        }
        switch session.state {
        case .running: return "bolt.fill"
        case .paused: return "pause.fill"
        case .armed: return "clock.badge.checkmark"
        case .ended:
            return session.endReason == .expired ? "checkmark.circle.fill" : "moon.zzz"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "moon.zzz"
        }
    }

    private var statusColor: Color {
        if model.isPreview { return .orange }
        if model.hasRestoreError || model.isConnectionUnavailable || model.mainStatusTitle == "Protection not verified" { return .orange }
        return model.hasVerifiedProtection ? .green : .secondary
    }
}

private struct StatusBadge: View {
    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}
