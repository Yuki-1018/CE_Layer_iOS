#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut fullscreenVertex(uint id [[vertex_id]]) {
    constexpr float2 positions[] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    constexpr float2 coordinates[] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };
    VertexOut output;
    output.position = float4(positions[id], 0.0, 1.0);
    output.texCoord = coordinates[id];
    return output;
}

fragment float4 displayFragment(VertexOut input [[stage_in]], texture2d<float> image [[texture(0)]]) {
    if (image.get_width() == 0) return float4(0.02, 0.02, 0.02, 1.0);
    constexpr sampler nearestSampler(mag_filter::nearest, min_filter::nearest);
    float4 color = image.sample(nearestSampler, input.texCoord);
    color.a = 1.0;
    return color;
}

