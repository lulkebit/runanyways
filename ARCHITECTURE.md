# RunAnyways architecture

Native SwiftUI menu bar application, macOS 13+, Apple Silicon and Intel, English UI.
Source-only Swift package plus an app bundle build script; no external dependencies.

## Menu bar presentation

An AppKit application delegate strongly owns the model and a native NSStatusItem /
NSPopover controller. SwiftUI renders the contents through NSHostingController;
the native popover supplies the only background surface. Its preferred-content
sizing tracks disclosure and status changes without extra top/bottom host margins.
Combine updates the status item after model changes. Closing the transient popover
does not end the model's timers or helper connection.

The build script uses SwiftPM's native backend with the current SDK explicitly.
On the development Swift 6.4 toolchain, the default backend incorrectly recorded
SDK 13.0 alongside deployment target 13.0; the native backend records SDK 27.0 and
retains the macOS 13 deployment target. Its deprecation warning is a known tooling
limitation to revisit when the default backend fixes SDK metadata.

## Session contract

The root helper is authoritative, never the menu bar timer. A pure `Session` value in
RunAnywaysCore receives explicit monotonic timestamps. Its states are idle, armed,
running (lid closed), paused (lid reopened), ended, and failed. Starting a session
while the lid is open arms it. Closing starts/resumes time consumption; opening
pauses it without resetting the remaining time. Unlimited sessions do not count
down. Extend adds a bounded positive duration. Battery sessions stop at a default
20% cutoff, configurable 5–50%. AC removal does not end a session. Thermal serious
or critical ends protection; OS emergency behavior must never intentionally be
overridden. Session expiration restores normal sleep policy, not forced sleep.

## Power and lifetime

Closed-lid operation needs more than idle-sleep assertions. Use a narrow root
LaunchDaemon managed by SMAppService. The helper may invoke only hardcoded pmset
commands through Process (no shell, no caller-supplied paths/arguments). Capture and
verify SleepDisabled before acquisition. Refuse to take ownership if another tool
already disabled sleep. Journal ownership before mutation in a root-only location;
recover it at daemon restart. Restore on stop, timer expiry, low battery, thermal
pressure, connection invalidation, signals, and stale heartbeat. Do not clear a
journal until restoration succeeds. Verify applied state and retry restoration.
Keep a short lease even for unlimited sessions. Prevent the app claiming active
protection until helper acknowledgment and verified power state.

The sleep override must be enabled while armed/paused, before the next lid close;
the countdown only consumes closed-lid time. Do not assert display wakefulness.
Ensure the built-in display sleeps on lid closure and do not change saved brightness.
Explain this global sleep override in README/setup. No agent process inspection.

## IPC boundary

NSXPC, a fixed Mach service and Objective-C protocol returning JSON Data snapshots
and error strings. Methods: fetchStatus, startSession(seconds: unlimited: cutoff:),
extendSession(seconds:), stopSession, heartbeat. Exactly one connection owns a
session; other clients cannot mutate it or prolong its lease. Validate all scalar
inputs in the helper. Authenticate both peers using code signing requirements;
never trust just bundle identifier or PID. Signed distributions pin a signing team;
local ad-hoc builds must use an explicitly documented, constrained development
trust path. No arbitrary execution API. The GUI handles setup approvals and helper
unavailability honestly. Timer and heartbeat continue with the popover closed.

## Verification

Meaningful deterministic tests for countdown/pause/resume, unlimited/extend,
validation/cutoffs, helper lease/ownership/restoration failures. Build app and helper,
inspect resulting bundle/plists/signing. Physical lid-close, battery/AC transitions,
display behavior and root service approval require a manual hardware test matrix.
Do not run privileged mutations or install/register services as part of tests.
