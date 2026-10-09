# Capture step 4 plan: locked camera mode

Architect plan, 2026-10-08. Covers ROADMAP Build order step 4. Not started.
Decisions marked **Open** need the user before work begins.

## Recommendation

Record through **ARKit from day one**, behind a `CaptureSource` seam (the
Capture analogue of `PoseProvider`):

- Steps 5-7 (path planner, live coaching, multi-clip in a shared AR frame)
  all need ARKit while recording, and ARKit can't share the back camera with
  a separate `AVCaptureSession`. Plain AVFoundation now means rewriting the
  recording core at step 6.
- ARKit gives per-frame camera poses and intrinsics for free. Saved as a
  sidecar, they're a head start for later SfM/training and the shared frame
  step 7 needs.
- What ARKit costs (no 4K60, no 10-bit/Log/ProRes) barely matters for splat
  training.
- Polycam, Scaniverse and Record3D record this way.

The seam exists anyway so a `SimulatedCaptureSource` (synthetic frames) can
exercise save → library → thumbnail → playback in the simulator. A plain
`AVCaptureSession` source stays possible as a fallback if the spike fails.

**Gate:** a 1-2 day on-device spike (step 0) decides this. If the locked
shutter doesn't hold under ARKit or tracking falls apart at 1/250 s, ship
step 4 on `AVCaptureSession` behind the same seam.

## Open decisions

1. **ARKit-backed vs AVCaptureSession** (above). Recommended: ARKit, pending
   the spike.
2. **What "1080p" means.** ARKit's main format is 1920×1440 (4:3).
   Recommended: the "HD" setting uses 1920×1440 when offered, 1920×1080
   otherwise. 4:3 covers more scene per frame.
3. **Container.** Recommended: fragmented `.mov`, so a crash or full disk
   still leaves a playable file. Luma, Polycam, nerfstudio, ffmpeg accept it.
   ROADMAP says MP4; fragmented MP4 support in AVAssetWriter is unconfirmed.
4. **Audio.** Recommended: none (useless for training, extra permission).
5. **Frame rate.** Recommended: 30 fps default, 60 optional. Shutter speed,
   not frame rate, prevents blur; pipelines sample 2-5 fps; 30 halves storage
   and heat. 4K is 30 fps only under ARKit.

Already decided by the user: HEVC default (H.264 option), 1080p-class
default, captures browsable in an in-app library.

## Design

**Recording (ARKit source).** Pick a format from
`ARWorldTrackingConfiguration.supportedVideoFormats` (wide back camera only;
`recommendedVideoFormatFor4KResolution` for 4K). After `run`, lock via
`configurableCaptureDeviceForPrimaryCamera`: custom shutter 1/250 s with ISO
raised to compensate (clamped, "too dark" flag at max ISO); white balance
locked to current gains; autofocus during preview, locked at record start
(also keeps intrinsics constant). `session.delegate` on a dedicated serial
queue; each `capturedImage` goes to an `AVAssetWriterInputPixelBufferAdaptor`.
If ARKit's pool starves, copy out with `VTPixelTransferSession`. Never poll
`currentFrame` on main.

**Preview.** RealityKit `ARView`, `automaticallyConfigureSession = false`.
Not SceneKit (deprecated). Revisit sharing the Viewer's compositor later.

**Where captures appear.** A **Splats | Captures segmented switch in
Library**, not a separate screen: captures are inputs to splats, and one
"Photos app" scales better. Capture's "View in Library" replaces the nav
stack with `[.library(.captures)]` so only one ARSession exists at a time.

**UI exposed.** Record button + timer; chips for locked shutter/ISO (with
"too dark"), resolution·fps, minutes of storage left; tap-to-meter/focus
before recording, lock icon during. Settings › Capture: resolution (HD/4K),
frame rate (30/60, 60 disabled with 4K), codec (HEVC/H.264); stored intent
survives unavailability. Storage line adds a captures total.

**Hidden/fixed.** Stabilization and HDR off; wide lens only (no lens
switching mid-take); orientation fixed at start; bitrate (~25 Mbps HD30,
40 HD60, 80 4K30) and 1 s keyframe interval; BT.709 tags.

