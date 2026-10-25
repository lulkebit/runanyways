# Contributing

RunAnyways is a small native macOS utility. Keep its scope focused on timed,
closed-lid background work. The application does not inspect agent conversations,
send telemetry, or require a network account.

Use Xcode's command line tools with Swift 5.9 or later on macOS 13+. There are no
third-party package dependencies. Open `Package.swift` in Xcode, or use `swift test`.
Build the actual application bundle using `scripts/build-app.sh`; `swift run` does
not provide the bundle layout required by Service Management.

Before submitting a change:

- Run `swift test` and build the application bundle.
- Add deterministic tests when changing session timing, ownership, or restoration.
- Use injected power drivers in tests. Never run privileged power mutations in CI.
- Use the hardware checklist in [TESTING.md](TESTING.md) for power-related changes.
- Describe which hardware and OS versions were actually tested.

Never widen the helper into a generic privileged command runner. It accepts a
fixed set of session operations, authenticates its caller, and restores only the
sleep override it owns. Changes to that boundary need careful manual review.

See [ARCHITECTURE.md](ARCHITECTURE.md) and [AGENTS.md](AGENTS.md).
