# Lustre — Status

Snapshot of where things stand. Plan and build order live in ROADMAP.md;
long-term history is git. Replace entries, don't append.

## Last updated
- 2026-09-24
- TestFlight build: **uploaded and installed on a device** (user report,
  2026-09-24). Project is at 1.0 (1); build number not confirmed.

## Current focus
ROADMAP Build order **step 2 (Library + Home) is implemented** (branch `library-home`),
and verified in the simulator. Next is step 3 (Settings), once step 2 has been
run on device.

## Recently done
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
- **Truncated PLY hangs the Viewer on "Loading…" forever.** MetalSplatter's
  `SplatPLYSceneReader.read()` runs its loop in an unstructured `Task`, so
  PLYIO's `unexpectedEndOfFile` is swallowed and the stream never finishes.
  Pre-existing, but the Library makes it easier to hit (e.g. a partial Files
  copy). Repro: `head -c 300000` a valid PLY into `Documents/Splats/`, open it.
  Back still works. Fix planned app-side in `SplatFileIO` (task spun off).
- **No thumbnails.** Library/Home show tinted placeholder tiles; deferred to
  the polish pass by decision.
- **Viewer nav title is black on the black background** when passthrough is
  off (pre-existing; used to say "Viewer", now the splat name).
- **Picker offers formats the parser can't read (SOG).** Deliberate, so the
  user gets a specific error rather than a generic one, but still a mismatch.
  Repro: import any `.sog` → "Lustre can't read SOG files yet. Export as PLY,
  SPZ, or .splat."
- **INTEGRATION.md is stale in two places.** "visionOS audit" item 1 says we
  don't override `highQualityDepth`, but `SplatRenderer.swift:249` passes
  `false` (so its multi-stage-pipeline warning no longer applies). "What has
  never run" still lists loading real PLY files. Repro: read both.
- **No test target.** The pbxproj has no test bundle, so the test-runner agent
  has nothing to run.

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
0. Merge `library-home`, run it on device (TestFlight): import from Files/iCloud,
   Share sheet, open a large capture from the Library.
1. Run the review fixes on device: nudge arrows, drop line on
   table vs floor, background then resume with a placed splat, a large
   capture for culling pop-in.
2. Confirm SPZ and `.splat` loading (may already be covered by the device run).
3. Fix the stale docs listed under Known issues.
4. Fix the truncated-PLY hang.
5. Then ROADMAP Build order step 3 (Settings); add the Home settings entry.

## Open questions
- Is the App Store name "Lustre" reserved? (Every build upload resets the
  90-day clock.)
- Which iPhone is the device target? Which formats were in the ~10 test splats?
- Keep SOG in the picker with its specific error, or hide it until there's a
  decoder?
- Add a unit test target now (Core math, SplatIO, and `SplatFileNaming` are
  easy wins), or wait?
- `SplatLibrary` scans the folder synchronously on the main actor (init,
  foreground, after mutations). Fine at tens of files; revisit if Capture
  makes libraries large.
