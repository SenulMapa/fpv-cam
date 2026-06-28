#include <metal_stdlib>
using namespace metal;

// Per-eye barrel distortion. Each eye gets its own viewport (left: x in [0,0.5], right: x in [0.5,1]).
// The distortion pre-warps the image so the headset lens un-warps it back to rectilinear.

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    int    eye;      // 0 = left, 1 = right
};

struct EyeParams {
    float ipd;       // inter-pupillary distance offset in NDC (derived from mm setting)
    float k1;        // radial distortion coeff 1 (Cardboard default ≈ 0.22)
    float k2;        // radial distortion coeff 2 (Cardboard default ≈ 0.24)
};

// Full-screen quad verts for one eye; eye index passed as instanceID
vertex VertexOut splitVertex(uint vid        [[vertex_id]],
                              uint eye        [[instance_id]],
                              constant EyeParams &params [[buffer(0)]]) {
    // Two triangles forming a quad covering [0,1] in NDC x
    float2 quad[6] = {
        {0, 0}, {1, 0}, {0, 1},
        {1, 0}, {1, 1}, {0, 1}
    };
    float2 pos = quad[vid];

    // Place in left or right half of screen
    float halfOffset = (eye == 0) ? 0.0 : 0.5;
    float screenX = halfOffset + pos.x * 0.5;

    VertexOut out;
    out.position = float4(screenX * 2.0 - 1.0, pos.y * 2.0 - 1.0, 0, 1);
    out.texCoord = float2(pos.x, 1.0 - pos.y);
    out.eye = (int)eye;
    return out;
}

// Barrel-distortion UV warp
float2 distort(float2 uv, float k1, float k2) {
    float2 c = uv - 0.5;
    float r2 = dot(c, c);
    float r4 = r2 * r2;
    float scale = 1.0 + k1 * r2 + k2 * r4;
    return c * scale + 0.5;
}

fragment float4 splitFragment(VertexOut in         [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler samp         [[sampler(0)]],
                               constant EyeParams &params [[buffer(0)]]) {
    float2 uv = distort(in.texCoord, params.k1, params.k2);

    // IPD shift: push each eye outward from center
    float ipdShift = params.ipd * (in.eye == 0 ? -1.0 : 1.0);
    uv.x += ipdShift;

    // Clamp to avoid bleeding
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0, 0, 0, 1);
    }
    return tex.sample(samp, uv);
}
