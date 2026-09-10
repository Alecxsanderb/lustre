---
name: arkit-pose
description: ARKit 6DoF pose, device-only capture hardware, and the simulator boundary in Lustre. Use when touching Viewer/AR, ARKitPoseProvider, the PoseProvider protocol, AVFoundation capture, CoreMotion motion coaching, or when deciding whether a change can be verified without a physical iPhone.
---

# ARKit and the device boundary

## What does not exist in the Simulator

ARKit, AVFoundation capture, and CoreMotion. `ARWorldTrackingConfiguration.isSupported`
returns `false`, so `ARKitPoseProvider` compiles and no-ops there.

**Consequence for reporting:** a green `xcodebuild` for the simulator verifies
that device-only code *compiles* and nothing more. Say it needs on-device
testing. Never call it working.

As of the MetalSplatter integration, `ARKitPoseProvider` has **never executed a
single line** on hardware. Treat every claim about it as unverified: the 6DoF
path, the intrinsics projection, and `recenter()`.

## The PoseProvider seam

The abstraction that makes the Viewer testable without hardware. Two
implementations, selected in `ViewerModel.makeProvider()`:

```swift
#if targetEnvironment(simulator)
SimulatedPoseProvider()          // dual joysticks
#else
ARKitPoseProvider.isSupported ? ARKitPoseProvider() : SimulatedPoseProvider()
#endif
```

`CameraPose` carries a full camera-to-world `transform` rather than
position+orientation, so ARKit can supply an exact matrix without quaternion
decomposition. `viewMatrix` is its inverse. Camera looks down **-Z**, **+Y** up
— Metal's and ARKit's shared convention.

Providers are `@MainActor`: read from the render loop, written by UI gestures,
so one actor avoids a lock.

## Orientation and intrinsics

Don't hand-roll the view matrix from `frame.camera.transform` — ARKit's camera
axes are tied to landscape-right, so a portrait app is rolled 90°. Use the
orientation-aware accessors:

```swift
camera.viewMatrix(for: interfaceOrientation)
camera.projectionMatrix(for: interfaceOrientation, viewportSize:, zNear:, zFar:)
```

Real intrinsics (not a guessed FOV) are what make a splat sit still relative to
the room. This is why `PoseProvider.projectionMatrix(...)` exists and returns
optional — nil falls back to `perspectiveProjection`.

`ARKitPoseProvider` polls `session.currentFrame` from `update(deltaTime:)`
rather than using `ARSessionDelegate`: the render loop already runs at display
rate, and polling keeps everything on one actor. It also holds the last good
pose when `trackingState` isn't `.normal`, because a pose from a non-tracking
camera is garbage.

`recenter()` composes an `originOffset` instead of re-running the session —
restarting would lose tracking.

## Monoscopic only

iPhone, single view. No visionOS, no stereo. That's why the renderer is
constructed with `maxViewCount: 1`.

The camera model is spatial, not orbit: the splat is world-anchored and the user
moves the phone to look around it, like Apple's Measure app.

## Placement (built)

`SurfaceProvider` is the third ARKit-free seam, alongside `PoseProvider` and
`CameraFrameSource`: plane detection, a center-screen raycast, and anchoring.
`SimulatedPoseProvider` adopts it with a synthetic floor at y = -1.5, so the
placement flow and gizmo are simulator-testable.

**Anchor, don't hardcode.** A splat at a fixed world transform drifts because
ARKit refines its map and the transform doesn't follow. Re-read
`anchorTransform(for:)` every frame. Re-running the session to change plane
detection must omit `.resetTracking`, or placed anchors are lost.

Plane detection is enabled only while placing, while indicators are on, or
while plane occlusion is on.

### Plane geometry, not just extent

`ARPlaneAnchor` gives both `planeExtent` (a bounding rectangle) and
`geometry.boundaryVertices` (a convex hull that follows the actual surface).
Use the hull wherever the plane is drawn or rasterized — masked by its
rectangle, a real table cuts a hard rectangular hole out of the splat in
mid-air. Boundary vertices are relative to the anchor's own origin, so the
`plane.center` offset that `refreshPlanes` folds into the transform has to come
back out of the vertices, or the outline sits skewed from the plane it
describes.

### Historical note

`ARKitPoseProvider` used to set `configuration.planeDetection = []`. The
placement flow needs `[.horizontal]` — detect a plane, raycast to tap-place an
`ARAnchor`, then pinch-to-scale and two-finger-rotate to fit. This matters
because Luma-style SfM output has an arbitrary coordinate frame and arbitrary
scale with no metric ground truth in the file, so placement can't be automatic.
Design is in `Lustre/Viewer/INTEGRATION.md` §5; don't improvise a different one.

## Three providers, not two

`PoseProvider` already abstracts the camera source and `SplatRenderer` never
imports ARKit — that constraint is satisfied, don't rebuild it. The gap is
`OrbitPoseProvider`: azimuth/elevation/distance around the splat's bounding-box
center. It's the deterministic unit-test path for matrix math *and* the
user-facing fallback when world tracking is unsupported or tracking fails.
`SimulatedPoseProvider` is free-flight FPS and is not that fallback.

## Info.plist

`NSCameraUsageDescription` is set via `INFOPLIST_KEY_NSCameraUsageDescription`
in build settings (the target uses `GENERATE_INFOPLIST_FILE = YES`, so there is
no checked-in plist to edit).

## Capture (not yet built)

When Capture starts, the splat-friendly defaults are: shutter 1/250s or faster,
locked exposure/focus/white balance after the first frame, 4K30 or 1080p60,
H.264 in MP4. All of it is device-only and unverifiable in the simulator.
