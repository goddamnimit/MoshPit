#include <metal_stdlib>
using namespace metal;

// ============================================================================
// MoshPit core shaders: block-matching motion estimation + the mosh canvas.
//
// The aesthetic of codec datamoshing comes from decoding P-frames (motion
// vectors + residuals) against the WRONG reference frame after an I-frame is
// deleted. We reproduce that by keeping a persistent canvas that is never
// cleared: every frame we estimate motion between consecutive SOURCE frames,
// then re-sample the CANVAS through that motion field. Real pixels only enter
// the canvas under mode-specific rules — exactly the role of I-frames/residual
// data in a real bitstream.
// ============================================================================

struct MoshUniforms {
    int     mode;               // MoshMode raw value
    int     smoothVectors;      // 0 = nearest (blocky), 1 = bilinear
    int     driftReplaces;      // drift replaces (1) or adds to (0) estimate
    int     crossMosh;          // sample fresh pixels from source B
    float2  drift;              // px/frame at canvas scale
    float   motionGain;
    float   heal;               // 0..0.02 fresh-frame leak (anti-collapse)
    float   mixAmount;          // Mix Mosh wet/dry
    float   bloomThreshold;     // motion magnitude gate (canvas px/frame)
    float   bloomGate;          // 1 while a bloom pulse admits pixels
    float   fbZoom, fbRotate;   // feedback transform per frame
    float2  fbOffset;
    float   fbHue;              // hue rotation radians per pass
    float2  canvasSize;
    float2  flowScale;          // canvas px per flow TEXEL (uv mapping)
    int     hasSource;          // source A texture bound & fresh
    int     hasSourceB;
    float2  vectorScale;        // canvas px per estimation-res px (magnitude)
    float2  bFit;               // aspect-fit uv scale for source B (>= 1)
};

