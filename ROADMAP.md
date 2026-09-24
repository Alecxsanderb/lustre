# Lustre — Project Roadmap

A planning document for the app's feature structure, scope per feature, and
suggested build order. Also serves as orienting context for fresh
chats / future you.

---

## What this is

Lustre is an iOS app for capturing, viewing, and (eventually) training
Gaussian splats. Target users are hobbyists and prosumers who want better
captures than the stock camera app gives them, and a viewing experience
that feels more like walking through a place than panning around a model.

Design principles:
- Beginner-friendly defaults with expert escape hatches
- Built for Apple Silicon — no cloud dependency for core features
- Native iOS experience, not a port of desktop tooling

---

## Folder organization

Folders are visual groupings only — Xcode and Swift don't care about
disk layout. The project groups by feature; each top-level folder is one
testable, independently buildable area. Shared code lives in a few
infrastructure folders alongside the features.

```
Lustre/
├── App/              # Entry point, root navigation
├── Home/             # Landing screen and navigation hub
├── Library/          # Splat collection management
├── Viewer/           # AR/walk-through experience
├── Capture/          # Guided capture flow
├── Training/         # On-device splat training (long-term)
├── Settings/         # App preferences
├── Components/       # Reusable UI (joystick, splat cards, etc.)
├── Core/             # Shared types and math
└── Services/         # File I/O, storage, format handling
```

When a feature borrows from another, it imports from Core/Services/Components
rather than reaching across feature folders. This keeps each feature
self-contained enough that it can be developed and tested in isolation.

---

## Features

### App

**Purpose:** Top-level entry, navigation root, environment setup.

**Scope:** `LustreApp.swift` (@main), root `ContentView` that hosts
the navigation stack, any app-wide environment objects.

**Status:** Skeleton in place from the scaffold; will be rewritten when
Home becomes the root view.

---

### Home

**Purpose:** First thing users see. Get them to their content fast.

**Scope:**
- Recently viewed splats (horizontal scroll, ~3-5 items)
- Prominent "Capture new" CTA
- "Browse library" entry
- Quick access to settings

**Key components:** `HomeView`, `RecentSplatsRow`, `CaptureCTAButton`

**Dependencies:** Library (read-only), navigation links to Viewer / Capture / Settings

**Status:** Planned

---

### Library

**Purpose:** Where splats live after capture or import. The "Photos app"
equivalent for splats.

**Scope:**
- Grid view with thumbnails
- Metadata: name, capture date, file size, source (captured vs imported)
- Import from Files (PLY, SPZ, .splat; SOG recognized but not yet decodable)
- Delete, rename, share (export as PLY/SPZ via share sheet)
- Sort by date, name, size

**Key components:** `LibraryView`, `SplatGridCell`, `SplatDetailSheet`,
`ThumbnailGenerator` (service)

**Storage strategy:** Documents directory for captured/saved splats
(user-visible via Files app); Caches directory for imports and previews
that can be regenerated.

**Dependencies:** Core (Splat model), Services (file I/O, sharing)

**Open questions:**
- Thumbnails: render on first view, cache to disk? Background queue?
- Folders/tags/collections — probably no for v1.

**Status:** Planned

---

### Viewer

**Purpose:** Walk through a splat by physically moving the phone, or via
on-screen joysticks in the simulator. The scaffold is already built.

**Current state:** Built and rendering. MetalSplatter is wired in and the
sample scene renders in the simulator. The AR path compiles but has never
executed — see the caveat below.

**Sub-structure:**
```
Viewer/
├── AR/              # ARKitPoseProvider
├── Simulator/       # SimulatedPoseProvider, SimulatorControlsOverlay
├── Rendering/       # SplatRenderer, SplatRenderView, PoseProvider, SplatSceneState,
│                    #   CameraFrameSource, PassthroughCompositor, Passthrough.metal
├── UI/              # ViewerScreen, ViewerModel, ControlMenu, ViewerUIState, SplatGestures
└── INTEGRATION.md
```

No `ARSplatView`: `ViewerScreen` composes the render view with whichever pose
provider is active, so an AR-specific view had nothing left to do.

**Scope (current):**
- 6DoF AR pose drives the virtual camera through the splat
- Simulator mode with dual joysticks for AR-less testing
- Tap-to-place on a detected surface on load, anchored so ARKit's corrections
  keep it put; re-place from the menu
- Manual placement: log-scale sizing, yaw (plus pitch/roll), camera-relative
  translation, all pivot-bracketed so they act in place
- Position indicators (axis bars, drop line, surface outlines), toggleable —
  and surface detection stops when they're off
