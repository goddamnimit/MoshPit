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
    int   gridWarpEnabled;   // 0 off, 1 on
    float gridWarpCellSize;  // grid cells across the short edge
    float gridWarpIntensity; // displacement magnitude, UV units
    float gridWarpLineOpacity; // 0 invisible mesh, 1 fully visible
    float gridWarpPhase;     // accumulated time * animSpeed, drives the field
    int   sheetEnabled;      // 0 off, 1 on — Spreadsheet Mosh Filter
    float sheetCols;         // columns across the frame width
    float sheetRows;         // rows (derived from aspect on the CPU side)
    float sheetChromeOpacity;   // blend raw mosaic <-> full chrome overlay
    float sheetLineOpacity;     // gridline visibility within the chrome
    float sheetSelPhase;        // accumulated time * selectionSpeed, in cells
    int   sheetRevealMode;      // 0 full grid, 1 sequential wipe, 2 random
    int   hudEnabled;           // 0 off, 1 on — Tracking HUD Overlay
    float hudPointCount;        // tracked points drawn (density)
    float hudLabelDensity;      // fraction of points with coordinate text
    float hudLineOpacity;       // sparse connecting-mesh visibility
    float hudHue;               // overlay hue, degrees (hueWheel)
    float pad0, pad1;
};

