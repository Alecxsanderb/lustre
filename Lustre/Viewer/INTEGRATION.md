# Viewer design note — monoscopic spatial splat viewer

**Scope:** iPhone only. The splat is world-anchored and you move the phone to
look around it, like Apple's Measure app. Not an orbit viewer, not stereo, not
visionOS. Single drawable, single view, one eye.

Status: MetalSplatter renders in the simulator via `SimulatedPoseProvider`.
Placement (pivot-bracketed scale/rotate/translate), the log scale slider, the
control menu, the two-finger gesture set, and the passthrough compositor are all
verified there.
Everything AR-related below is **designed, not verified** — see "What has never
run" at the end.

---

## 1. Single view — amplification

`maxViewCount: 1` at renderer construction is the whole mechanism. The library
clamps with `min(maxViewCount, 2)` and sets
`maxVertexAmplificationCount = maxViewCount`, so an amplification count of 1
makes `amplification_id` in the shaders constant at 0 and every draw reads
`uniforms[0]`.

Correction to "strip amplification from the sample app": there is nothing in our
code to strip — we adapted the sample's `MetalKitSceneRenderer` frame loop, not
its shaders, and our tree has no stereo path (audit below). The shaders live in
`MetalSplatter/Resources/*.metal` as **package resources of an SPM dependency**,
so they can't be edited without vendoring the library. Amplification is
neutralized at construction, not removed. That's the correct and sufficient
approach; don't fork the package for it.

We pass `renderTargetArrayLength: 0` and a single `ViewportDescriptor` for the
same reason.

## 2. Camera from ARKit — the actual API

MetalSplatter takes camera state per frame as an array of `ViewportDescriptor`
(read from `MetalSplatter/Sources/SplatRenderer.swift`, 1.0.1):

```swift
public struct ViewportDescriptor {
    public var viewport: MTLViewport
    public var projectionMatrix: simd_float4x4
    public var viewMatrix: simd_float4x4
    public var screenSize: SIMD2<Int>
}

try renderer.render(viewports: [descriptor],
                    colorTexture:, colorStoreAction:,
                    depthTexture:, rasterizationRateMap:,
                    renderTargetArrayLength:, to: commandBuffer)
```

There is **no model-matrix parameter**. Splat placement must be folded into
`viewMatrix` — `poseProvider.pose.viewMatrix * sceneState.modelMatrix`.

**Don't feed `ARFrame.camera.transform` directly.** ARKit's camera axes are
pinned to landscape-right, so in a portrait app the raw transform is rolled 90°.
Use the orientation-aware accessors:

```swift
let view = frame.camera.viewMatrix(for: interfaceOrientation)
let proj = frame.camera.projectionMatrix(for: interfaceOrientation,
                                         viewportSize: drawableSize,
                                         zNear: 0.05, zFar: 100)
```

`viewMatrix(for:)` is already world-to-camera, so it goes straight into
`ViewportDescriptor.viewMatrix`; `simd_inverse` of it is the camera-to-world
pose if you need the position.

**Caveat found in source:** `updateUniforms` derives the values it uses for
covariance projection from only two entries of the projection matrix —
`focalX = screenSize.x * proj[0][0] / 2`, `tanHalfFovX = 1 / proj[0][0]`, and
the `[1][1]` equivalents. Any principal-point offset ARKit puts in `[2][0]` /
`[2][1]` is **ignored** for splat footprint sizing, though it still applies to
vertex position. Expect slight splat-size error on devices with an off-center
principal point. Acceptable for v1; revisit if splats look subtly wrong at frame
edges.

## 3. Rendering stack — ARSession + custom Metal

**RealityKit cannot render Gaussian splats**, so `ARView` is not an option. The
stack is:

- A headless `ARSession` with `ARWorldTrackingConfiguration` — no ARKit-provided
  view. Pose and intrinsics are pulled from `session.currentFrame`.
- Our own `MTKView` + `SplatRenderer` (`MTKViewDelegate`) for all drawing.

### Passthrough — two passes, not one

**Correction.** An earlier version of this note claimed splats could composite
over a camera image already in the drawable. They cannot.
`MetalSplatter.SplatRenderer.render` hardcodes
`colorAttachments[0].loadAction = .clear` (`SplatRenderer.swift:711`), so the
splat pass destroys whatever is in the color texture before drawing. There is no
parameter to change it and `clearColor` is `public let`, fixed at init.