- Measuring notches on the axis bars at real-world intervals, metric or
  imperial, with the menu naming the interval
- Occlusion against detected planes (off by default, needs the camera
  background)
- Collapsible control menu; one-finger dolly plus two-finger gestures, with a
  global on/off and an optional lock to one axis at a time
- Spatial chunking with frustum culling, plus a load-time splat budget
- Black or camera-passthrough background
- File picker entry (will be replaced by Library integration)

**Scope (future, in rough priority):**
- ~~Wire in MetalSplatter~~ — done
- ~~Manual placement (scale / rotate / translate) + control menu + multi-touch~~ — done
- ~~Passthrough mode (splat over camera feed)~~ — built; compositor verified in
  the simulator against a test pattern, camera plumbing needs a device
- Library integration (load from Library instead of file picker)
- **SOG and other compressed containers.** MetalSplatter has no reader for them
  at any version, so this needs a decoder written from scratch (WebP planes plus
  a container unzip). Currently recognized and rejected with a clear message.
- ~~Anchored placement (detect plane, tap to place)~~ — done; also the likely
  fix for splats drifting relative to the room
- ~~Position indicators (axis bars, surface outlines)~~ — done
- ~~Measuring notches on the indicators~~ — done
- ~~Occlusion against detected planes~~ — done; conservative (one depth sample
  per pixel stands in for a translucent column), off by default
- ~~Spatial chunking + frustum culling via `setChunkEnabled`, no fork~~ — done;
  visible-set logic verified in the simulator, **frame-rate benefit not yet
  measured on a real capture**
- **Performance, what's left.** Culling saves rasterization but not the CPU
  sort, which still walks every splat — the quality budget is the only lever on
  that, and it downsamples uniformly rather than by splat size. A shader
  early-out (real per-splat occlusion) still needs vendoring MetalSplatter, and
  better plane occlusion needs `highQualityDepth: true`, which is itself slower.
  See INTEGRATION.md "Performance".
- Snapshot / screen recording from within the viewer
- Saved viewpoints / bookmarks within a splat
- Use ARKit camera intrinsics for projection (already noted in INTEGRATION.md)

**Dependencies:** Core, MetalSplatter 1.0.1 (via SPM), ARKit, Metal

**Status:** Rendering in the simulator, with manual placement (pivot-bracketed
scale/rotate/translate), anchored tap-to-place, a collapsible control menu,
gestures with optional axis lock, a measuring ruler on the indicators, plane
occlusion, chunk culling, and a camera-passthrough compositor — all exercised
in the simulator.

**Still unverified — needs a device.** ARKit doesn't run in the simulator, so
`ARKitPoseProvider` compiles but has never produced a pose, and the passthrough
path's camera plumbing (`CVMetalTextureCache` against the real capture pool,
`displayTransform`) has never seen a real frame; only the compositor math is
verified, against a synthetic test pattern. Real PLY files load (manually
tested); SPZ and `.splat` loading is still untested.

---

### Capture

**Purpose:** Help a beginner produce a video suitable for splat training.
The biggest new feature and the most product-distinguishing.

**Why this matters:** Even with a good camera app, capturing a splat-ready
video takes practice. Most failures come from things a tool can detect and
warn about — motion too fast, missed coverage, wrong camera settings,
inconsistent lighting.

**Scope (in rough build order, each step is independently useful):**

1. **Locked camera mode.** Wrap `AVCaptureSession` with sensible splat
   defaults:
   - Fast shutter (1/250s or faster) to minimize motion blur
   - Locked exposure after initial frame
   - Locked focus (manual or auto-then-lock)
   - Locked white balance
   - 4K30 or 1080p60, H.264 in MP4
   - Expose only the few settings that matter; hide the rest

2. **Pre-capture path planner.** Before recording, user sketches a rough
   path through space using ARKit:
   - Tap to drop waypoints in the AR view
   - Visualize planned path as a curve
   - Suggest path patterns: orbit, figure-8, multi-height
   - Confirm before recording starts

3. **Live capture coaching.** During recording, monitor and warn:
   - Motion too fast → motion blur risk
   - Motion too slow → coverage inefficiency
   - Coverage gaps → "you haven't captured this angle"
   - Height variation → "try a lower/higher angle"
   - Lighting changes mid-capture → flag for re-shoot
   - Powered by ARKit's IMU + scene understanding

4. **Multi-clip support.** Some captures benefit from multiple short
   clips rather than one long take:
   - Pause/resume within a session
   - Stitch clips with shared AR coordinate frame
   - Trim individual clips before export

