//
//  Gizmo.metal
//  Lustre
//
//  Flat coloured lines for the placement indicators: axis bars at the splat's
//  center, a drop line to the surface below it, and outlines of detected
//  planes.
//
//  Deliberately no depth test — these exist to tell you where the splat *is*,
//  which is least obvious when it's buried inside geometry.
//

#include <metal_stdlib>
using namespace metal;

struct GizmoVertexIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};

struct GizmoVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex GizmoVertexOut gizmoVertex(GizmoVertexIn in [[stage_in]],
                                  constant float4x4 &viewProjection [[buffer(1)]]) {
    GizmoVertexOut out;
    out.position = viewProjection * float4(in.position, 1.0);
    out.color = in.color;
    return out;
}

fragment float4 gizmoFragment(GizmoVertexOut in [[stage_in]]) {
    // Premultiplied, to match the blend state the pass is configured with.
    return float4(in.color.rgb * in.color.a, in.color.a);
}
