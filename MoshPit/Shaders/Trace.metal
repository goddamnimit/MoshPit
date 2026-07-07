#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Trace / Mass: geometry render path (after Signal Culture's Re:Trace and
// V-Mass). The moshed canvas becomes a texture sampled by a vertex grid —
// point cloud, wireframe, or solid — with luma-driven displacement along the
// vertex normal. Unlit on purpose: the video IS the light.
// ============================================================================

struct TraceVertexIn {
    packed_float3 position;
    packed_float3 normal;
    float2 uv;
};

struct TraceUniforms {
    float4x4 mvp;
    float    depthAmount;   // luma displacement along normal (+/-)
    float    pointSize;
    float    alpha;
    float    pad0;
};

struct TraceVSOut {
    float4 pos [[position]];
    float2 uv;
    float  pointSize [[point_size]];
};

vertex TraceVSOut traceVertex(uint vid [[vertex_id]],
                              const device TraceVertexIn* verts [[buffer(0)]],
                              constant TraceUniforms& u          [[buffer(1)]],
                              texture2d<float, access::sample> canvas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    TraceVertexIn v = verts[vid];
    float3 p = float3(v.position);
    float3 n = float3(v.normal);
    // Vertex-stage texture fetch: luma pushes the vertex along its normal.
    float3 c = canvas.sample(s, v.uv, level(0)).rgb;
    float luma = dot(c, float3(0.299, 0.587, 0.114));
    p += n * (luma - 0.5) * u.depthAmount;

    TraceVSOut out;
    out.pos = u.mvp * float4(p, 1.0);
    out.uv = v.uv;
    out.pointSize = u.pointSize;
    return out;
}

fragment float4 traceFragment(TraceVSOut in [[stage_in]],
                              constant TraceUniforms& u [[buffer(1)]],
                              texture2d<float, access::sample> canvas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(canvas.sample(s, in.uv).rgb, u.alpha);
}

// Feedback-trails background: translucent black quad drawn instead of a
// clear, fading the previous frame (reuses the trails idea from Feedback
// Mosh at the viewport level).
struct FadeOut { float4 pos [[position]]; };

vertex FadeOut traceFadeVertex(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    FadeOut o;
    o.pos = float4(p[vid], 0, 1);
    return o;
}

fragment float4 traceFadeFragment(constant float& fade [[buffer(0)]]) {
    return float4(0.0, 0.0, 0.0, fade);
}
