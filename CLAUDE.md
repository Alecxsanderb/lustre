# CLAUDE.md

## Project

**Lustre** — a native iOS app for capturing, viewing, and (eventually) training
3D Gaussian Splats. Target users are hobbyists and prosumers who want better
captures than the stock camera gives them, and a viewing experience that feels
like walking through a place rather than orbiting a model.

The full roadmap — per-feature scope, folder org, build order, and current
status — lives in **`ROADMAP.md`**. Read the relevant section there before
starting a feature. This file is the quick-reference contract; `ROADMAP.md` is
the detailed plan and the live status snapshot.

## Design principles

- Beginner-friendly defaults with expert escape hatches.
- Built for Apple Silicon — **no cloud dependency for core features**.
- A native iOS experience, not a port of desktop tooling.

## Stack

- Swift + SwiftUI
- **Minimum iOS 16.0** — do not use APIs newer than 16.0 without flagging it.
- Metal + **MetalSplatter** (via SPM) for splat rendering
- ARKit (6DoF pose), AVFoundation (capture), CoreMotion (motion analysis)
- Xcode project; develops on Apple Silicon (M4, 16GB)

## Architecture — feature folders

The project groups by feature. Each top-level folder is one testable,
independently buildable area. Folders are visual groupings only.

**Current state:** all code lives flat in `Lustre/Lustre/`. The intended
feature-folder layout (once reorganized):

```
Lustre/
├── App/         # SplatWalkApp (@main), root navigation
├── Viewer/      # SplatRenderer, ARSplatView, PoseProvider, SplatSceneState,
│                #   ControlsOverlay, INTEGRATION.md  ← scaffold complete
├── Components/  # VirtualJoystick, SimulatorControlsOverlay
├── Core/        # Shared math (matrix helpers, perspectiveProjection)
└── Services/    # SplatIO wrapper over MetalSplatter (not yet created)
```

**Cross-feature rule:** a feature never imports from another feature folder.
Shared code goes in `Core`, `Services`, or `Components`, and features import
from there. This keeps each feature self-contained and testable in isolation.

**The testing seam:** `PoseProvider` is the abstraction that lets the Viewer
run without a device — `ARKitPoseProvider` on device, `SimulatedPoseProvider`
(dual joysticks) in the simulator. Preserve this seam.

## Conventions

- SwiftUI-first; prefer value types and `@Observable`/`ObservableObject` over
  ad-hoc singletons.
- Preferences via `@AppStorage` (see `Settings/AppPreferences`). Features
  observe only their own slice; don't front-load settings.
- **Storage:** `Documents/` for captured/saved splats (user-visible in the
  Files app); `Caches/` for imports, thumbnails, and anything regenerable.
- Splat formats: PLY / SPZ / `.splat`. MetalSplatter handles most format I/O;
  `Services/SplatIO` is a thin app-side wrapper over it.

## Hard rules

- **Don't break the Viewer scaffold** or the `PoseProvider` abstraction — the
  architecture there is complete and is the next integration target, not a
  rewrite candidate.
- **No cross-feature imports.** Shared code moves to Core/Services/Components.
- **No cloud dependency** in core capture/view/library paths.
- **Stay within the out-of-scope list** (below). Don't build toward them.
- **Don't start Training.** It's research; it doesn't begin until Capture is
  mature.
- Every step from the build order should remain shippable to TestFlight — keep
  `main` buildable.

## Simulator vs. device — important

ARKit, the camera (AVFoundation), and CoreMotion **do not work in the iOS
Simulator**. That means:

- Viewer logic is testable in the simulator via `SimulatedPoseProvider`.
- Capture, AR pose, and motion coaching require a **physical device** — a
  successful `xcodebuild` for the simulator does NOT verify those features.
- When asked to "verify it works" for a device-only feature, build for the
  simulator to confirm it compiles, then tell me it needs on-device testing
  rather than claiming it works.

## Build / test / run

- **Open:** `Lustre/Lustre/Lustre.xcodeproj`; build/run with the `Lustre` scheme.
- **Simulator (Viewer logic):** uses `SimulatedPoseProvider` — dual joysticks
  in the app control the camera. ARKit/camera do not work in the simulator.
- **Headless compile check:**
  ```
  xcodebuild -project Lustre/Lustre/Lustre.xcodeproj \
             -scheme Lustre \
             -destination 'platform=iOS Simulator,name=iPhone 16' \
             build
  ```
- **Reload after edits:** re-run from Xcode (`⌘R`); no add-on reload step needed.
- MetalSplatter integration steps are in `Lustre/Lustre/INTEGRATION.md`.

## Out of scope (do not build toward these)

- Cloud sync between devices
- Social features / sharing splats with other Lustre users
- visionOS (Apple Vision Pro) version — related, but its own project
- iPad-specific UI — a universal binary is fine, no custom layouts
- AR Quick Look integration for non-Lustre sharing

## Current state (mirror of ROADMAP.md status — keep in sync)

- Viewer scaffold complete; **MetalSplatter not yet integrated** — this is the
  immediate next step.
- All other features planned, not started.
- Repo created, public, MIT licensed. Bundle ID / App Store name reservation
  still TBD.

## Definition of "done" for any change

- The app still builds and runs; the Viewer scaffold still works.
- No new cross-feature imports introduced.
- Device-only features are flagged for manual on-device testing rather than
  reported as verified from a simulator build.
