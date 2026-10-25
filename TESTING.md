# Verification and hardware checklist

## Automated checks

Run `swift test` on macOS, then `scripts/build-app.sh` to compile and sign a local
application bundle. Tests use a simulated clock and mock power controller. They
must never install/register the daemon, invoke mutating `pmset` commands, or alter
host sleep settings. A successful build does not prove closed-lid operation.

The development target is an M4 MacBook Air, macOS 27. The deployment target is
macOS 13 or newer on Apple Silicon and Intel. Compatibility beyond the tested
machine remains unverified until the following checks are performed there.

## Initial verification — 2026-10-25

Verified locally on the M4/macOS 27 development machine:

- `swift test --scratch-path /tmp/runanyways-final-tests`: 32 tests passed
  (23 helper coordinator tests and 9 session tests), without privileged operations.
- `scripts/build-app.sh --release --universal`: successful Apple Silicon and Intel
  release compilation; both executables contain arm64 and x86_64 slices.
- Strict code-signature verification for every architecture, plist validation,
  shell syntax checks, and `git diff --check`: passed.

The daemon was not installed or registered. Real lid-close, display-off, battery,
power-source transition, and recovery behavior have not yet been verified on
physical hardware. These are acceptance tests, not outcomes of the unit tests.

## First-run setup fix — 2026-10-25

The installed app had valid helper resources but no Service Management record.
Its `notFound` status incorrectly hid registration and only opened Settings. The
setup policy now offers registration when resources pass validation, for both
`notFound` and `notRegistered`, and distinguishes missing resources from pending
approval.

- Full suite: 38 tests passed (23 helper, 9 session, 6 setup policy).
- Universal release compilation and strict signature validation passed.
- `--helper-status` reported `notFound` with a present helper, valid plist, and
  valid app signature without attempting registration.
- Conflicting status/register and preview/register flags returned exit code 2
  with `registrationAttempted: false`.

The corrected app must be reinstalled by the user because the existing app is
root-owned and administrator authentication is required. Real registration and
approval remain to be confirmed after that update. No background-service reset,
privileged helper registration, or sleep-setting mutation was performed.

## Native popover verification — 2026-10-25

The SwiftUI MenuBarExtra host left white top/bottom bands on macOS 27, even after
applying a window background. The app now owns an NSStatusItem and NSPopover with
a transparent SwiftUI content root and one native surface.

- The packaged Universal release was launched through LaunchServices with
  `--preview --render-preview /tmp/runanyways-native-packaged-final`.
- Geometry reports `anchor: statusItem`, a visible 29 × 26 pt menu button, exact
  340 × 378 pt hosted content, and zero hosting safe-area insets. The native frame
  measures 366 × 404 pt including its shadow/arrow envelope.
- Full native-frame PNGs were rendered and visually inspected in light and dark
  appearance: rounded surface and arrow, no white bands or nested material layer.
- An isolated native sizing probe expanded and collapsed 340 × 128 → 340 × 268 →
  340 × 128 pt using preferred-content sizing.
- The full 38-test suite passed. Both release architectures report minimum macOS
  13.0 / SDK 27.0, and strict all-architecture signature verification passed.
- Preview rendering requires `--preview` and rejects helper command combinations
  before dispatch. No helper registration or keep-awake session was invoked.

Reproduce the native preview with:

```sh
open -n dist/RunAnyways.app --args --preview --render-preview /tmp/runanyways-native-preview
```

The process writes light/dark PNGs and `popover-geometry.json`, then exits. A raw
command-line launch may use an owned preview anchor window; geometry records that
fallback explicitly. Require `anchor: statusItem` when checking actual menu-bar
anchoring. Preview mode keeps session controls disabled.

## Local helper launch fix — 2026-10-25

The installed ad-hoc Service Management job was loaded but had no PID and exited
with `78: EX_CONFIG`. Host logs recorded an AMFI launch-constraint violation for
an ad-hoc/unknown-chain signature; the helper never reached its entry point.
On-disk signature validity and `SMAppService.status == enabled` did not prove
that macOS could launch it.

Local builds now use an administrator-installed LaunchDaemon and a protected
executable in `/Library/PrivilegedHelperTools`. Signed distribution builds retain
Service Management. Migration unregisters only RunAnyways' old managed service
from the installed app's user context. A recovery journal blocks replacement or
removal, and the installer requires a real authenticated status reply at the end.

