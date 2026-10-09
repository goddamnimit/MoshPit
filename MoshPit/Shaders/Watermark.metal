#include <metal_stdlib>
using namespace metal;

// Free-tier watermark: same sampling as blitScale, plus a "MoshPit" wordmark
// composited bottom-right. Used ONLY by the recorder and snapshot paths;
// preview / NDI / MJPEG keep plain blitScale (clean). Mirror of
// WatermarkUniformsSwift in Watermark.swift.
struct WatermarkUniforms {
    float4 rect;          // x, y, w, h of the mark in output pixels (top-left origin)
    float  shadowOffset;  // px
    float  shadowSoft;    // px blur radius
    float  opacity;
    float  pad;
};

kernel void blitScaleWatermark(texture2d<float, access::sample> input  [[texture(0)]],
                               texture2d<float, access::write>  output [[texture(1)]],
                               texture2d<float, access::sample> mask   [[texture(2)]],
                               constant WatermarkUniforms& u           [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler ms(coord::normalized, address::clamp_to_zero, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 rgb = input.sample(s, uv).rgb;

    float2 muv = (float2(gid) + 0.5 - u.rect.xy) / u.rect.zw;
    float2 so = float2(u.shadowOffset) / u.rect.zw;
    float2 sb = float2(u.shadowSoft) / u.rect.zw;
    float sh = 0.0;
    sh += mask.sample(ms, muv - so + float2( sb.x,  sb.y)).a;
    sh += mask.sample(ms, muv - so + float2(-sb.x,  sb.y)).a;
    sh += mask.sample(ms, muv - so + float2( sb.x, -sb.y)).a;
    sh += mask.sample(ms, muv - so + float2(-sb.x, -sb.y)).a;
    sh *= 0.25;
    float a = mask.sample(ms, muv).a;
    rgb = mix(rgb, float3(0.0), sh * 0.5 * u.opacity);
    rgb = mix(rgb, float3(1.0), a * u.opacity);
    output.write(float4(rgb, 1.0), gid);
}
