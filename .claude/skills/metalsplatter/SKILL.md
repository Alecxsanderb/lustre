---
name: metalsplatter
description: MetalSplatter and splat-format specifics for Lustre — the render loop, SplatChunk/SplatPoint APIs, PLY/SPZ/.splat loading, coordinate conventions, and the iOS 18 constraint. Use when touching Viewer/Rendering, Services/SplatIO, splat file import/export, the MTKView draw path, or anything involving splat counts, sorting, or GPU buffers.
---

# MetalSplatter in Lustre

Full integration notes, including what is and isn't verified, live in
`Lustre/Viewer/INTEGRATION.md`. Read that before changing the render path.

## Dependency facts

- SPM: `https://github.com/scier/MetalSplatter.git`, `upToNextMajorVersion`
  from **1.0.1**. Products linked: `MetalSplatter` (renderer), `SplatIO`
  (formats). Pulls in `spz-swift` and `swift-argument-parser` transitively.
- **This is why the project is iOS 18.0.** 1.0.x declares `.iOS(.v18)`; the
  oldest tag (0.1.1) needs iOS 17. No version runs on iOS 16. Don't "fix" the
  deployment target back down.
- `fatalError`s on x86_64. Fine on Apple Silicon (the Simulator runs arm64),
  impossible on an Intel Mac.

## Name collision

`Lustre.SplatRenderer` **shadows** `MetalSplatter.SplatRenderer`. In app code
the unqualified name is always Lustre's `MTKViewDelegate`; the library's type is
always written out as `MetalSplatter.SplatRenderer`. Keep that discipline or the
file becomes unreadable.

## Frame path

1. `MTKView` calls `draw(in:)` at display rate.
2. `advanceClock()` hands the pose provider real elapsed time, so movement is
   frame-rate independent.
3. View matrix is `poseProvider.pose.viewMatrix * sceneState.modelMatrix`.
   MetalSplatter takes only view + projection — there is no model-matrix
   parameter, so placement must be folded into the view matrix.
4. Projection comes from `poseProvider.projectionMatrix(...)` when the provider
   has real intrinsics (ARKit does), else `perspectiveProjection` built from
   `verticalFieldOfView`.
5. `render(...)` returns `false` when it declined to draw. Drop the frame —
   don't present it, or you show a half-sorted image.

Pixel formats are fixed at renderer construction (`bgra8Unorm_srgb`,
`depth32Float`, `sampleCount: 1`). `SplatRenderer.configure(_:)` must set the
same values on the `MTKView` before the first draw or rendering fails.

`maxViewCount: 1` is deliberate — Lustre is monoscopic iPhone AR. The library
supports 2 for stereo; that's the visionOS path and out of scope. It also sets
`maxVertexAmplificationCount`, so 1 neutralizes the shaders' `amplification_id`.
The shaders are package resources of the dependency — you can't edit them
without vendoring, and you don't need to.

**Pass `highQualityDepth: false`.** It defaults to `true` and exists, per the
library's own comment, for "reducing artifacts during Vision Pro's frame
reprojection." It gates `useMultiStagePipeline` (a 3-stage imageblock
tile-memory path the library says "takes longer"). Monoscopic iPhone has no
reprojection, so the default is pure cost. Note `useMultiStagePipeline` is
hardcoded `false` in the simulator, so the device pipeline differs from the one
you just tested.

**The splat pass always clears.** `colorAttachments[0].loadAction = .clear` is
hardcoded (`SplatRenderer.swift:711`) and `clearColor` is `public let`. Splats
therefore cannot composite over anything already in the target — camera
passthrough renders splats offscreen and composites in a second pass. See
`PassthroughCompositor` and INTEGRATION.md §3.

**No depth testing.** `depthCompareFunction = .always` on every pipeline
variant. Depth is written (`writeDepth = depthFormat != .invalid`) but never
tested, so splats draw over everything and real-world occlusion does not come
for free.

What the written depth actually contains depends on `highQualityDepth`:

- `false` (what Lustre passes): the single-stage fragment shader emits no depth,
  so the buffer holds the rasterizer's interpolated `z` of the *last* fragment
  written — with back-to-front order, the **nearest splat quad**. Usable as a
  conservative occlusion signal, which is what `PassthroughCompositor` does, but
  it's one sample standing in for a translucent column.
- `true`: the multi-stage path computes an alpha-weighted mean depth
  (`MultiStageRenderPath.metal`), which is what you'd actually want for
  occlusion — and is slower, and exists for Vision Pro reprojection.

Full scene occlusion still needs `ARFrame.sceneDepth`; that's Phase 3.

## Key APIs

```swift
// Loading a file
let points = try await AutodetectSceneReader(url).readAll()   // [SplatPoint]
let chunk  = try SplatChunk(device: device, from: points)
await renderer.addChunk(chunk)                                 // async
await renderer.removeAllChunks()
```

- `SplatPoint(position:color:opacity:scale:rotation:)`. `color` is
  `.sphericalHarmonicFloat([SIMD3<Float>])` or `.sRGBUInt8`; `opacity` is
  `.logitFloat` / `.linearFloat` / `.linearUInt8`; `scale` is `.exponent` or
  `.linearFloat`.
- sRGB → SH0 is `(srgb - 0.5) / 0.28209479177387814`. The library's own
  conversion isn't public, so `SampleSplatScene` mirrors it.
- The `read(from:)` / `add(_:)` convenience methods are **deprecated**. Use
  `SplatChunk` + `addChunk` instead.
- Chunk mutation is `async` and invalidates the sort. `isReadyToRender` gates
  drawing.

## Coordinate convention — the up-calibration trap

3DGS PLY captures are conventionally authored **Y-down**, so files need a 180°
roll about Z. `SampleSplatScene` is authored **Y-up** in our own coordinates and
must NOT get that correction. Hence `SplatSceneState.appliesUpCalibration` is a
per-scene flag, not a constant, and the controls overlay exposes it — the
convention isn't universal and some files need the opposite.

## Performance

The procedural sample is ~12k splats and tells you nothing about real
performance. Actual captures are 1–5M splats, which is where sort cost and
memory pressure appear. `readAll()` blocks on the whole file. Parse off the
main actor — a multi-megabyte PLY on the main thread drops frames.

### Chunk culling — the two things that surprise people

`setChunkEnabled(_:enabled:)` is public and **sort-neutral**: the library's own
comment says disabled chunks keep participating in sorting and the flag takes
effect through the GPU chunk table on the next `render()`. So:

- Culling saves **rasterization only**. The CPU sort still walks every splat in
  every chunk. Fewer splats on screen does not make the sort cheaper — only
  loading fewer splats does (`SplatQuality`).
- The reason to pace toggling is **not** sort invalidation. It's that
  `setChunkEnabled` goes through `withChunkAccess`, which waits for in-flight
  renders to drain and makes `isReadyToRender` false while it waits — so
  `draw(in:)` drops frames for as long as a request is pending. `SplatChunkCuller`
  therefore re-evaluates only after real camera movement and batches every
  change into one `withChunkAccess` (it's reentrant, so nested
  `setChunkEnabled` calls are free).

There is still **no early-out in the fragment shaders** — no transmittance
cutoff, only a behind-camera cull. Adding one means vendoring the package.
