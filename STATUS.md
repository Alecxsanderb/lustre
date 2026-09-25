# Lustre — Status

Snapshot of where things stand. Plan and build order live in ROADMAP.md;
long-term history is git. Replace entries, don't append.

## Last updated
- 2026-09-25
- TestFlight build: **uploaded and installed on a device** (user report,
  2026-09-24). Project is at 1.0 (1); build number not confirmed.

## Current focus
ROADMAP Build order **steps 2 (Library + Home) and 3 (Settings) are merged to
`main`** and verified in the simulator. Next is step 4 (Capture: locked camera
mode), after the on-device pass below.

## Recently done
- **2026-09-25, step 3 Settings + test target.** `LustreTests` (hosted, Swift
  Testing, shared `Lustre` scheme; 150 tests pass) covers PLYPreflight,
  SplatFileNaming, AppPreferences, SplatScale/Bounds, RulerScale, Frustum,
  LibrarySort, and the Viewer's initial/fitted scale logic. Settings (gear on
  Home): Initial size preset, simulator-only joystick speed, library storage
  total, version/build. Verified in the simulator: gear opens Settings, all
  sections render, Initial size persists across relaunch and the Viewer opens
  with it. code-reviewer pass: no correctness findings. **Not verified:**
  joystick slider change by hand (automated drag didn't take), each preset
  on a real ARKit plane.
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
3. On device: try each Initial size preset with tap-to-place, and confirm
   the Simulator section is absent from the TestFlight build.
4. Then ROADMAP Build order step 4 (Capture: locked camera mode).

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
