# RunAnyways

Keep the work running. Close the lid.

A minimal, open-source macOS menu bar app for giving Codex, Claude Code, and other
background jobs more time while your MacBook is closed. English interface, native
SwiftUI, no cloud account, no third-party dependencies.

**Development preview:** the source and automated checks are available, but real
closed-lid behavior must be verified on each supported hardware/OS combination.
macOS can still interrupt work, and this app cannot guarantee job completion.

## How a session works

1. Choose 15, 30, 60, or 120 minutes, a custom duration, or unlimited.
2. Activate the session. The app waits for the lid to close.
3. Close your MacBook. Only time spent closed counts down.
4. Open it again to pause; close it again to resume the remaining time.
5. Extend or stop a session from the menu bar. After expiry, normal sleep policy
   applies again.

Designed to work on battery or external power without an external monitor. Changing
power source does not intentionally stop the session. The default battery cutoff
is 20%, configurable from 5–50%. Serious or critical thermal pressure ends a session.
Display sleep is allowed; RunAnyways does not change saved brightness settings or
force a screen lock.

**Stop the session before putting the MacBook in a bag.** Closed-lid work still
uses battery and produces heat. A thermal status check cannot detect every unsafe
transport condition.

## Build and run

Requires macOS 13+, Apple Silicon or Intel, and Xcode command line tools with Swift
5.9 or newer. The development machine is an M4 MacBook Air running macOS 27; other
hardware and OS versions need physical verification.

```sh
swift test
./scripts/build-app.sh
```

The resulting app is at `dist/RunAnyways.app`. Install the local build using:

```sh
./scripts/install-local.sh
open /Applications/RunAnyways.app
```

The installer requests administrator access to install the protected app at
`/Applications/RunAnyways.app`, the local helper executable in
`/Library/PrivilegedHelperTools`, and its LaunchDaemon in `/Library/LaunchDaemons`.
Local ad-hoc builds use this conventional administrator-installed service because
macOS can reject them under Service Management's launch constraints. The installer
migrates RunAnyways' old managed registration; it does not reset other background
items or change system security settings. Dragging a development build into
Applications does not perform this setup.

The app also offers local helper installation or repair with administrator
authentication. Until an authenticated helper replies, the app does not report
active protection. **Retry connection** requests status only; sleep restoration is
offered for an actual pending restoration or a previously active session.

For an Apple-signed, notarized distribution, helper registration instead uses
`SMAppService`: choose **Enable background helper**, then approve it through
**Open System Settings** if requested. The service is not added with the `+` button
for ordinary login applications. A first-use `notFound` status alone does not mean
the embedded helper is missing.

For read-only configuration and authenticated connection diagnostics, run:

```sh
/Applications/RunAnyways.app/Contents/MacOS/RunAnyways --helper-status
/Applications/RunAnyways.app/Contents/MacOS/RunAnyways --probe-helper
```

These return JSON and never start or stop a keep-awake session. A configured or
loaded service is distinct from a running process and a successful XPC reply.
The explicit `--unregister-managed-helper` command is used by the installer to
remove RunAnyways' old Service Management registration in the user context.

Build an optimized version or a universal app:

```sh
./scripts/build-app.sh --release
./scripts/build-app.sh --release --universal
```

Opening `Package.swift` in Xcode is useful for editing and tests. Launch the built
app bundle for actual use: `swift run` does not create the required helper and
resource bundle layout. The build script defaults to local ad-hoc signing. Both IPC peers
validate the protected installed app and require the actual companion code
signature. A local build is not an Apple-notarized public release.

For public distribution, set `CODE_SIGN_IDENTITY` to your Developer ID signing
identity and `DEVELOPMENT_TEAM` to its ten-character team ID, then notarize and
staple the application using your own Apple Developer account. The build selects
Service Management only for the configured signing team. Never commit signing
certificates or notarization credentials. The repository does not include a signing identity or publish a
GitHub release automatically.

## Why a privileged helper?

Apple's public idle-sleep assertion permits sleep on lid close. Keeping a MacBook
running while closed therefore needs a separate sleep override, rather than just
running `caffeinate`.

RunAnyways uses a small root LaunchDaemon with a fixed session API. Local builds
install it with administrator authorization; signed distributions register it
through `SMAppService`. The helper owns session timing, checks power state, and accepts
no arbitrary commands, executable paths, or shell scripts from the app. It applies
the system-wide `pmset disablesleep` override and restores its owned state when a
session ends. Another utility's pre-existing override blocks session start.

The override is enabled while **ready or paused** too, so the next lid closure can
be intercepted. The countdown still only consumes closed-lid time. During that
armed interval, other system sleep actions can also be affected. Stop the session
to fully return sleep control to macOS.

A short heartbeat lease, connection cleanup, and a recovery journal are intended
to restore normal sleep after app/helper failures. Restoration failures must be
visible and retried. This mechanism is not a stable Apple guarantee for closed-lid
operation; OS updates can change it. It is not a substitute for running critical
jobs on a server.

Technical background: [Apple idle-sleep assertion documentation](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep),
[Apple Service Management](https://developer.apple.com/documentation/servicemanagement/smappservice),
[Apple's pmset source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m).

## Testing and contributing

See [TESTING.md](TESTING.md) for deterministic tests, physical acceptance checks,
and recovery diagnostics. Automated tests never install the privileged service or
alter host power settings. Architecture and contribution guidance are in
[ARCHITECTURE.md](ARCHITECTURE.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

To uninstall, stop the session, choose **Disable helper** from the app's menu,
quit, then remove `/Applications/RunAnyways.app`. Disable waits for normal sleep
restoration before unregistering the daemon. See [TESTING.md](TESTING.md) for
manual recovery if the helper cannot restore its state.

RunAnyways is licensed under the [MIT License](LICENSE).