**Permissions (build settings).** Reword `NSCameraUsageDescription` to cover
recording. Add `NSPhotoLibraryAddUsageDescription` (the share sheet's "Save
Video" crashes without it). No microphone. Camera-denied screen links to
Settings.

**Storage.** `Documents/Captures/` (visible in Files; folder is the source of
truth, no index). Record into `Documents/Captures/.recording/<uuid>.mov`,
then move to `Capture 2026-10-08 143205.mov` (collisions via
`SplatFileNaming.uniqueFileName`). Sidecars next to the video:
`<name>.capture.json` (settings, locked values, format, device, frame/drop
counts) and `<name>.poses.jsonl` (per frame: time, camera-to-world 4×4 in
ARKit world / landscape-right sensor axes, fx/fy/cx/cy, tracking state).
Rename/delete carry sidecars; videos without sidecars are fine. Leftovers in
`.recording/` are recovered on launch.

**Video thumbnails.** `AVAssetImageGenerator`, 480×360, ≤2 concurrent, cached
in **`Caches/CaptureThumbnails/`**. Must be separate from
`Caches/Thumbnails/`, which `SplatLibrary`'s sweep clears of non-splat JPEGs.

**Concurrency.** Writer and pose recorder are `nonisolated`, confined to the
ARKit delegate queue (`@unchecked Sendable`, documented). UI gets throttled
state ~4-10 Hz. No per-frame allocations beyond a buffered pose line.

**Sizes.** ~190 MB/min HD30, ~600 MB/min 4K30; pose sidecar ~10-20 MB per
5 min at 60 fps.

## Commits

0. **Spike (throwaway branch).** Debug screen: list `supportedVideoFormats`;
   run HD30, HD60, 4K30; lock exposure/WB/focus; record 2 min HEVC from
   `capturedImage`. For auto, 1/250, 1/500, in bright and dim indoor light
   while orbiting, measure: delivered vs nominal frames, timestamp gaps,
   writer drops, "retaining N ARFrames" warnings, whether shutter/ISO hold
   (read back 1 Hz), tracking state and return-to-start drift, thermal over
   5 min at 4K30, pixel format and color. **Pass:** <1% drops at HD30/60 and
   4K30, shutter holds, tracking normal indoors at 1/250.
1. Core types: `CaptureItem`, `CaptureSettings` (+ closest-format choice),
   `CaptureMetadata`, `PoseRecord`, `CaptureFileNaming`. Tests.
2. `Services/CaptureLibrary`: list/rename/delete with sidecars, staging,
   finalize, free space (`volumeAvailableCapacityForImportantUsage`),
   thumbnail sweep. Temp-folder tests.
3. `Services/VideoWriter`: HEVC/H.264 AVAssetWriter, fragments, real-time,
   drop-and-count on backpressure, drop non-increasing timestamps.
   Simulator round-trip test.
4. `Services/Thumbnails/VideoThumbnailer` + `ThumbnailKey(capture:)` +
   `ThumbnailStore` method. Test on a synthetic video.
5. Library Captures tab: segmented switch, `CaptureGridView`,
   `CapturePreviewCard`, `CaptureDetailSheet` (AVKit player, rename, share,
   delete, details); `LibrarySort` over a Core protocol; Photos-add key.
6. `AppPreferences.Capture` + Settings › Capture + captures storage total.
7. `CaptureSource` protocol, `SimulatedCaptureSource`, `CaptureModel`,
   `CaptureScreen`, post-record sheet (Done / Record Another / Delete), idle
   timer off, `.capture` route, Home CTA enabled, thumbnails paused during
   Capture.
8. `ARKitCaptureSource` (device only): format choice, locking, delegate-queue
   writer, pose sidecar, camera usage wording.
9. Robustness: interruptions (re-apply locks on resume), background finalize
   under `beginBackgroundTask`, thermal (warn `.serious`, stop `.critical`),
   storage (≥1 GB / 5 min to start, poll 2 s, stop <~300 MB), `.recording/`
   recovery.
10. Docs: STATUS, ROADMAP Capture status, arkit-pose skill (its Capture
    section and "never executed" claim are stale).

New code: `Core/` (capture types), `Services/` (library, naming, writer,
video thumbnailer), `Capture/Source|Simulator|UI/`, `Library/` (capture grid,
card, detail sheet). Touches `ContentView`, `LustreApp`, Home CTA,
`LibraryView`, `LibrarySort`, `AppPreferences`, `SettingsView`,
`ThumbnailStore`/`ThumbnailKey`, `SplatFileNaming` (message wording), and
`project.pbxproj` (Info.plist keys). Nothing in `Viewer/`.

## Tests

Pure: exposure math (ISO for target shutter, clamping, underexposed flag,
shutter never slower than 1/250), format choice (4K+60 → 30, HD prefers
1440, empty list), bitrate table, recording time left, orientation → track
transform, ARKit time → CMTime and timestamp dropping, file naming. Also
sidecar round trips, `CaptureLibrary` in a temp folder, preferences,
`VideoWriter` read-back (duration, frames, size, codec, drops),
`VideoThumbnailer`, and `CaptureModel` against a fake source (record/save,
start failure, background mid-record, storage stop, delete).

By hand in the simulator: Home → Capture → record (synthetic) → result sheet
→ Library Captures → play/rename/share/delete → visible in Files.

## Risks

- Fast shutter in dim light → high ISO noise, may hurt tracking and splat
  quality. "Too dark" badge is the user-facing answer.
- Encoder holding ARKit buffers may starve its pool (fix: copy out).
- ARKit may reset device settings on reconfigure/interruption; re-apply.
- Focus-lock ordering vs ARKit autofocus is unverified.
- HEVC encode in the simulator probably works on Apple Silicon; writer test
  falls back to H.264 if not.
- Everything in commits 8-9 is device-only; only the 15 Pro's format list
  will be seen, so selection must handle any list.
- iOS 18.0 floor: avoid iOS 26 APIs (e.g.
  `AVAssetWriter.inputPixelBufferReceiver`) and SceneKit.
