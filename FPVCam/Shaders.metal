#include <metal_stdlib>
using namespace metal;

// Barrel-distortion split-view shader.
// Rendered with drawPrimitives(instanceCount: 2) — instance 0 = left eye, instance 1 = right eye.
// Each eye gets its own half of the screen with per-eye barrel distortion + IPD shift.

struct EyeParams {
    float ipd;   // NDC offset (derived from mm setting in Swift)
    float k1;    // radial distortion coefficient 1 (Cardboard default 0.22)
    float k2;    // radial distortion coefficient 2 (Cardboard default 0.24)
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    uint   eye;
};

// Two CCW triangles forming a unit quad, indexed by vertex_id 0-5
static constant float2 kQuadPositions[6] = {
    float2(0, 0), float2(1, 0), float2(0, 1),
    float2(1, 0), float2(1, 1), float2(0, 1),
};

vertex VertexOut splitVertex(uint vid  [[vertex_id]],
                              uint eye  [[instance_id]],
                              constant EyeParams &p [[buffer(0)]]) {
    float2 pos = kQuadPositions[vid];

    // Place quad in left (x: 0–0.5) or right (x: 0.5–1.0) half of screen
    float screenX = (float(eye) * 0.5) + pos.x * 0.5;

    VertexOut out;
    // NDC: x in [-1, 1], y in [-1, 1]. Screen x [0,1] → NDC [-1,1].
    out.position = float4(screenX * 2.0 - 1.0, pos.y * 2.0 - 1.0, 0.0, 1.0);
    out.texCoord = float2(pos.x, 1.0 - pos.y);  // flip Y: Metal UV origin is top-left
    out.eye = eye;
    return out;
}

static float2 barrelDistort(float2 uv, float k1, float k2) {
    float2 c  = uv - 0.5;
    float  r2 = dot(c, c);
    float  r4 = r2 * r2;
    return c * (1.0 + k1 * r2 + k2 * r4) + 0.5;
}

fragment float4 splitFragment(VertexOut in          [[stage_in]],
                               texture2d<float> tex  [[texture(0)]],
                               sampler samp          [[sampler(0)]],
                               constant EyeParams &p [[buffer(0)]]) {
    float2 uv = barrelDistort(in.texCoord, p.k1, p.k2);

    // IPD: push each eye away from the display centre
    uv.x += p.ipd * (in.eye == 0u ? -1.0 : 1.0);

    // Black border outside valid UV range
    if (any(uv < 0.0) || any(uv > 1.0)) {
        return float4(0, 0, 0, 1);
    }
    return tex.sample(samp, uv);
}
