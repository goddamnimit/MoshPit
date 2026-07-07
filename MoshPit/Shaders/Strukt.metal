#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Strukt: temporal strobe pass (after Signal Culture's Re:Struktr).
// Final stage before output. CPU-side LFOs decide per frame whether to
// (a) hard-cut to source B, (b) invert colors, (c) flash to black/white.
// The flicker limiter lives on the CPU (StruktEngine) where gate transitions
// are rate-capped; this pass just applies the decided state.
// ============================================================================

struct StruktUniforms {
    int   flip;        // 1 = show raw source B instead of the chain output
    int   invert;
    float flash;       // 0..1
    int   flashWhite;  // flash color: 0 black, 1 white
    int   hasSourceB;
    int   pad0, pad1, pad2;
};

kernel void struktPass(texture2d<float, access::sample> input   [[texture(0)]],
                       texture2d<float, access::write>  output  [[texture(1)]],
                       texture2d<float, access::sample> sourceB [[texture(2)]],
                       constant StruktUniforms& u               [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());

    float3 c = (u.flip && u.hasSourceB) ? sourceB.sample(s, uv).rgb
                                        : input.sample(s, uv).rgb;
    if (u.invert) c = 1.0 - c;
    c = mix(c, float3(u.flashWhite ? 1.0 : 0.0), u.flash);
    output.write(float4(c, 1.0), gid);
}

// ============================================================================
// Mixer wipes (Stage 4, after Signal Culture's Video Mixer).
// PRE-canvas: blends sources A/B into the frame that FEEDS the mosh engine,
// so wipes themselves get moshed.
//   mode 0: plain crossfade
//   mode 1: luma wipe — a threshold sweeps the wipe-luma image so bright
//           areas transition first; softness feathers the edge
//   mode 2: mask wipe — MOD luma directly keys A vs B
// ============================================================================

struct WipeUniforms {
    float crossfade;   // 0 = full A, 1 = full B
    float softness;
    int   mode;
    int   hasMask;     // mask/luma texture bound
    float2 bFit;       // aspect-fit uv scale for B (never stretch)
    float2 maskFit;    // aspect-fit uv scale for the mask/luma source
};

static inline float wipeLuma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

kernel void mixWipe(texture2d<float, access::sample> inA   [[texture(0)]],
                    texture2d<float, access::sample> inB   [[texture(1)]],
                    texture2d<float, access::sample> lumaT [[texture(2)]],
                    texture2d<float, access::write>  out   [[texture(3)]],
                    constant WipeUniforms& u               [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(out.get_width(), out.get_height());

    float3 a = inA.sample(s, uv).rgb;
    float3 b = inB.sample(s, (uv - 0.5) * u.bFit + 0.5).rgb;
    float2 uvM = (uv - 0.5) * u.maskFit + 0.5;
    float t;
    if (u.mode == 1 && u.hasMask) {
        // Threshold sweep: crossfade 0..1 maps to a threshold moving through
        // luma so bright regions flip to B first (see wipeThreshold() mirror
        // in Swift, unit-tested).
        float l = wipeLuma(lumaT.sample(s, uvM).rgb);
        float soft = max(0.001, u.softness);
        float edge = 1.0 + soft - u.crossfade * (1.0 + 2.0 * soft);
        t = smoothstep(edge - soft, edge + soft, l);
    } else if (u.mode == 2 && u.hasMask) {
        float l = wipeLuma(lumaT.sample(s, uvM).rgb);
        float soft = max(0.001, u.softness);
        t = smoothstep(0.5 - soft, 0.5 + soft, l) * u.crossfade * 2.0;
        t = clamp(t, 0.0, 1.0);
    } else {
        t = u.crossfade;
    }
    out.write(float4(mix(a, b, t), 1.0), gid);
}
