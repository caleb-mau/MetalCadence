#include <metal_stdlib>
using namespace metal;

// Color-correct NV12 conversion. The input matrix is carried by the
// CVImageBuffer attachments and selected by the Objective-C++ host.
kernel void convert(texture2d<float, access::sample> y [[texture(0)]],
                    texture2d<float, access::sample> uv [[texture(1)]],
                    texture2d<float, access::write> out [[texture(2)]],
                    constant int &fullRange [[buffer(0)]],
                    constant int &matrix [[buffer(1)]],
                    uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= out.get_width() || pixel.y >= out.get_height()) {
        return;
    }

    constexpr sampler linearSampler(filter::linear);
    float2 coordinates = (float2(pixel) + 0.5) / float2(out.get_width(), out.get_height());
    float luma = fullRange ? y.sample(linearSampler, coordinates).r
                           : (y.sample(linearSampler, coordinates).r * 255.0 - 16.0) / 219.0;
    float2 chroma =
        (uv.sample(linearSampler, coordinates).rg * 255.0 - 128.0) / (fullRange ? 255.0 : 224.0);

    float3 rgb;
    if (matrix == 1) {
        // BT.601
        rgb = float3(luma + 1.402 * chroma.y,
                     luma - 0.344136 * chroma.x - 0.714136 * chroma.y,
                     luma + 1.772 * chroma.x);
    } else if (matrix == 2) {
        // BT.2020
        rgb = float3(luma + 1.4746 * chroma.y,
                     luma - 0.164553 * chroma.x - 0.571353 * chroma.y,
                     luma + 1.8814 * chroma.x);
    } else {
        // BT.709
        rgb = float3(luma + 1.5748 * chroma.y,
                     luma - 0.1873 * chroma.x - 0.4681 * chroma.y,
                     luma + 1.8556 * chroma.x);
    }

    out.write(float4(clamp(rgb, 0.0, 1.0), 1.0), pixel);
}

struct MCVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex MCVertexOut vert(uint index [[vertex_id]]) {
    float2 corner = float2((index << 1) & 2, index & 2);
    MCVertexOut result;
    result.position = float4(corner * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    result.uv = corner;
    return result;
}

fragment float4 frag(MCVertexOut input [[stage_in]],
                     texture2d<float> source [[texture(0)]],
                     texture2d<float> enhanced [[texture(1)]],
                     constant int &mode [[buffer(0)]],
                     constant float2 &aspect [[buffer(1)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    float2 uv = input.uv;
    bool comparison = mode == 0;
    bool right = uv.x >= 0.5;

    if (comparison) {
        uv.x = fract(uv.x * 2.0);
    }

    float horizontal = aspect.x * (comparison ? 0.5 : 1.0);
    if (horizontal < aspect.y) {
        uv.y = (uv.y - 0.5) * aspect.y / horizontal + 0.5;
    } else {
        uv.x = (uv.x - 0.5) * horizontal / aspect.y + 0.5;
    }

    if (any(uv < 0.0) || any(uv > 1.0)) {
        return float4(0.035, 0.04, 0.05, 1.0);
    }

    return (mode == 2 || (comparison && !right)) ? source.sample(linearSampler, uv)
                                                 : enhanced.sample(linearSampler, uv);
}

// Optional low-cost blend backend. It is not motion compensated and can ghost
// around moving objects, which is why VideoToolbox remains the game default.
kernel void blend(texture2d<float, access::read> source [[texture(0)]],
                  texture2d<float, access::read> next [[texture(1)]],
                  texture2d<float, access::write> output [[texture(2)]],
                  constant float &phase [[buffer(0)]],
                  uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) {
        return;
    }

    output.write(mix(source.read(pixel), next.read(pixel), phase), pixel);
}
