# CLAUDE.md

## Project Snapshot

**Lustre** — native iOS app for capturing, viewing, and (eventually) training 3D
Gaussian Splats. The viewing experience should feel like walking through a place,
not orbiting a model.

- Swift + SwiftUI. Project at `Lustre.xcodeproj` (repo root), scheme `Lustre`.
- **Minimum iOS 18.0.** Forced by MetalSplatter, which has no version that runs
  on iOS 16. Don't use APIs newer than 18.0 without flagging it.
- Metal + MetalSplatter (SPM) for rendering; ARKit for 6DoF pose; AVFoundation
  for capture; CoreMotion for motion analysis.
- Bundle ID `com.alecborer.Lustre`. Apple Silicon only — MetalSplatter
  `fatalError`s on x86_64. Development machine is a MacBook Air M4 16GB.
- Reference apps in the same space: Scaniverse, Polycam, RadianceKit (macOS
  only), Gaussian SplatKing.

**`ROADMAP.md` holds the per-feature plan and build order; `STATUS.md` holds
live status.** Read the relevant ROADMAP section before starting a feature.
Status is not duplicated here, because a second copy drifts.

## Architecture Constraints

```
Lustre/
├── App/         # LustreApp (@main), ContentView (nav root)
├── Viewer/      # Rendering/ AR/ Simulator/ UI/ + INTEGRATION.md
├── Components/  # VirtualJoystick
├── Core/        # Shared math
└── Services/    # SplatIO wrapper, SampleSplatScene
```

- **No cross-feature imports.** A feature never imports from another feature
  folder; shared code moves to `Core` / `Services` / `Components`.
- **Preserve the `PoseProvider` seam.** It's what lets the Viewer run without
  hardware: `ARKitPoseProvider` on device, `SimulatedPoseProvider` in the
  simulator. Don't collapse it into either implementation.
- **iPhone only, monoscopic world-tracked AR (like Apple's Measure app), no
  visionOS or stereo rendering.** Single-view rendering (`maxViewCount: 1`), no
  side-by-side, no iPad-specific layouts (a universal binary is fine).
- **No cloud dependency** in core capture / view / library paths.
- **Storage:** `Documents/` for captured and saved splats (user-visible in
  Files); `Caches/` for imports, thumbnails, anything regenerable.
- Prefer value types and `@Observable` over ad-hoc singletons. The project sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are MainActor-isolated
  unless marked `nonisolated` — relevant any time work must leave the main
  thread.
- **Don't start Training.** It's research, not a commitment, and it waits until
  Capture is mature.
- Out of scope, don't build toward: cloud sync, sharing between Lustre users,
  AR Quick Look for non-Lustre sharing.

## Session Flow

Read `STATUS.md` at the start of every session, and update it before finishing
any significant chunk of work.

Headless compile check:

```
xcodebuild -project Lustre.xcodeproj -scheme Lustre \
           -destination 'platform=iOS Simulator,OS=latest,name=iPhone 17' build
```

`OS=latest` is required: more than one installed runtime has an "iPhone 17",
and a name-only destination is ambiguous. Confirm the simulator exists first:
`xcrun simctl list devices available`.

**ARKit, AVFoundation capture, and CoreMotion do not work in the iOS
Simulator.** A green simulator build does NOT verify them. When asked whether a
device-only feature works, compile it, then say it needs on-device testing.
Don't report it as working.

Subagents in `.claude/agents/`: **architect** plans non-trivial work before any
code, **implementer** writes code and its tests in one pass, **code-reviewer**
reviews after changes land, **test-runner** executes suites in isolation.
architect and code-reviewer have no `Write` or `Edit` tool, so they report
instead of changing code. They do have `Bash`, which is not an airtight
sandbox — don't ask them to apply a fix, hand it to implementer.

Done means: the app builds and runs; no new cross-feature imports; the
`PoseProvider` seam intact; device-only work explicitly flagged as needing
hardware rather than claimed as verified.