// Cheap 2D hash -> [0,1), used as the procedural per-cell displacement field
// for Grid-Mesh Glitch Warp (no texture asset — pure in-shader noise).
static inline float gridWarpHash(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Sample one glyph from the 37-slot atlas (0-9, A-Z, then ':'; single row,
// baked on the CPU at FinisherPass init). `luv` is the glyph-local uv.
static inline float sheetGlyphAlpha(texture2d<float, access::sample> atlas,
                                    sampler s, int glyph, float2 luv) {
    if (luv.x < 0.0 || luv.x > 1.0 || luv.y < 0.0 || luv.y > 1.0) return 0.0;
    // CoreGraphics bakes bottom-up; flip v so glyphs read upright.
    return atlas.sample(s, float2((float(glyph) + luv.x) / 37.0, 1.0 - luv.y)).a;
}

// Stable scatter position for tracking-HUD point `i` (uv, inset from edges).
static inline float2 hudPointBase(float i) {
    return float2(gridWarpHash(float2(i * 1.618, 7.3)),
                  gridWarpHash(float2(i * 2.113, 41.9))) * 0.92 + 0.04;
}

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
                         texture2d<float, access::sample> glyphs [[texture(2)]],
                         texture2d<float, access::sample> flow   [[texture(3)]],
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

    float gridLine = 0.0;
    if (u.gridWarpEnabled != 0) {
        float cells = max(1.0, u.gridWarpCellSize);
        float2 cellUV = uv * cells;
        float2 cellId = floor(cellUV);
        float2 cellFrac = fract(cellUV);

        // Per-cell procedural displacement: two hashed scalars (x/y) walked
        // forward by the animated phase, so each cell drifts independently.
        float2 seed = cellId + u.gridWarpPhase;
        float dx = gridWarpHash(seed) * 2.0 - 1.0;
        float dy = gridWarpHash(seed + float2(19.19, 7.7)) * 2.0 - 1.0;
        uv += float2(dx, dy) * u.gridWarpIntensity;
        uv = clamp(uv, 0.0, 1.0);

        // Mesh line mask: thin bands near each cell's edges, in screen space
        // (independent of the displacement so the mesh reads as an overlay).
        float2 edgeDist = min(cellFrac, 1.0 - cellFrac);
        float lineWidth = 0.04;
        float ex = 1.0 - smoothstep(0.0, lineWidth, edgeDist.x);
        float ey = 1.0 - smoothstep(0.0, lineWidth, edgeDist.y);
        gridLine = max(ex, ey) * u.gridWarpLineOpacity;
    }

    // Spreadsheet mosaic quantize: the (possibly mirrored/warped) uv picks a
    // cell; populated cells flatten to the cell's average color, so moshed
    // motion stays visible as shifting cell colors.
    float3 c;
    bool sheetOn = u.sheetEnabled != 0;
    float2 sheetDims = float2(max(1.0, u.sheetCols), max(1.0, u.sheetRows));
    if (sheetOn) {
        float2 cellId = floor(uv * sheetDims);
        float total = sheetDims.x * sheetDims.y;
        float idx = cellId.y * sheetDims.x + cellId.x;
        bool populated = true;
        if (u.sheetRevealMode == 1) {          // sequential wipe, reading order
            populated = idx / total <= fract(u.sheetSelPhase / total);
        } else if (u.sheetRevealMode == 2) {   // random reveal
            populated = gridWarpHash(cellId + 3.7) <= fract(u.sheetSelPhase / total);
        }
        if (populated) {
            // 3x3 tap average over the cell approximates its flat mean color.
            float3 acc = float3(0.0);
            for (int j = 0; j < 3; j++)
                for (int i = 0; i < 3; i++)
                    acc += input.sample(s, (cellId + (float2(i, j) + 0.5) / 3.0)
                                           / sheetDims).rgb;
            c = acc / 9.0;
        } else {
            c = input.sample(s, uv).rgb;
        }
    } else {
        c = input.sample(s, uv).rgb;
    }

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
    if (u.gridWarpEnabled != 0 && gridLine > 0.0) {
        c = mix(c, float3(1.0) - c, gridLine * 0.999); // bright, mode-agnostic mesh line
    }

    // Spreadsheet chrome overlay — screen-space, drawn topmost. Deliberately
    // generic light-gray/white sheet chrome: no branding, no app colors.
    if (sheetOn && u.sheetChromeOpacity > 0.0) {
        float chrome = clamp(u.sheetChromeOpacity, 0.0, 1.0);
        float2 suv = (float2(gid) + 0.5)
            / float2(output.get_width(), output.get_height());
        float2 cuv = suv * sheetDims;
        float2 cellId = floor(cuv);
        float2 frac = fract(cuv);
        float2 edge = min(frac, 1.0 - frac);

        // Gridlines between cells (thin, light gray).
        float line = (1.0 - smoothstep(0.0, 0.05, min(edge.x, edge.y)))
            * clamp(u.sheetLineOpacity, 0.0, 1.0);
        c = mix(c, float3(0.78), line * chrome);

        // Animated active-cell selection: border + fill-handle square,
        // stepping through cells in reading order over time.
        float total = sheetDims.x * sheetDims.y;
        float selIdx = fmod(floor(u.sheetSelPhase), total);
        float2 selCell = float2(fmod(selIdx, sheetDims.x),
                                floor(selIdx / sheetDims.x));
        const float3 kSelColor = float3(0.16, 0.38, 0.75); // neutral UI blue
        if (all(cellId == selCell)) {
            if (edge.x < 0.09 || edge.y < 0.09) c = mix(c, kSelColor, chrome);
            if (frac.x > 0.82 && frac.y > 0.82) c = mix(c, kSelColor, chrome); // fill handle
        }

        // Top chrome bands: generic toolbar + formula bar + column header.
        const float kToolbarH = 0.035, kFormulaH = 0.030, kHeadH = 0.032;
        const float kHeadW = 0.045; // row-number rail width
        if (suv.y < kToolbarH) {
            float3 bar = float3(0.93);
            if (suv.y > kToolbarH * 0.9) bar = float3(0.80);   // divider
            c = mix(c, bar, chrome);
        } else if (suv.y < kToolbarH + kFormulaH) {
            float3 bar = float3(0.97);
            if (suv.y > kToolbarH + kFormulaH * 0.9) bar = float3(0.80);
            c = mix(c, bar, chrome);
        } else if (suv.y < kToolbarH + kFormulaH + kHeadH) {
            float3 band = float3(0.88);
            if (suv.x > kHeadW) {                              // column letters
                float col = floor(suv.x * sheetDims.x);
                int glyph = 10 + int(fmod(col, 26.0));         // 'A' + col%26
                float gx = fract(suv.x * sheetDims.x);
                float gy = (suv.y - kToolbarH - kFormulaH) / kHeadH;
                float2 luv = float2((gx - 0.30) / 0.40, (gy - 0.10) / 0.80);
                float a = sheetGlyphAlpha(glyphs, s, glyph, luv);
                band = mix(band, float3(0.25), a);
            }
            c = mix(c, band, chrome);
        } else if (suv.x < kHeadW) {                           // row numbers
            float3 band = float3(0.88);
            float row = floor(suv.y * sheetDims.y);
            int n = (int(row) + 1) % 100;
            float gy = fract(suv.y * sheetDims.y);
            float gx = suv.x / kHeadW;
            // Two digit slots; tens digit hidden below 10.
            int tens = n / 10, ones = n % 10;
            float2 luvT = float2((gx - 0.08) / 0.40, (gy - 0.12) / 0.76);
            float2 luvO = float2((gx - 0.52) / 0.40, (gy - 0.12) / 0.76);
            float a = 0.0;
            if (tens > 0) a = max(a, sheetGlyphAlpha(glyphs, s, tens, luvT));
            a = max(a, sheetGlyphAlpha(glyphs, s, ones, tens > 0 ? luvO : luvT + float2(-0.55, 0.0)));
            band = mix(band, float3(0.25), a);
            c = mix(c, band, chrome);
        }
    }

    // Tracking HUD overlay — decorative VFX-style motion-tracking readout,
    // drawn topmost in pure screen space. Points are hash-scattered, then
    // displaced by the REAL optical-flow field sampled at their location so
    // they twitch with actual scene motion. rg32Float isn't filterable on
    // all GPUs, so the flow field is sampled with a nearest-filter sampler.
    if (u.hudEnabled != 0) {
        constexpr sampler sf(coord::normalized, address::clamp_to_edge, filter::nearest);
        float2 res = float2(output.get_width(), output.get_height());
        float2 px = float2(gid) + 0.5;
        float acc = 0.0;
        int n = clamp(int(u.hudPointCount), 1, 64);
        for (int i = 0; i < n; i++) {
            float fi = float(i);
            float2 base = hudPointBase(fi);
            float2 fl = flow.sample(sf, base).rg;              // px of motion
            float2 pt = clamp(base + fl * 0.004, 0.02, 0.98);  // uv drift
            float2 ppx = pt * res;
            float d = length(px - ppx);

            // Feature dot (~2.5 px, soft 1 px edge).
            acc = max(acc, 1.0 - smoothstep(1.8, 3.0, d));

            // Occasional larger "search radius" circle.
            if (i % 9 == 3) {
                acc = max(acc, (1.0 - smoothstep(0.7, 1.7, fabs(d - 22.0))) * 0.7);
            }

            // Sparse mesh: thin line from ~every 3rd point to its successor.
            if (u.hudLineOpacity > 0.0 && (i % 3) == 0 && i + 1 < n) {
                float2 b2 = hudPointBase(fi + 1.0);
                float2 p2 = clamp(b2 + flow.sample(sf, b2).rg * 0.004,
                                  0.02, 0.98) * res;
                float2 ab = p2 - ppx, ap = px - ppx;
                float t = clamp(dot(ap, ab) / max(dot(ab, ab), 1.0), 0.0, 1.0);
                float dl = length(ap - ab * t);
                acc = max(acc, (1.0 - smoothstep(0.3, 1.1, dl)) * u.hudLineOpacity);
            }

            // Coordinate readout "X:1234 Y:0987" on a hash-chosen subset,
            // typeset from the shared glyph atlas (no runtime text layout).
            if (gridWarpHash(float2(fi, 5.5)) < u.hudLabelDensity) {
                const float gw = 7.0, gh = 11.0;
                float2 lp = px - (ppx + float2(8.0, -20.0));
                if (lp.x >= 0.0 && lp.x < gw * 13.0 && lp.y >= 0.0 && lp.y < gh) {
                    int slot = int(lp.x / gw);
                    int glyph = -1;
                    if (slot == 0) glyph = 33;                       // X
                    else if (slot == 1 || slot == 8) glyph = 36;     // :
                    else if (slot == 7) glyph = 34;                  // Y
                    else if (slot != 6) {                            // digits
                        int v = slot < 6 ? int(ppx.x) : int(ppx.y);
                        int k = slot < 6 ? slot - 2 : slot - 9;
                        int div = k == 0 ? 1000 : (k == 1 ? 100 : (k == 2 ? 10 : 1));
                        glyph = (v / div) % 10;
                    }
                    if (glyph >= 0) {
                        float2 luv = float2(fmod(lp.x, gw) / gw, lp.y / gh);
                        acc = max(acc, sheetGlyphAlpha(glyphs, s, glyph, luv));
                    }
                }
            }
        }
        c = mix(c, hueWheel(u.hudHue), min(acc, 1.0) * 0.9);
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
