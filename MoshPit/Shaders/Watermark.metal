#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Watermark blit: identical to blitScale, plus a premultiplied-alpha blend of
// a pre-rendered watermark texture over a bottom-right rect. One pass, no
// read_write texture access (bgra8Unorm targets don't support it everywhere):
// the watermark rides along with the copy the recorder/snapshot already does.
// Free tier exports only — preview, NDI, MJPEG never run this kernel.
// ---------------------------------------------------------------------------

struct WatermarkUniforms {
    float2 origin;   // top-left of the watermark rect, dst pixels
    float2 size;     // watermark rect size, dst pixels
};

kernel void watermarkBlit(texture2d<float, access::sample> input  [[texture(0)]],
                          texture2d<float, access::write>  output [[texture(1)]],
                          texture2d<float, access::sample> mark   [[texture(2)]],
                          constant WatermarkUniforms&      u      [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float3 c = input.sample(s, uv).rgb;

    float2 local = (float2(gid) + 0.5 - u.origin) / u.size;
    if (all(local >= 0.0) && all(local < 1.0)) {
        float4 w = mark.sample(s, local);          // premultiplied alpha
        c = w.rgb + c * (1.0 - w.a);
    }
    output.write(float4(c, 1.0), gid);
}
