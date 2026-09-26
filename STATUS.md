# Lustre — Status

Snapshot of where things stand. Plan and build order live in ROADMAP.md;
long-term history is git. Replace entries, don't append.

## Last updated
- 2026-09-25
- TestFlight: **1.0 (6) uploaded 2026-09-26** (`80b5bb4`: placement and
  depth-drag fixes), not yet tested on device. 1.0 (5) (step 3 Settings) was
  device-tested 2026-09-26 and produced the bug reports fixed in 6. The project file stays at build 1: uploads let App Store
  Connect assign the build number (`manageAppVersionAndBuildNumber`).

## Current focus
ROADMAP Build order **steps 2 (Library + Home) and 3 (Settings) are merged to
`main`** and verified in the simulator. Next is step 4 (Capture: locked camera
mode), after the on-device pass below.

## Recently done
- **2026-09-26, Viewer display defaults** (`6461ed9`..`d10f351`). Touch
  controls, axis lock, indicators, ticks, units (locale default), background,
  and occlusion are stored; Viewer menu changes write back ("last used wins")
  and Settings › Viewer Display edits the same values. Detail is a Settings
  default only (in-Viewer change lasts for that splat). Stored intent survives
  unavailability (no AR doesn't clear occlusion). Fixed the latent bug where
  indicators on at open never drew. Verified in the simulator by tapping:
  toggling axis lock in the Viewer writes it, and the next splat opens with it
  on. code-reviewer: no blocking findings. **Not verified on device.**
- **2026-09-26, placement + depth-drag fixes (from the 1.0 (5) device test).**
  `775386c`: the placement overlay was drawn once and never updated on device
  (it read an unobserved ARKit poll), so Place / Place anyway stayed disabled;
  it now follows an observed readiness state. `7b68b7b`: drags and nudge
  arrows applied world-space deltas to an anchor-local translation, so an
  ARKit raycast anchor's yaw rotated them; the axes are now built in anchor
  space. `80b5bb4` (after code review): the basis is built in world space and
  then mapped into the anchor, so a tilted surface anchor doesn't skew drags.
  Unit-tested and simulator-checked (overlay updates on its own).
  **Not verified on device yet.**
- **2026-09-25, step 3 Settings + test target.** `LustreTests` (hosted, Swift
  Testing, shared `Lustre` scheme; 150 tests pass) covers PLYPreflight,
  SplatFileNaming, AppPreferences, SplatScale/Bounds, RulerScale, Frustum,
  LibrarySort, and the Viewer's initial/fitted scale logic. Settings (gear on
  Home): Initial size preset, simulator-only joystick speed, library storage
  total, version/build. Verified in the simulator: gear opens Settings, all
  sections render, Initial size persists across relaunch, and a splat opens
  with Room set (scale math covered by unit tests; the on-screen scale
  readout wasn't checked). code-reviewer pass: no correctness findings.
  **Not verified:** joystick slider change by hand (automated drag didn't
  take), each preset on a real ARKit plane.
- **2026-09-25, stale docs fixed.** INTEGRATION.md no longer claims the AR
  path has never run or that we don't override `highQualityDepth`. ROADMAP's
  Viewer section now reflects Library integration and the TestFlight run.
- **2026-09-24, step 2 Library + Home.** Home (recents row, disabled Capture
  CTA, Browse Library) is now the root; Library grid over `Documents/Splats/`
  with multi-file import (copied in, `name 2.ply` on collision), rename
  (renames the file), delete, share (original file), sort by date/name/size.
  Viewer takes a `ViewerContent` and lost its own import button; the sample
  room is reachable from Home/Library. Files app shows Lustre › Splats
  (`Config/Lustre-Info.plist` adds `UIFileSharingEnabled`). Verified in the
  simulator: Files drop-in picked up on refresh, picker import, rename
  (validation + collision errors), delete, recents ordering, open → Viewer.
  code-reviewer pass done; its one real finding (full rescan on open) fixed.
  **Not verified:** on device, Share sheet, SPZ/.splat through the Library.
- **2026-09-24, damaged PLYs no longer hang on "Loading…".** MetalSplatter
  1.0.1's `SplatPLYSceneReader` drops any error PLYIO throws mid-body and
  never finishes its stream. App-side fix in `Services/`: `PLYPreflight`
  checks a binary PLY's size against its header (truncated → "is
  incomplete", trailing bytes → "isn't a valid PLY file"; also rejects
  element counts > UInt32.max, which crash PLYIO). `SplatStreamWatchdog`
  fails any read that yields nothing for 20 s, catching what a size check
  can't (malformed ASCII rows, lists). Verified in the simulator via the
  Library with truncated, trailing-byte, bad-ASCII, and valid PLYs. SPZ
  (synchronous) and `.splat` (finishes its stream on error) aren't affected.
- 2026-09-09, three commits (`dea8af7`, `e96770e`, `2cd7d8c`): Viewer controls,
  anchored tap-to-place, position indicators, measuring ruler, plane occlusion,
  chunking + frustum culling, quality budget, passthrough compositor.
