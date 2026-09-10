//
//  Occluder.metal
//  Lustre
//
//  Rasterizes detected real-world surfaces into a depth buffer. Nothing is
//  shaded — the result is consumed by the passthrough composite, which hides
//  splats that sit behind a surface.
//
//  Depth-only, so there is no fragment function at all.
//

#include <metal_stdlib>
using namespace metal;

struct OccluderVertexIn {
    float3 position [[attribute(0)]];
};

vertex float4 occluderVertex(OccluderVertexIn in [[stage_in]],
                             constant float4x4 &viewProjection [[buffer(1)]]) {
    return viewProjection * float4(in.position, 1.0);
}