So splats render **offscreen** and a second pass composites. Implemented in
`Rendering/PassthroughCompositor.swift` + `Rendering/Passthrough.metal`:

**Pass 1 — splats, offscreen.** `SplatRenderer.draw(in:)` targets
`splatColorTexture` (`.bgra8Unorm_srgb`, drawable-sized, `.private`) instead of
the drawable. The library clears it to its own transparent `clearColor`, and its
blend state is premultiplied `.one` / `.oneMinusSourceAlpha`, so the result is a
**premultiplied** RGBA image.

**Pass 2 — composite, into the drawable.** One fullscreen triangle samples the
camera planes and the splat texture and outputs
`splat.rgb + camera.rgb * (1 - splat.a)`.

Camera planes come from `CameraFrameSource`, a narrow protocol in `Rendering/`
that deliberately carries no ARKit types — `ARKitPoseProvider` adopts it and
owns the `CVMetalTextureCache`; `SimulatedPoseProvider` doesn't, which is why
passthrough is simply unavailable in the simulator.

**Three traps, all of which produce a plausible-but-wrong image rather than a
crash:**

1. **sRGB.** Sampling a `_srgb` texture returns *linear* values and writing to
   one re-encodes, but the YCbCr transform yields *sRGB-encoded* values. The
   shader must linearize the camera color before mixing or passthrough comes out
   washed out. You can't dodge this with a non-sRGB offscreen texture — the
   library's pipeline format is fixed at construction.
2. **Premultiplication.** The splat texture is already premultiplied. Using the
   straight-alpha `mix()` formula double-darkens the splats.
3. **Orientation.** The shader needs *view→capture* UVs, so it takes the
   **inverse** of `ARFrame.displayTransform(for:viewportSize:)`.

`TestPatternCameraSource` supplies synthetic YCbCr planes in the simulator, so
all three are verifiable without a device. Only the ARKit plumbing itself
(`CVMetalTextureCache` against the real capture pool, `displayTransform`, the
pixel-format range flag) remains device-only.

Offscreen targets are allocated lazily on first enable and released on
toggle-off and on memory warning — ~24 MB at phone resolution. Depth is
`.private`, not `.memoryless`: the library's device-only multi-stage pipeline
has never run, and if it touches depth across encoder boundaries a memoryless
attachment would break in a way no simulator run reveals.

## 4. No real-world occlusion — known v1 limitation

Splats are alpha-blended back-to-front. Confirmed from source:

- `depthCompareFunction = .always` on every pipeline variant — the splat pass
  **never depth-tests**, so nothing in the scene can occlude a splat.
- `isDepthWriteEnabled = writeDepth`, where `writeDepth = depthFormat != .invalid`.

Small correction to the framing: depth *is* written (we pass `.depth32Float`);
what's absent is depth *testing*. The practical result is the same — splats draw
over everything, including your hand and the walls — but it matters because the
written depth is a usable signal later.

**v1 behavior: splats render over everything. Not solving this now.** Real
occlusion needs per-pixel scene depth from `ARFrame.sceneDepth`
(LiDAR/`ARConfiguration.FrameSemantics.sceneDepth`) tested against splat depth,
which is a Phase 3 LiDAR question and a hardware-gated feature. Document it in
the UI as expected behavior rather than a bug.

## 5. Placement and scale — the real design problem

Luma runs its own SfM, so a returned PLY is in an **arbitrary coordinate frame
at arbitrary scale with no metric ground truth in the file**. Nothing in the
splat data says how big the scene is or which way is up. Two consequences: the
existing `appliesUpCalibration` 180°-about-Z heuristic is a guess that will
sometimes be wrong, and initial scale is unknowable without user input.

### Built: manual placement

Shipped ahead of the anchor flow below, because it needs no ARKit and works in
the simulator. All of it lives on `SplatSceneState` and is driven by
`ControlMenu` and `SplatGestures`.

**The pivot is the part that matters.** SfM output has an arbitrary origin that
can sit far outside the point cloud, so scaling or rotating about it throws the
splat across the room instead of acting in place. `modelMatrix` is therefore
bracketed:

```
T(translation) · R_user · S(scale) · R_upCalibration · T(-pivot)
```