5. **Export.** Hand off to:
   - MP4 for cloud training pipelines (Polycam, Luma, etc.)
   - The Training feature for on-device (when ready)
   - ZIP of raw frames for users with custom pipelines

**Key components:** `CaptureSession` (AVFoundation wrapper),
`PathPlannerView`, `CoachingOverlay`, `MotionAnalyzer` (CoreMotion + ARKit),
`ClipManager`

**Dependencies:** AVFoundation, ARKit, CoreMotion, Core, Services

**Open questions:**
- How much coaching is too much? Find the line between helpful and patronizing.
- Path planner presets — useful or noise?
- What's the right "this video will splat well" metric? Coverage score? Sharpness?

**Status:** Planned. Biggest unknowns. Build the smallest useful slice
(locked camera mode) first.

---

### Training

**Purpose:** On-device splat training from captured video. Long-term,
experimental.

**Context:**
- Scaniverse does on-device training; quality is reportedly lower than cloud
- RadianceKit on macOS does full local training (M1+ required) — good reference
- Apple Silicon iPhones do inference well; training is harder
- This is the most uncertain feature; treat it as research, not a roadmap commitment

**Scope (long-term, speculative):**
- Take a captured or imported video
- SfM (Structure from Motion) for camera alignment
- Splat initialization from sparse point cloud
- Training loop using Metal compute kernels
- Quality presets (fast / balanced / quality)
- Live preview during training

**Sub-problems:**
- On-device SfM is hard. Candidates: ARKit's existing world map,
  port of COLMAP, custom SIFT/SuperPoint pipeline
- Memory budget: 16GB unified is the practical ceiling on current iPhones
- Background training when plugged in / charging
- Battery and thermal management

**Dependencies:** Metal Performance Shaders, possibly MLX, Core

**Prior art:** RadianceKit (macOS), Scaniverse (iOS), 3DGS reference (CUDA)

**Status:** Research. Don't start until Capture is mature.

---

### Settings

**Purpose:** App-wide preferences and metadata.

**Scope:**
- Viewer prefs: default scale, movement speed, look sensitivity
- Capture prefs: default resolution, codec, coaching strictness
- Training prefs (when implemented)
- Storage usage display + cache management
- About / credits / open-source licenses / privacy policy / version info

**Key components:** `SettingsView`, `AppPreferences` (UserDefaults
or `@AppStorage` wrapper)

**Dependencies:** Minimal. Features observe their own slice of preferences.

**Status:** Build incrementally as features need it; don't front-load.

---

## Shared infrastructure

### Core

Shared types used across features. Likely contents:
- `Splat` model (metadata, format enum: PLY/SPZ/.splat, source, capture date)
- Math utilities (matrix helpers from Viewer/Rendering can move here as
  they're reused)
- Format definitions and constants

### Services

Cross-feature services:
- `SplatStorage` — read/write splats to documents/caches, list, delete
- `SplatIO` — format-specific loading. MetalSplatter handles most of this;
  this is a thin app-side wrapper
- `ThumbnailGenerator` — render preview images for Library
- `SharingService` — wrap `UIActivityViewController` for export flows

### Components

Reusable UI:
- `VirtualJoystick` — currently in Viewer/Simulator/, move here when reused
- `SplatPreviewCard` — thumbnail + metadata cell for Library/Home
- Any future AR overlay primitives used by both Viewer and Capture

---

## Build order

Each step ends with something runnable and testable:

1. ~~**Wire MetalSplatter into Viewer.**~~ **Done.** The sample scene is
   generated procedurally rather than bundled as a PLY, to keep a large binary
   out of the repo.
2. **Library + Home (basic).** Replace the hardcoded splat with a real
   pick-from-library flow. App now feels like an app.
3. **Settings (minimal).** Movement speed, default scale. Real preferences
   via `@AppStorage`.
4. **Capture: locked camera mode only.** Simplest possible "press to record
   a splat-friendly video." Export MP4 to Files.
5. **Capture: path planner.** AR waypoints before recording starts.
6. **Capture: live coaching.** Motion analysis, real-time warnings.
7. **Capture: multi-clip.** Pause/resume, splicing.
8. **Polish pass.** Onboarding, sharing flow, Library improvements.
9. **Training.** Research phase. Far future.

Every step from 1 onward is shippable to TestFlight. Important for the
App Store name reservation — the 90-day clock resets each time a build
is uploaded, even a minimal one.

---

## Out of scope (for now)

- Cloud sync between devices
- Sharing splats with other Lustre users (social features)
- Apple Vision Pro version — related, but its own project
- iPad-specific UI — universal binary is fine, no custom layouts
- AR Quick Look integration for sharing with non-Lustre users