- 2026-09-23: simulator build (iPhone 17) succeeds on `2cd7d8c`.
- **Device run via TestFlight (2026-09-24):** ~10 splats loaded and viewed,
  "worked great" per user. On device `ViewerModel` picks `ARKitPoseProvider`,
  so the AR pose path has now executed. Not recorded: which formats, which
  iPhone, and whether passthrough / plane occlusion / tap-to-place were used.
- 2026-09-24: code-reviewer pass on `2cd7d8c` done. Little bloat (~30-40
  lines); a few real bugs. Fixes committed (`a7a71e3`..`b15e624`).
  Simulator build passes. On-device checks still needed: nudge direction,
  plane lookup, background/resume keeping the anchor, culling pop-in.
- **Splat formats, settled:**
  - Picker (`ViewerScreen.swift:92` → `SplatFileIO.importableContentTypes`)
    offers `ply`, `spz`, `splat`, `sog`, `sogs`.
  - Parser (MetalSplatter 1.0.1 `SplatFileFormat` / `AutodetectSceneReader`)
    decodes `ply`, `spz`, `splat` only.
  - `sog`/`sogs` are rejected before parsing with a format-specific message.

## Known issues
- **MetalSplatter's PLY reader hangs on body errors** (upstream bug in
  1.0.1, still on `main`; worked around app-side, see Recently done). Issue
  not filed yet; draft text exists.
- **No thumbnails.** Library/Home show tinted placeholder tiles; deferred to
  the polish pass by decision.
- **Viewer nav title is black on the black background** when passthrough is
  off (pre-existing; used to say "Viewer", now the splat name).
- **Picker offers formats the parser can't read (SOG).** Deliberate, so the
  user gets a specific error rather than a generic one, but still a mismatch.
  Repro: import any `.sog` → "Lustre can't read SOG files yet. Export as PLY,
  SPZ, or .splat."

## Suspected issues
- **Recenter probably misaligns the splat on device.** `ARKitPoseProvider.recenter()`
  folds an offset into `pose`, but raycast hits, the fallback candidate, and
  `ARAnchor` transforms stay in raw ARKit world space, so after a recenter the
  renderer's `pose.viewMatrix * anchor` mixes frames and the placement preview
  would sit away from the crosshair. Found reading code 2026-09-26. Confirm:
  recenter on device, then re-place.
- **Passthrough camera plumbing and real-plane occlusion may be unexercised.**
  The AR pose path has run on device; these two are off by default, so the
  TestFlight run may not have touched them. Confirm: enable each on device.
- **SPZ and `.splat` loading untested.** Only PLY is confirmed. Confirm: import
  one of each (works in the simulator; no ARKit needed).
- **`spz`/`splat`/`sog` resolve to dynamic `dyn.*` UTTypes.** A file another
  app exported under its own declared UTI might be greyed out in the picker.
  Confirm: pick an `.spz` exported by another app from Files.
- **Performance at real scale unmeasured.** The CPU sort still walks every
  splat, and the culling benefit is unproven. Confirm: frame timing on device
  with a multi-million-splat capture.

## Next up
0. Run step 2 on device (TestFlight): import from Files/iCloud,
   Share sheet, open a large capture from the Library.
1. Run the review fixes on device: nudge arrows, drop line on
   table vs floor, background then resume with a placed splat, a large
   capture for culling pop-in.
2. Confirm SPZ and `.splat` loading (may already be covered by the device run).
3. On device (1.0 (6)): placement overlay goes Starting tracking → Place
   anyway → Place; Place anyway works; drag, dolly, and nudges follow the
   camera heading after placing on a detected surface (try a sloped one).
   Also try recenter then re-place (see Suspected issues).
   Plus: try each Initial size preset with tap-to-place, and confirm
   the Simulator section is absent from the TestFlight build.
4. On device: Viewer display defaults (see Recently done) carry over
   between splats and match Settings; a fresh US-region install opens in feet.
5. **Library thumbnails.** Planned 2026-09-26: offscreen MetalSplatter render
   of a stride-decimated (~300k, SH0-only) subsample in `Services/Thumbnails/`,
   one at a time, paused while the Viewer is open; JPEG cache in
   `Caches/Thumbnails/` keyed by name+size+mtime+renderer version; generated
   on first display; `.failed` markers for damaged files. Decisions: skip SPZ
   files over ~50 MB (whole-file decompression peak); exterior 3/4 framing
   accepted for v1 even though interior captures will look like a shell.
   Estimated 600-800 lines, 3-4 sessions.
6. Then ROADMAP Build order step 4 (Capture: locked camera mode).

## Open questions
- Is the App Store name "Lustre" reserved? (Every build upload resets the
  90-day clock.)
- Which iPhone is the device target? Which formats were in the ~10 test splats?
- Keep SOG in the picker with its specific error, or hide it until there's a
  decoder?
- File the MetalSplatter PLY-hang issue upstream?
- `SplatLibrary` scans the folder synchronously on the main actor (init,
  foreground, after mutations). Fine at tens of files; revisit if Capture
  makes libraries large.
