#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertexShader(uint vid [[vertex_id]]) {
    float2 positions[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
    float2 uvs[4]       = { {0,1},   {1,1},  {0,0},  {1,0} };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv       = uvs[vid];
    return out;
}

fragment float4 fragmentShader(
    VertexOut        in          [[stage_in]],
    texture2d<float> base        [[texture(0)]],
    texture2d<float> deltaEye    [[texture(1)]],
    texture2d<float> deltaMouth  [[texture(2)]],
    constant float&  eyeWeight   [[buffer(0)]],
    constant float&  mouthWeight [[buffer(1)]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 b  = base.sample(s, in.uv);
    // delta textures are encoded as delta/2 + 0.5
    float4 de = (deltaEye.sample(s, in.uv)   * 2.0 - 1.0);
    float4 dm = (deltaMouth.sample(s, in.uv) * 2.0 - 1.0);
    float4 result = b + eyeWeight * de + mouthWeight * dm;
    return clamp(result, 0.0, 1.0);
}