`pivot` comes from `SplatBounds.robust` — 2nd–98th percentile per axis over a
strided subsample, *not* raw min/max, because real PLYs carry far-flung floater
splats that inflate an AABB by orders of magnitude. `pivot` and `fittedScale`
are asset metadata, set at load and deliberately **not** cleared by
`resetPlacement()`.

Both corrections are gated on `hasAuthoredPlacement`. Files get them; the
procedural sample doesn't, because its origin and its metres are deliberate —
re-centering it on its bounding box visibly shifts a scene the author already
placed. ARKit-derived captures will want the same exemption.

Scale is `SplatScale`: logarithmic 0.001–1000 with 1.0 still meaning "as
authored", magnitude-aware formatting, and auto-fit seeding the longest
horizontal extent to 1.5 m. Dollhouse-first is deliberate — too small is
obviously present and recoverable, too large puts the camera inside geometry and
reads as a failed load.

Rotation is Euler (intrinsic Y-X-Z), not a quaternion: the yaw slider has to
round-trip exactly, and extracting yaw from a quaternion with non-zero
pitch/roll is lossy, so the slider would drift as the gesture is used. Yaw is
primary; pitch and roll are behind a disclosure.

Translation is stored in **world** space but *input* is camera-relative via
`CameraRelativeBasis`, snapshotted at gesture start so the axes can't rotate
mid-drag. Forward is flattened to the XZ plane (legitimate because
`worldAlignment = .gravity`); vertical is always world up.

Gestures are all two-finger — pinch to scale, rotate to yaw, pan to translate —
because `VirtualJoystick` already owns single-finger drags and `NavigationStack`
owns the leading edge. They are **UIKit** recognizers, not SwiftUI gestures: a
`UIView` hosting a recognizer consumes touches before any SwiftUI gesture
beneath it, which silently swallowed `MagnifyGesture` on the first attempt.

### Still to build: anchored placement

**State machine** — add to `SplatSceneState` rather than inventing a parallel
store:

```
.loading → .awaitingSurface → .placing(anchor) → .placed(anchor) → .adjusting
```

1. **`.awaitingSurface`** — enable `configuration.planeDetection = [.horizontal]`
   (currently `[]` in `ARKitPoseProvider`, so this is a required change) and
   coach the user to sweep the phone until a plane is found. Show the detected
   plane's extent.
2. **`.placing`** — raycast from screen center or tap point with
   `ARRaycastQuery(.existingPlaneGeometry, alignment: .horizontal)`. On tap,
   create an `ARAnchor` at the hit. Seed scale from the splat's own bounding box
   so the longest horizontal axis spans ~1.5 m — an arbitrary but predictable
   starting point that keeps the splat on screen and in reach.
3. **`.placed`** — the anchor is the world origin for the splat. `modelMatrix`
   becomes `anchorTransform * translation * rotation * scale`. Re-read the
   anchor's transform each frame; ARKit refines anchors as tracking improves,
   and a cached copy will drift.
4. **`.adjusting`** — direct manipulation, all writing into `SplatSceneState`:
   - Scale, yaw, and translation are already built (above). What the anchor
     adds is a *reference frame*: gestures would compose against the anchor
     rather than the world origin.
   - **One-finger drag** → translate along the detected plane. Not possible
     today: one finger belongs to the joysticks. Once an anchor exists and the
     simulator joysticks are gone on device, a plane-constrained single-finger
     drag becomes the better interaction than the current two-finger pan.
5. Persist the final transform with the splat so reopening restores placement.
   Anchors don't survive a session without an `ARWorldMap`; storing the
   splat-relative transform and re-placing is simpler and enough for v1.

Keep placement out of `SplatRenderer`. It reads `sceneState.modelMatrix` and
knows nothing about anchors or gestures.

## 6. Camera-source abstraction

**This already exists — `PoseProvider` is the protocol.** It vends `pose`,
`verticalFieldOfView`, `statusMessage`, and an optional
`projectionMatrix(viewportSize:nearZ:farZ:)`, and `SplatRenderer` talks only to
it. `ARKitPoseProvider` is the AR-backed implementation. Nothing in the renderer
imports ARKit. That constraint is already satisfied — don't rebuild it.

What's actually missing is the **orbit** implementation. `SimulatedPoseProvider`
is free-flight FPS (dual joysticks), which is a fine simulator harness but is
not the "view a splat without moving around" fallback. Add `OrbitPoseProvider`:

- Azimuth/elevation/distance around the splat's bounding-box center, driven by
  one-finger drag and pinch.
