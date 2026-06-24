#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen triangle strip — no vertex buffer needed, positions are
// derived from vertex_id, which is the standard trick for full-screen
// post-process passes like this.
vertex VertexOut karaoke_bg_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1)
    };
    VertexOut out;
    float2 p = positions[vertexID];
    out.position = float4(p, 0, 1);
    // Flip Y for UV since Metal's clip space Y is opposite texture-space Y.
    out.uv = float2((p.x + 1) * 0.5, 1.0 - (p.y + 1) * 0.5);
    return out;
}

// Simplex-noise-ish value noise (a cheap 2D gradient noise approximation —
// not bit-identical to true simplex noise, but produces the same kind of
// smooth, organic-looking field that's all domain warping actually needs;
// a from-scratch simplex implementation would be considerably more code
// for a visual difference that isn't meaningfully perceptible here).
float2 hash22(float2 p) {
    float n = sin(dot(p, float2(41.3, 289.1)));
    return fract(float2(262144.0, 32768.0) * n) * 2.0 - 1.0;
}

float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = dot(hash22(i + float2(0, 0)), f - float2(0, 0));
    float b = dot(hash22(i + float2(1, 0)), f - float2(1, 0));
    float c = dot(hash22(i + float2(0, 1)), f - float2(0, 1));
    float d = dot(hash22(i + float2(1, 1)), f - float2(1, 1));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

struct KaraokeBgParams {
    float time;
    float warpIntensity;  // matches Kawarp's warpIntensity option (0-1)
    float blurRadius;     // approximates blurPasses' visual effect
};

fragment float4 karaoke_bg_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> albumArt [[texture(0)]],
    constant KaraokeBgParams &params [[buffer(0)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

    // Domain warp: offset the sample UV by a slowly-evolving noise field,
    // the same core idea as Kawarp's simplex-noise warping — distorting
    // where we sample from, rather than the pixel colors directly, is
    // what gives the "fluid" look rather than a static blur.
    float2 warpUV = in.uv * 3.0 + float2(params.time * 0.05, params.time * 0.03);
    float2 offset = float2(
        valueNoise(warpUV),
        valueNoise(warpUV + float2(7.3, 2.1))
    ) * params.warpIntensity * 0.08;

    float2 sampleUV = clamp(in.uv + offset, 0.0, 1.0);

    // Multi-tap box blur approximating Kawase-style cheap blur — a real
    // Kawase blur does this via downsample/upsample mip passes for
    // efficiency; this single-pass multi-tap version is simpler to write
    // as a first version and still produces a comparable soft blur look,
    // at the cost of being somewhat less efficient per-pixel than true
    // Kawase blur for the same visual softness.
    float4 color = float4(0);
    const int taps = 8;
    for (int i = 0; i < taps; i++) {
        float angle = (float(i) / float(taps)) * 6.28318;
        float2 tapOffset = float2(cos(angle), sin(angle)) * params.blurRadius;
        color += albumArt.sample(s, sampleUV + tapOffset);
    }
    color /= float(taps);

    return color;
}
