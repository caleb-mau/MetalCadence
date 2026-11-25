#include <metal_stdlib>
using namespace metal;

// Pixel-format conversion for AVAssetWriter. A logical RGBA float4 is written
// to BGRA8; Metal handles the byte-channel mapping for the destination format.
kernel void exportRGBA(texture2d<float, access::read> source [[texture(0)]],
                       texture2d<float, access::write> destination [[texture(1)]],
                       uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= destination.get_width() || pixel.y >= destination.get_height())
        return;
    destination.write(source.read(pixel), pixel);
}