// A live bloom region for Timed Multi-Directional Bloom. Several can be alive
// simultaneously, each with its own direction bias and lifetime envelope.
struct BloomRegion {
    float2 bias;       // direction bias added to the motion field (canvas px)
    float  strength;   // 0..1 envelope (decays over the region's lifetime)
    float  active;     // >0.5 while alive
};
constant int kMaxBlooms = 8;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static inline float lumaOf(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

// Hue rotation via YIQ rotation matrix — cheap and stable for feedback loops.
static inline float3 hueRotate(float3 c, float a) {
    if (a == 0.0) return c;
    const float3x3 toYIQ = float3x3(float3(0.299,  0.596,  0.211),
                                    float3(0.587, -0.274, -0.523),
                                    float3(0.114, -0.322,  0.312));
    const float3x3 toRGB = float3x3(float3(1.0,  1.0,  1.0),
                                    float3(0.956, -0.272, -1.106),
                                    float3(0.621, -0.647,  1.703));
    float3 yiq = toYIQ * c;
    float ca = cos(a), sa = sin(a);
    yiq.yz = float2x2(float2(ca, sa), float2(-sa, ca)) * yiq.yz;
    return toRGB * yiq;
}

// Sample the flow field for a canvas pixel. Nearest keeps macroblock edges
// hard (the classic chunky MPEG look); bilinear gives a smooth melt.
static inline float2 sampleFlow(texture2d<float, access::sample> flow,
                                float2 canvasPos, float2 flowScale,
                                float2 vectorScale, int smooth) {
    constexpr sampler sNear(coord::normalized, address::clamp_to_edge, filter::nearest);
    constexpr sampler sLin (coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = canvasPos / (float2(flow.get_width(), flow.get_height()) * flowScale);
    float2 v = smooth ? flow.sample(sLin, uv).xy : flow.sample(sNear, uv).xy;
    // Vectors are stored in estimation-res pixels; rescale to canvas pixels.
    // Nearest-sampled at macroblock granularity = the chunky upscaled look.
    return v * vectorScale;
}

// ---------------------------------------------------------------------------
// Block-matching motion estimation (16x16-style macroblock SAD search).
// One thread per macroblock. Searches a ±rangePx window in `prev` for the
// best match of the block in `cur`, sampling every other pixel for speed.
// Output: one float2 texel per block, in estimation-resolution pixels,
// oriented so cur(x) ≈ prev(x - v)  (backward warp convention).
// ---------------------------------------------------------------------------

struct BlockMatchUniforms {
    int blockSize;   // 4 / 8 / 16 / 32
    int searchRange; // px
    int step;        // search stride in px (1 = exhaustive)
    int pad;
};

kernel void blockMatch(texture2d<float, access::sample> cur   [[texture(0)]],
                       texture2d<float, access::sample> prev  [[texture(1)]],
                       texture2d<float, access::write>  flow  [[texture(2)]],
                       constant BlockMatchUniforms& u          [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= flow.get_width() || gid.y >= flow.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::nearest);

    const int bs = u.blockSize;
    const float2 origin = float2(gid) * float(bs);
    // Sample the block sparsely (every 2px for bs>=8) — SAD ranking barely
    // changes and it quarters the cost.
    const int stride = max(1, bs / 8);

    float bestSAD = INFINITY;
    float2 bestV = float2(0.0);
    for (int dy = -u.searchRange; dy <= u.searchRange; dy += u.step) {
        for (int dx = -u.searchRange; dx <= u.searchRange; dx += u.step) {
            float sad = 0.0;
            for (int y = 0; y < bs; y += stride) {
                for (int x = 0; x < bs; x += stride) {
                    float2 p = origin + float2(x, y);
                    float3 a = cur.sample(s, p).rgb;
                    float3 b = prev.sample(s, p - float2(dx, dy)).rgb;
                    sad += abs(lumaOf(a) - lumaOf(b));
                }
            }
            // Zero-motion bias: prefer stillness on ties so noise doesn't jitter.
            sad += 0.001 * length(float2(dx, dy));
            if (sad < bestSAD) { bestSAD = sad; bestV = float2(dx, dy); }
        }
    }
    flow.write(float4(bestV, 0.0, 0.0), gid);
}

// ---------------------------------------------------------------------------
// The mosh kernel: one pass, all modes. Reads the previous canvas (ping) and
// writes the next (pong). The canvas is NEVER cleared while moshing.
// ---------------------------------------------------------------------------

kernel void moshCanvas(texture2d<float, access::sample> prevCanvas [[texture(0)]],
                       texture2d<float, access::write>  nextCanvas [[texture(1)]],
                       texture2d<float, access::sample> sourceA    [[texture(2)]],
                       texture2d<float, access::sample> sourceB    [[texture(3)]],
                       texture2d<float, access::sample> flow       [[texture(4)]],
                       constant MoshUniforms& u                    [[buffer(0)]],
                       constant BloomRegion* blooms                [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= (uint)u.canvasSize.x || gid.y >= (uint)u.canvasSize.y) return;
    constexpr sampler sLin(coord::normalized, address::clamp_to_edge, filter::linear);

    const float2 pos = float2(gid) + 0.5;
    const float2 uv  = pos / u.canvasSize;

    // -- 1. Motion vector for this pixel ------------------------------------
    float2 v = sampleFlow(flow, pos, u.flowScale, u.vectorScale, u.smoothVectors) * u.motionGain;
    float2 estV = v; // keep the raw estimate for bloom gating

    // Drift (mode 3, but the drift vector is honored in every mode so the
    // joystick works as a live "wind" on top of any mosh).
    if (u.driftReplaces) { v = u.drift; } else { v += u.drift; }

    // Timed multi-directional bloom: each live region biases the field.
    float bloomBiasMag = 0.0;
    if (u.mode == 2) {
        for (int i = 0; i < kMaxBlooms; i++) {
            if (blooms[i].active > 0.5) {
                v += blooms[i].bias * blooms[i].strength;
                bloomBiasMag += length(blooms[i].bias) * blooms[i].strength;
            }
        }
    }

    // -- 2. Feedback transform (mode 6): move the canvas itself each frame --
    float2 samplePos = pos;
    if (u.mode == 6) {
        float2 c = u.canvasSize * 0.5;
        float2 d = samplePos - c;
        float ca = cos(-u.fbRotate), sa = sin(-u.fbRotate);
        d = float2x2(float2(ca, sa), float2(-sa, ca)) * d;
        d /= (1.0 + u.fbZoom);
        samplePos = c + d - u.fbOffset * u.canvasSize;
    }

    // -- 3. The P-frame smear: sample previous canvas displaced by -v -------
    float2 warpedUV = (samplePos - v) / u.canvasSize;
    float3 smear = prevCanvas.sample(sLin, warpedUV).rgb;
    if (u.mode == 6) smear = hueRotate(smear, u.fbHue);

    // -- 4. Fresh pixel admission rules per mode -----------------------------
    // Cross-mosh admits pixels from B while motion still comes from A.
    float3 fresh = smear;
    bool haveFresh = false;
    if ((u.mode == 5 || u.crossMosh) && u.hasSourceB) {
        // B may have a different aspect than the (A-shaped) canvas: FIT it,
        // clamping edges — never stretch either source.
        float2 uvB = (uv - 0.5) * u.bFit + 0.5;
        fresh = sourceB.sample(sLin, uvB).rgb; haveFresh = true;
    } else if (u.hasSource) {
        fresh = sourceA.sample(sLin, uv).rgb; haveFresh = true;
    }

    float admit = 0.0;
    switch (u.mode) {
        case 0: // Classic Smear — no new pixels, ever. Pure deleted-I-frame.
            admit = 0.0; break;
        case 1: // Bloom — when the pulse fires, moving regions take new detail.
        case 2: // Timed bloom — same gate, plus the directional bias above.
            if (u.bloomGate > 0.5 &&
                (length(estV) + bloomBiasMag) > u.bloomThreshold) admit = 1.0;
            break;
        case 3: admit = 0.0; break;                    // Drift: smear only
        case 4: admit = u.mixAmount; break;            // Mix Mosh wet/dry
        case 5: admit = 0.0; break;                    // Cross-mosh: smear of B
        case 6: admit = 0.0; break;                    // Feedback: smear only
    }
    if (!haveFresh) admit = 0.0;

    float3 outC = mix(smear, fresh, admit);

    // -- 5. Stability: heal leak + clamp so the float canvas can run forever.
    if (u.heal > 0.0 && haveFresh) outC = mix(outC, fresh, u.heal);
    outC = clamp(outC, 0.0, 1.0);

    nextCanvas.write(float4(outC, 1.0), gid);
}

// Manual I-frame: copy the current source into the canvas (Reset button).
kernel void resetCanvas(texture2d<float, access::sample> source [[texture(0)]],
                        texture2d<float, access::write>  canvas [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= canvas.get_width() || gid.y >= canvas.get_height()) return;
    constexpr sampler sLin(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(canvas.get_width(), canvas.get_height());
    canvas.write(float4(source.sample(sLin, uv).rgb, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Motion statistics reduction (HUD + video-as-controller).
// Accumulates |v|, v, and source luma into fixed-point atomics.
// buffer layout: [sumMag, sumVx, sumVy, count, sumLuma, lumaCount]
// ---------------------------------------------------------------------------

kernel void motionStats(texture2d<float, access::sample> flow [[texture(0)]],
                        texture2d<float, access::sample> src  [[texture(1)]],
                        device atomic_uint* acc               [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::nearest);
    if (gid.x < flow.get_width() && gid.y < flow.get_height()) {
        float2 v = flow.sample(s, float2(gid)).xy;
        atomic_fetch_add_explicit(&acc[0], uint(length(v) * 256.0), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[1], uint((v.x + 64.0) * 256.0), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[2], uint((v.y + 64.0) * 256.0), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[3], 1u, memory_order_relaxed);
    }
    if (gid.x < src.get_width() / 8 && gid.y < src.get_height() / 8) {
        float3 c = src.sample(s, float2(gid * 8)).rgb;
        atomic_fetch_add_explicit(&acc[4], uint(lumaOf(c) * 256.0), memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[5], 1u, memory_order_relaxed);
    }
}