- Deterministic and hardware-free, so it's the unit-test path for anything
  matrix-shaped — feed a known azimuth, assert the view matrix.
- User-facing too: the mode you get when `ARWorldTrackingConfiguration` is
  unsupported, when tracking fails hard, or when the user just wants to look at
  a splat sitting on a desk.

Provider selection currently branches on `#if targetEnvironment(simulator)` in
`ViewerModel.makeProvider()`. With three implementations that becomes a
user-visible mode, so it should be state on the model, not a compile-time
branch.

## 7. iPhone budget

Constraints the visionOS path never has to think about:

- **Thermals.** Sustained AR + splat sorting throttles a phone within minutes.
  ARKit at 60fps is already a heavy baseline before we draw anything. Budget for
  a degraded mode: drop splat count or framerate on
  `ProcessInfo.thermalStateDidChangeNotification` rather than letting the OS
  make the choice.
- **Memory: ~2–4GB usable**, not the 16GB of a dev Mac. A 500MB PLY is not a
  500MB problem — `AutodetectSceneReader.readAll()` materializes the entire
  `[SplatPoint]` array before any GPU upload, and `SplatChunk(device:from:)`
  then allocates a parallel `MetalBuffer`. Peak is roughly **2× the decoded
  size**, and decoded is larger than on-disk. Large captures must stream as
  multiple chunks; `addChunk` is per-chunk precisely so that's possible.
- **Memory warnings.** Nothing currently handles
  `didReceiveMemoryWarningNotification`. On a big load the app will be jetsammed
  with no diagnostic. At minimum: fail the load cleanly, `removeAllChunks()`,
  and surface a real message.
- **`highQualityDepth` — turn it off.** See the audit below; this is the one
  concrete visionOS cost we're currently paying.

---

## visionOS audit

Our Swift is clean. No `visionOS` / `xrOS` conditionals, no RealityKit, no
`ARView`, no `CompositorServices`, no stereo or amplification code. The only hit
for the whole search set is `maxViewCount: 1`, which is the monoscopic setting.
`SDKROOT = iphoneos` in both configurations; no XROS/VISIONOS build settings.

Three things worth acting on:

1. **`highQualityDepth` defaults to `true` and we don't override it.**
   `SplatRenderer.swift:92` constructs the library renderer without it. The
   library's own doc comment: high-quality depth "takes longer" and exists for
   "reducing artifacts during Vision Pro's frame reprojection." It gates
   `useMultiStagePipeline` (`writeDepth && highQualityDepth`), an imageblock
   tile-memory path with three stages instead of one. **On monoscopic iPhone
   there is no reprojection, so this is pure cost.** Pass
   `highQualityDepth: false`.
   Sharper still: `useMultiStagePipeline` is hardcoded `false` under
   `targetEnvironment(simulator)`. Every simulator verification so far exercised
   the single-stage path, while a device would take the multi-stage one — so the
   pipeline that actually ships is the one that has never been run.

2. **`TARGETED_DEVICE_FAMILY = "1,2"`** (both configs) ships an iPad binary, and
   `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` is populated. Not
   visionOS, but it contradicts "iPhone only." `"1"` would make the scope
   real. Left alone — narrowing the shipping device family is a product call.

3. **MetalSplatter declares `.visionOS(.v2)`** in its `Package.swift` and its
   depth design is shaped by Vision Pro. It doesn't affect our build (we build
   `iphoneos`), but it explains why the library's defaults aren't tuned for us.
   Read its Vision Pro comments as *not applicable* rather than as guidance.

## What has never run

`ARKitPoseProvider` has not executed a single line on hardware — ARKit reports
unsupported in the simulator. Unverified: the 6DoF path, `viewMatrix(for:)` /
`projectionMatrix(for:)` correctness, `recenter()`, whether a splat actually
sits still relative to the room, the multi-stage depth pipeline, and loading any
real PLY/SPZ/`.splat` file. Also unverified: everything in the passthrough path
that touches ARKit — wrapping `capturedImage` planes through
`CVMetalTextureCache`, the `displayTransform` inverse against a real camera, and
the full/video-range flag. The compositor *math* is verified in the simulator
against `TestPatternCameraSource`; the camera plumbing feeding it is not. The procedural `SampleSplatScene` (~12k splats) is
the only scene that has ever reached the renderer, and it says nothing about
performance at the 1–5M splats real captures produce.
