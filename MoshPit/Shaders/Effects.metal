#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Post-canvas effect chain — ports of other Signal Culture app ideas.
// Each kernel reads `input` and writes `output`; the CPU ping-pongs them in
// the user-ordered chain. All run at canvas resolution.
// ============================================================================

static inline float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

// ---------------------------------------------------------------------------
// Frame Buffer / Echo: ring buffer of past canvas frames (texture2d_array),
// keyed layering — the pixel's luma selects which history layer shows through.
// ---------------------------------------------------------------------------
struct EchoUniforms {
    int   layers;      // how many history slices to consider
    int   head;        // ring buffer write head (most recent slice)
    float keyLow, keyHigh;
};

kernel void echoEffect(texture2d<float, access::sample>       input  [[texture(0)]],
                       texture2d<float, access::write>        output [[texture(1)]],
                       texture2d_array<float, access::sample> ring   [[texture(2)]],
                       constant EchoUniforms& u                      [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 now = input.sample(s, uv).rgb;

    // Luma inside [keyLow, keyHigh] maps to a history layer: darker keys reach
    // further back in time. Outside the key band the live frame shows.
    float l = luma(now);
    float k = smoothstep(u.keyLow, u.keyHigh, l);
    if (l < u.keyLow || l > u.keyHigh) { output.write(float4(now, 1.0), gid); return; }

    int nSlices = int(ring.get_array_size());
    int depth = clamp(int((1.0 - k) * float(u.layers - 1)) + 1, 1, u.layers - 1);
    int slice = ((u.head - depth) % nSlices + nSlices) % nSlices;
    float3 past = ring.sample(s, uv, slice).rgb;
    output.write(float4(mix(now, past, 0.85), 1.0), gid);
}

// Copies the chain input into the ring buffer slice at the write head.
kernel void echoStore(texture2d<float, access::sample>      input [[texture(0)]],
                      texture2d_array<float, access::write> ring  [[texture(1)]],
                      constant int& head                          [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= ring.get_width() || gid.y >= ring.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(ring.get_width(), ring.get_height());
    ring.write(float4(input.sample(s, uv).rgb, 1.0), gid, head);
}

// ---------------------------------------------------------------------------
// SSSScan slitscan: per-pixel time displacement into the same ring buffer.
// The scan gradient is either luma of source B or a generated angled ramp;
// speed scrolls the gradient, scrub offsets the whole buffer read.
// ---------------------------------------------------------------------------
struct SlitscanUniforms {
    int   head;
    int   depth;          // usable slices
    float phase;          // accumulated speed * time
    float angle;          // ramp direction
    float scrub;          // 0..1 manual buffer offset
    int   useSourceB;     // gradient from B luma instead of ramp
    float pad0, pad1;
};

kernel void slitscanEffect(texture2d<float, access::sample>       input   [[texture(0)]],
                           texture2d<float, access::write>        output  [[texture(1)]],
                           texture2d_array<float, access::sample> ring    [[texture(2)]],
                           texture2d<float, access::sample>       gradTex [[texture(3)]],
                           constant SlitscanUniforms& u                   [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());

    float g;
    if (u.useSourceB) {
        g = luma(gradTex.sample(s, uv).rgb);
    } else {
        // Angled linear ramp across the frame — the "scan shape".
        float2 dir = float2(cos(u.angle), sin(u.angle));
        g = fract(dot(uv - 0.5, dir) + 0.5 + u.phase);
    }
    float t = fract(g + u.scrub + (u.useSourceB ? u.phase : 0.0));
    int nSlices = int(ring.get_array_size());
    int back = clamp(int(t * float(u.depth - 1)), 0, u.depth - 1);
    int slice = ((u.head - back) % nSlices + nSlices) % nSlices;
    float3 c = (back == 0) ? input.sample(s, uv).rgb : ring.sample(s, uv, slice).rgb;
    output.write(float4(c, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Weaver: interleave chain output with source B through a dynamic luminance
// displacement map — B's luma warps the weave boundaries so the two images
// thread through each other.
// ---------------------------------------------------------------------------
struct WeaverUniforms { float amount; float pad0, pad1, pad2; };

kernel void weaverEffect(texture2d<float, access::sample> input  [[texture(0)]],
                         texture2d<float, access::write>  output [[texture(1)]],
                         texture2d<float, access::sample> texB   [[texture(2)]],
                         constant WeaverUniforms& u              [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 size = float2(output.get_width(), output.get_height());
    float2 uv = (float2(gid) + 0.5) / size;

    float lb = luma(texB.sample(s, uv).rgb);
    // Displace the weave phase by B's luminance; amount sets weave pitch.
    float pitch = mix(64.0, 4.0, u.amount);
    float phase = (float(gid.y) + lb * pitch * 2.0) / pitch;
    bool takeB = fract(phase) < 0.5;
    // Also displace the taken texture's sample coordinate for the "threaded" feel.
    float2 shift = float2(lb - 0.5, 0.0) * u.amount * 0.05;
    float3 c = takeB ? texB.sample(s, uv + shift).rgb
                     : input.sample(s, uv - shift).rgb;
    output.write(float4(c, 1.0), gid);
}

// ---------------------------------------------------------------------------
// PXLMSH-lite: pixel "sorting" along luma-keyed spans. True sorting is
// O(n log n) per span; this lite version smears each masked pixel toward the
// span position its luma ranks at — visually equivalent streaks at 60 fps.
// ---------------------------------------------------------------------------
struct PixelSortUniforms {
    float threshold;
    int   vertical;    // sort direction
    float pad0, pad1;
};

kernel void pixelSortEffect(texture2d<float, access::sample> input  [[texture(0)]],
                            texture2d<float, access::write>  output [[texture(1)]],
                            constant PixelSortUniforms& u           [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::nearest);
    float2 pos = float2(gid);
    float3 me = input.sample(s, pos).rgb;
    float lm = luma(me);
    if (lm < u.threshold) { output.write(float4(me, 1.0), gid); return; }

    float2 dir = u.vertical ? float2(0.0, 1.0) : float2(1.0, 0.0);
    // Walk to the span edge (up to 48 px) while pixels stay above threshold.
    const int kMax = 48;
    int spanUp = 0, spanDown = 0;
    for (int i = 1; i <= kMax; i++) {
        if (luma(input.sample(s, pos - dir * float(i)).rgb) < u.threshold) break;
        spanUp = i;
    }
    for (int i = 1; i <= kMax; i++) {
        if (luma(input.sample(s, pos + dir * float(i)).rgb) < u.threshold) break;
        spanDown = i;
    }
    float span = float(spanUp + spanDown);
    if (span < 2.0) { output.write(float4(me, 1.0), gid); return; }
    // Rank-by-luma approximation: bright pixels migrate to the span start.
    float target = (1.0 - (lm - u.threshold) / max(1e-4, 1.0 - u.threshold)) * span;
    float2 srcPos = pos - dir * float(spanUp) + dir * target;
    output.write(float4(input.sample(s, srcPos).rgb, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Proc-Amp: brightness / contrast / saturation / hue / gamma on final output.
// ---------------------------------------------------------------------------
struct ProcAmpUniforms {
    float brightness, contrast, saturation, hue, gamma;
    float pad0, pad1, pad2;
};

kernel void procAmpEffect(texture2d<float, access::sample> input  [[texture(0)]],
                          texture2d<float, access::write>  output [[texture(1)]],
                          constant ProcAmpUniforms& u             [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::nearest);
    float3 c = input.sample(s, float2(gid)).rgb;
    c = (c - 0.5) * u.contrast + 0.5 + u.brightness;
    float l = luma(c);
    c = mix(float3(l), c, u.saturation);
    if (u.hue != 0.0) {
        const float3x3 toYIQ = float3x3(float3(0.299,  0.596,  0.211),
                                        float3(0.587, -0.274, -0.523),
                                        float3(0.114, -0.322,  0.312));
        const float3x3 toRGB = float3x3(float3(1.0,  1.0,  1.0),
                                        float3(0.956, -0.272, -1.106),
                                        float3(0.621, -0.647,  1.703));
        float3 yiq = toYIQ * c;
        float ca = cos(u.hue), sa = sin(u.hue);
        yiq.yz = float2x2(float2(ca, sa), float2(-sa, ca)) * yiq.yz;
        c = toRGB * yiq;
    }
    c = pow(clamp(c, 0.0, 1.0), float3(1.0 / max(0.05, u.gamma)));
    output.write(float4(c, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Finisher: mirror + color modes, one pass AFTER the whole effect chain and
// BEFORE the preview blit / recorder / NDI / MJPEG taps — what you see is
// what you record. UV math mirrors FinisherMath.mirroredUV (unit-tested).
// ---------------------------------------------------------------------------
struct FinisherUniforms {
    int   mirrorMode;        // 0 none, 1 horizontal, 2 vertical, 3 quad
    int   mirrorRightToLeft; // horizontal: reflect the right half instead
    int   colorMode;         // 0 none, 1 invert, 2 duotone, 3 hue shift
    float shadowHue;         // degrees, duotone
    float highlightHue;      // degrees, duotone
    float hueShift;          // degrees, hue-shift mode
    float pad0, pad1;
};

// Full-saturation hue wheel (degrees) -> RGB, matches FinisherMath.hueToRGB.
static inline float3 hueWheel(float deg) {
    float h = fmod(fmod(deg, 360.0) + 360.0, 360.0) / 60.0;
    float x = 1.0 - fabs(fmod(h, 2.0) - 1.0);
    if (h < 1.0) return float3(1, x, 0);
    if (h < 2.0) return float3(x, 1, 0);
    if (h < 3.0) return float3(0, 1, x);
    if (h < 4.0) return float3(0, x, 1);
    if (h < 5.0) return float3(x, 0, 1);
    return float3(1, 0, x);
}

kernel void finisherPass(texture2d<float, access::sample> input  [[texture(0)]],
                         texture2d<float, access::write>  output [[texture(1)]],
                         constant FinisherUniforms& u            [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());

    // Mirror: fold the sample coordinate back into the kept half/quadrant.
    if (u.mirrorMode == 1) {
        uv.x = u.mirrorRightToLeft ? max(uv.x, 1.0 - uv.x) : min(uv.x, 1.0 - uv.x);
    } else if (u.mirrorMode == 2) {
        uv.y = min(uv.y, 1.0 - uv.y);
    } else if (u.mirrorMode == 3) {
        uv = min(uv, 1.0 - uv);   // four quadrants of the top-left quadrant
    }
    float3 c = input.sample(s, uv).rgb;

    if (u.colorMode == 1) {                       // invert
        c = 1.0 - clamp(c, 0.0, 1.0);
    } else if (u.colorMode == 2) {                // duotone: luma -> 2-color ramp
        c = mix(hueWheel(u.shadowHue), hueWheel(u.highlightHue), luma(clamp(c, 0.0, 1.0)));
    } else if (u.colorMode == 3) {                // hue shift (YIQ rotation)
        const float3x3 toYIQ = float3x3(float3(0.299,  0.596,  0.211),
                                        float3(0.587, -0.274, -0.523),
                                        float3(0.114, -0.322,  0.312));
        const float3x3 toRGB = float3x3(float3(1.0,  1.0,  1.0),
                                        float3(0.956, -0.272, -1.106),
                                        float3(0.621, -0.647,  1.703));
        float rad = u.hueShift * (M_PI_F / 180.0);
        float3 yiq = toYIQ * c;
        float ca = cos(rad), sa = sin(rad);
        yiq.yz = float2x2(float2(ca, sa), float2(-sa, ca)) * yiq.yz;
        c = toRGB * yiq;
    }
    output.write(float4(c, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Utility: blit/scale any texture into another (used for preview, recorder,
// and BGRA conversion for CVPixelBuffer-backed targets).
// ---------------------------------------------------------------------------
kernel void blitScale(texture2d<float, access::sample> input  [[texture(0)]],
                      texture2d<float, access::write>  output [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    output.write(float4(input.sample(s, uv).rgb, 1.0), gid);
}

// Fullscreen textured quad for on-screen preview (MTKView render pass).
// The uv transform implements aspect-fill (uvScale < 1: center-crop) or
// aspect-fit (uvScale > 1: letterbox — out-of-range uv renders black).
struct QuadOut { float4 pos [[position]]; float2 uv; };
struct PreviewUniforms { float2 uvScale; };

vertex QuadOut previewVertex(uint vid [[vertex_id]],
                             constant PreviewUniforms& u [[buffer(0)]]) {
    float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    QuadOut o;
    o.pos = float4(p[vid], 0, 1);
    float2 uv = p[vid] * float2(0.5, -0.5) + 0.5;
    o.uv = (uv - 0.5) * u.uvScale + 0.5;   // centered crop/expand
    return o;
}

fragment float4 previewFragment(QuadOut in [[stage_in]],
                                texture2d<float, access::sample> tex [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    if (any(in.uv < 0.0) || any(in.uv > 1.0)) return float4(0, 0, 0, 1); // letterbox
    return float4(tex.sample(s, in.uv).rgb, 1.0);
}

// Targeted GPU-side rotation for camera frames when physical rotation fails.
// Rotates 90 degrees clockwise and handles front-camera mirroring.
kernel void cameraRotate(texture2d<float, access::sample> input  [[texture(0)]],
                         texture2d<float, access::write>  output [[texture(1)]],
                         constant int& mirror                    [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float2 rotUV = mirror ? float2(uv.y, 1.0 - uv.x) : float2(1.0 - uv.y, uv.x);
    
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    output.write(float4(input.sample(s, rotUV).rgb, 1.0), gid);
}