- Full suite: 51 tests passed (23 coordinator, 8 installation, 11 setup/recovery,
  9 session). Tests do not install daemons or change host power settings.
- Universal release compilation, strict all-architecture signature checks, both
  daemon plists, shell syntax, and `git diff --check` passed.
- Conflicting helper CLI commands returned exit code 2 with registration and
  unregistration both unattempted. Running the helper as a normal user returned
  its expected root-only error before creating any session or journal.
- Initial connection failure offers a read-only retry; pending restoration or a
  previously active session retains cleanup requirements. These are separate
  policy cases covered by regression tests.
- Harmless descriptor probes confirmed that the administrator launcher rejects
  user-owned scripts and that Bash continues reading the pinned script when its
  source pathname is replaced or its descriptor is reused later.
- The final packaged Universal app rendered both native light/dark previews
  through LaunchServices and exited. Geometry remained `anchor: statusItem`,
  340 × 378 pt content, 366 × 404 pt full frame, and zero hosting insets; visual
  inspection found no extra bands. AppKit startup stays synchronous, while
  asynchronous helper CLI commands pump the main run loop separately.

Administrator-authenticated installation and a successful installed
`--probe-helper` response still require verification on the host. Physical
lid-close behavior remains subject to the acceptance matrix below.

## Physical acceptance test

Use a hard, ventilated surface, save your work, and start with sufficient battery.
Use `scripts/install-local.sh` to install the protected local build in
`/Applications/RunAnyways.app` and install its local helper, then open it. Signed
distributions instead enable the helper through the in-app setup and macOS
background-item approval. Keep other
sleep-management utilities stopped during the test.

| Case | Expected result |
| --- | --- |
| First launch, helper unavailable | Setup is visible; the app does not claim protection. |
| Activate a timed session with lid open | Ready/armed; remaining time stays constant. |
| Close lid, no external monitor, on battery | Background job continues; timer consumes time; built-in screen is off. |
| Open lid after a measured interval | Paused; elapsed closed-lid time was subtracted once. |
| Wait with lid open, then close again | Remaining time does not reset; countdown resumes. |
| Extend an active or paused session | Remaining time increases by the selected amount. |
| Unlimited session, multiple lid transitions | No countdown; stop and battery protections still apply. |
| Timer expires while closed | Override is restored; normal macOS sleep policy applies. |
| Unplug/plug charger while closed | Session continues and protection is verified again. |
| Battery reaches configured cutoff on battery | Session ends; normal sleep policy is restored. |
| Stop, quit, or force-quit GUI | Helper restores the override; lease also bounds connection failure. |
| Kill/restart helper during a session | Journal recovery restores sleep; the app reports lost protection. |
| Deny/revoke background permission | Setup/error state is shown; no false active status. |
| Another utility already disabled sleep | Session start is refused without overwriting that utility's state. |
| Serious/critical thermal pressure (simulated in unit tests) | Session ends and restoration is requested. |
| Reboot after an interrupted session | Recovery clears an owned override; no session restarts automatically. |
| Stop session before transport | App shows no active protection. |

Do not deliberately overheat or drain a device to verify the thermal/battery paths.
Use deterministic unit tests for those conditions and normal operation for the
physical checks.

Before installing an updated build, stop the session, disable the helper from the
app menu, and quit the installed app. Do not replace a running daemon's app bundle.

## Checking that a background process kept running

For a short test, run this in Terminal before closing the lid:

```sh
while true; do
  date -u '+%Y-%m-%dT%H:%M:%SZ' >> /tmp/runanyways-heartbeat.log
  sleep 2
done
```

Inspect `/tmp/runanyways-heartbeat.log` after opening the lid. There should be no
sleep-sized gaps during the protected interval. Stop the test with Control-C.
Also test a real Codex or Claude Code job: keeping the Mac awake cannot resolve
network disconnections, permission prompts, or failures inside the agent itself.

Read-only diagnostics:

```sh
pmset -g
pmset -g assertions
pmset -g log
```

## Emergency recovery

Only if RunAnyways owned the sleep override and normal stop/restart recovery has
failed, restore it manually in Terminal:

```sh
sudo /usr/bin/pmset -a disablesleep 0
```

This command clears the system-wide override. It can affect another sleep utility,
so verify ownership first. Do not reset all power settings or disable system
security features.
