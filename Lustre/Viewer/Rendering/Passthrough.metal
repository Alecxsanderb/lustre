//
//  Passthrough.metal
//  Lustre
//
//  Composites the splat layer over the camera image.
//
//  MetalSplatter hardcodes `loadAction = .clear` on its color attachment, so
//  splats cannot be drawn on top of a camera image already in the drawable.
//  Instead splats render to an offscreen texture and this pass combines them.
//

#include <metal_stdlib>
using namespace metal;

struct FullscreenVertex {
    float4 position [[position]];
    float2 uv;
};

/// Single oversized triangle rather than a quad: no diagonal seam, one fewer
/// vertex, and no vertex buffer to bind.
vertex FullscreenVertex passthroughVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const float2 clip = positions[vertexID];

    FullscreenVertex out;
    out.position = float4(clip, 0.0, 1.0);
    // Clip space is y-up, texture space is y-down.
    out.uv = float2((clip.x + 1.0) * 0.5, 1.0 - (clip.y + 1.0) * 0.5);
    return out;
}

struct PassthroughUniforms {
    // Capture UV -> view UV. float3x3 so the crop and the orientation rotation
    // travel together.
    float3x3 displayTransform;
    // 0 = video range (420v), 1 = full range (420f).
    uint isFullRange;
    uint occlusionEnabled;
    // Must match the projection both depth buffers were rendered with.
    float nearZ;
    float farZ;
    float occlusionBias;
    float occlusionFeather;
    uint padding0;
    uint padding1;
};

/// Turns Metal's [0, 1] window depth back into meters along the view ray.
///
/// Inverse of z = far * (d - near) / (d * (far - near)). Occlusion has to be
/// decided in meters: window depth is wildly non-linear, so a fixed tolerance
/// in depth units would be microscopic up close and enormous across the room.
static float linearDepth(float windowZ, float nearZ, float farZ) {
    const float denominator = farZ - windowZ * (farZ - nearZ);
    return (denominator <= 1e-6) ? farZ : (farZ * nearZ) / denominator;
}

/// BT.601, matching what the camera pipeline produces. Returns *sRGB-encoded*
/// values, which still have to be linearized before compositing.
static float3 ycbcrToSRGB(float luma, float2 chroma, uint isFullRange) {
    float y = luma;
    float2 cbcr = chroma - float2(0.5, 0.5);

    if (isFullRange == 0) {
        // Video range packs luma into 16-235 and chroma into 16-240.
        y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        cbcr *= (255.0 / 224.0);
    }

    return float3(y + 1.402 * cbcr.y,
                  y - 0.344136 * cbcr.x - 0.714136 * cbcr.y,
                  y + 1.772 * cbcr.x);
}

/// The trap: sampling a `_srgb` texture returns linear values and writing to
/// one re-encodes, but the YCbCr transform above yields sRGB-encoded values.
/// Skipping this makes passthrough come out visibly washed out.
static float3 srgbToLinear(float3 c) {
    float3 low = c / 12.92;
    float3 high = pow((c + 0.055) / 1.055, 2.4);
    return select(high, low, c <= 0.04045);
}

fragment float4 passthroughFragment(FullscreenVertex in [[stage_in]],
                                    texture2d<float> splatColor [[texture(0)]],
                                    texture2d<float> lumaPlane  [[texture(1)]],
                                    texture2d<float> chromaPlane [[texture(2)]],
                                    depth2d<float> splatDepth [[texture(3)]],
                                    depth2d<float> occluderDepth [[texture(4)]],
                                    constant PassthroughUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler splatSampler(filter::nearest, address::clamp_to_edge);
    constexpr sampler cameraSampler(filter::linear, address::clamp_to_edge);
    constexpr sampler depthSampler(filter::nearest, address::clamp_to_edge);

    const float2 cameraUV = (uniforms.displayTransform * float3(in.uv, 1.0)).xy;

    const float luma = lumaPlane.sample(cameraSampler, cameraUV).r;
    const float2 chroma = chromaPlane.sample(cameraSampler, cameraUV).rg;
    const float3 cameraLinear = srgbToLinear(saturate(ycbcrToSRGB(luma, chroma, uniforms.isFullRange)));

    // Already linear (sRGB texture) and already premultiplied — the library's
    // blend state is .one / .oneMinusSourceAlpha over a transparent clear.
    float4 splat = splatColor.sample(splatSampler, in.uv);

    if (uniforms.occlusionEnabled != 0) {
        // The splat pass writes depth with `.always` compare over a back-to-
        // front draw order, so this is the depth of the *nearest* splat quad
        // covering the pixel — one value standing in for a whole translucent
        // column. Occlusion is therefore conservative: it hides a pixel only
        // when even the nearest splat there is behind the surface. Splats
        // further back in the same column stay visible.
        const float splatMeters = linearDepth(splatDepth.sample(depthSampler, in.uv),
                                              uniforms.nearZ, uniforms.farZ);
        const float surfaceMeters = linearDepth(occluderDepth.sample(depthSampler, in.uv),
                                                uniforms.nearZ, uniforms.farZ);
        const float behind = splatMeters - surfaceMeters;
        const float hidden = smoothstep(uniforms.occlusionBias,
                                        uniforms.occlusionBias + uniforms.occlusionFeather,
                                        behind);
        // Premultiplied, so scaling all four channels is the correct fade.
        splat *= (1.0 - hidden);
    }

    return float4(splat.rgb + cameraLinear * (1.0 - splat.a), 1.0);
}
