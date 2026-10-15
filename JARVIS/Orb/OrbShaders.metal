#include <metal_stdlib>
using namespace metal;

// Five-layer JARVIS orb. Colours are the brief's palette:
// main #00BFCB, highlight #00E5F2, deep #07565F, shadow #031C25, dim ring #0B3948.
// Additive blending expects premultiplied rgb.

struct Uniforms {
    float time;
    float amplitude;
    float level;
    float glow;
    float scan;
    float coreSpeed;
    float pulsePos;
    float pulseAmt;
    float dim;
    float quality;
    float aspect;
    float state;
    float coreGlow;
    float nodeFlash;
    float bandLow;
    float bandMid;
    float bandHigh;
};

struct PointVary {
    float4 position [[position]];
    float4 color;
    float size [[point_size]];
};

struct SolidVary {
    float4 position [[position]];
    float4 color;
};

struct BloomVary {
    float4 position [[position]];
    float2 uv;
};

constant float3 kMain = float3(0.0, 0.74902, 0.79608);
constant float3 kHighlight = float3(0.0, 0.89804, 0.94902);
constant float3 kDeep = float3(0.02745, 0.33725, 0.37255);
constant float3 kShadow = float3(0.01176, 0.10980, 0.14510);
constant float3 kDim = float3(0.04314, 0.22353, 0.28235);

float hash11(float n) {
    return fract(sin(n * 127.1) * 43758.5453);
}

float noise1(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), u);
}

float soften(float x) {
    float t = saturate(x);
    return t * t * (3.0 - 2.0 * t);
}

float breathOf(float time) {
    return 1.0 + 0.015 * sin(time * 1.25663706);
}

float3 premul(float3 rgb, float alpha) {
    return rgb * alpha;
}

float3 rotX(float3 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return float3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}

float3 rotY(float3 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

float3 rotZ(float3 p, float a) {
    float c = cos(a);
    float s = sin(a);
    return float3(c * p.x - s * p.y, s * p.x + c * p.y, p.z);
}

float2 place(float2 xy, float aspect) {
    return float2(xy.x / max(aspect, 0.01), xy.y);
}

float membraneDisp(float theta, float time, float contour, float bands) {
    float slow = sin(theta * 3.0 + time * 0.33 + contour * 1.2);
    float mid = sin(theta * 6.0 - time * 0.57 + contour * 0.7);
    float fine = sin(theta * 14.0 + time * 1.05);
    float n = noise1(theta * 1.6 + time * 0.21 + contour * 2.4) * 2.0 - 1.0;
    return slow * 0.50 + mid * 0.26 + fine * 0.10 + n * 0.30 + bands * 0.18;
}

vertex PointVary membrane_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    PointVary o;
    float breath = breathOf(u.time);
    float contour = fmod(float(vid), 4.0);
    float index = floor(float(vid) / 4.0);
    float span = (u.quality > 0.7) ? 420.0 : 180.0;
    float along = index / span;
    float drift = u.time * (0.045 + contour * 0.012);
    float theta = along * 6.2831853 + drift;
    float bands = u.bandLow * 0.65 + u.bandMid * 0.35;
    float disp = membraneDisp(theta, u.time, contour, bands);
    float base = 0.50 + contour * 0.038;
    float radius = (base + disp * (0.028 + u.amplitude * 0.085)) * breath;
    if (u.state > 0.5 && u.state < 1.5) {
        radius *= 0.90;
    }
    bool atmos = (vid % 9u) == 0u;
    if (atmos) {
        radius *= 1.07;
    }
    float2 xy = place(float2(cos(theta), sin(theta)) * radius, u.aspect);
    o.position = float4(xy, 0.0, 1.0);

    float bright = 0.22 + 0.50 * saturate(0.5 + 0.5 * disp) + u.glow * 0.28;
    bright += u.bandHigh * 0.12;
    float gap = abs(fract(along - u.pulsePos + 0.5) - 0.5);
    bright += soften(1.0 - gap / 0.07) * u.pulseAmt * 1.15;
    float3 col = mix(kDeep, kMain, saturate(bright));
    col = mix(col, kHighlight, soften(bright - 0.55));
    float alpha = (atmos ? 0.10 : 0.16 + bright * 0.28) * u.dim * (0.75 + u.quality * 0.25);
    o.color = float4(premul(col, alpha), alpha);
    o.size = (atmos ? 6.5 : 1.7 + bright * 1.4) * mix(1.15, 1.0, u.quality);
    return o;
}

vertex PointVary ring_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    PointVary o;
    float breath = breathOf(u.time);
    uint ring = vid % 3u;
    float along = float(vid / 3u) / 280.0;
    float dir = (ring == 1u) ? -1.0 : 1.0;
    float theta = along * 6.2831853 + u.time * 0.035 * dir * (1.0 + float(ring) * 0.35);
    float radius = (0.455 + float(ring) * 0.038) * breath;
    float2 xy = place(float2(cos(theta), sin(theta)) * radius, u.aspect);
    o.position = float4(xy, 0.0, 1.0);
    float twinkle = 0.35 + 0.65 * abs(sin(theta * 5.0 + u.time * 0.4 + float(ring)));
    float alpha = (0.05 + 0.07 * twinkle) * u.dim * (0.7 + u.glow * 0.4);
    float3 col = mix(kDim, kMain, 0.35 + 0.4 * twinkle);
    o.color = float4(premul(col, alpha), alpha);
    o.size = 1.35;
    return o;
}

vertex SolidVary segment_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    SolidVary o;
    float breath = breathOf(u.time);
    uint seg = vid / 6u;
    uint corner = vid % 6u;
    uint q = 0u;
    if (corner == 1u) q = 1u;
    else if (corner == 2u || corner == 5u) q = 2u;
    else if (corner == 4u) q = 3u;
    else if (corner == 3u) q = 1u;

    float pitch = 6.2831853 / 60.0;
    float centre = pitch * (float(seg) + 0.5) + u.time * 0.04;
    float halfW = pitch * 0.30;
    float ang = centre + ((q == 1u || q == 3u) ? halfW : -halfW);
    float inner = 0.332 * breath;
    float outer = 0.418 * breath;
    float rad = (q >= 2u) ? outer : inner;
    float2 xy = place(float2(cos(ang), sin(ang)) * rad, u.aspect);
    o.position = float4(xy, 0.0, 1.0);

    float wave = 0.5 + 0.5 * sin(float(seg) * 0.42 - u.time * u.scan * 2.1);
    float wave2 = 0.5 + 0.5 * sin(float(seg) * 0.15 + u.time * 0.55);
    float lit = 0.16 + 0.84 * max(wave, wave2 * 0.32);
    lit = saturate(lit * (0.55 + u.level * 0.7 + u.glow * 0.25));
    float edge = (q >= 2u) ? 1.0 : 0.25;
    float3 col = mix(kShadow, kDim, 0.65);
    col = mix(col, kDeep, lit);
    col = mix(col, kMain, lit * edge * 0.85);
    col = mix(col, kHighlight, lit * edge * 0.35 * u.glow);
    float alpha = (0.22 + lit * 0.40) * u.dim;
    o.color = float4(premul(col, alpha), alpha);
    return o;
}

float3 corePoint(float3 p, constant Uniforms &u) {
    float t = u.time * max(0.15, u.coreSpeed);
    return rotY(rotX(rotZ(p, t * 0.37), t * 0.21), t * 0.53);
}

vertex SolidVary line_vertex(uint vid [[vertex_id]],
                             const device float4 *verts [[buffer(1)]],
                             constant Uniforms &u [[buffer(0)]]) {
    SolidVary o;
    float breath = breathOf(u.time);
    float3 spun = corePoint(verts[vid].xyz, u);
    float persp = 1.0 / (2.15 - spun.z * 0.62);
    float s = 0.236 * breath * persp;
    float2 xy = place(spun.xy * s, u.aspect);
    o.position = float4(xy, 0.0, 1.0);
    float front = saturate(spun.z * 0.5 + 0.5);
    float alpha = (0.08 + front * front * 0.72) * u.dim * (0.65 + u.coreGlow * 0.5);
    float3 col = mix(kDeep, kMain, front);
    col = mix(col, kHighlight, front * front * 0.45 * u.coreGlow);
    o.color = float4(premul(col, alpha), alpha);
    return o;
}

vertex PointVary core_vertex(uint vid [[vertex_id]],
                             const device float4 *verts [[buffer(1)]],
                             constant Uniforms &u [[buffer(0)]]) {
    PointVary o;
    float breath = breathOf(u.time);
    float3 spun = corePoint(verts[vid].xyz, u);
    float persp = 1.0 / (2.15 - spun.z * 0.62);
    float s = 0.236 * breath * persp;
    float2 xy = place(spun.xy * s, u.aspect);
    o.position = float4(xy, 0.0, 1.0);
    float front = saturate(spun.z * 0.5 + 0.5);
    float id = float(vid);
    float flash = step(0.84, hash11(id * 3.1 + floor(u.time * 2.7))) * u.nodeFlash;
    float spark = step(0.93, hash11(id * 9.7));
    float alpha = (0.25 + front * 0.65 + flash * 0.9 + spark * 0.4) * u.dim * u.coreGlow;
    float3 col = mix(kMain, kHighlight, saturate(front + flash));
    o.color = float4(premul(col, alpha), alpha);
    o.size = (1.6 + front * 2.2 + flash * 3.0 + spark * 2.4) * mix(1.1, 1.0, u.quality);
    return o;
}

vertex PointVary micro_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
    PointVary o;
    float breath = breathOf(u.time);
    float id = float(vid);
    float kind = fmod(id, 3.0);
    float seed = hash11(id * 1.7);
    float life = fract(u.time * (0.12 + seed * 0.08) + seed);
    float fade = soften(life / 0.18) * soften((1.0 - life) / 0.35);
    float along = fract(seed + life);
    float theta = along * 6.2831853;
    float radius = 0.52;
    if (kind < 0.5) {
        float disp = membraneDisp(theta, u.time, 1.0, u.bandMid);
        radius = (0.52 + disp * 0.05) * breath;
    } else if (kind < 1.5) {
        float ring = floor(seed * 3.0);
        float dir = (ring == 1.0) ? -1.0 : 1.0;
        theta = along * 6.2831853 + u.time * 0.05 * dir;
        radius = (0.455 + ring * 0.038) * breath;
    } else {
        float lat = (seed - 0.5) * 1.4;
        theta = along * 6.2831853 + u.time * u.coreSpeed * 0.6;
        radius = 0.236 * breath * cos(lat);
        float y = sin(lat) * 0.236 * breath;
        float x = cos(theta) * radius;
        float2 xy = place(float2(x, y), u.aspect);
        if (u.state > 4.5 && u.state < 5.5) {
            xy *= mix(1.0, 0.12, fract(u.time * 0.45 + seed));
        }
        o.position = float4(xy, 0.0, 1.0);
        float alpha = fade * (0.20 + u.glow * 0.35) * u.dim;
        o.color = float4(premul(kHighlight, alpha), alpha);
        o.size = 1.5 + fade * 2.0;
        return o;
    }
    if (u.state > 4.5 && u.state < 5.5) {
        radius *= mix(1.0, 0.15, fract(u.time * 0.5 + seed));
    }
    float2 xy = place(float2(cos(theta), sin(theta)) * radius, u.aspect);
    o.position = float4(xy, 0.0, 1.0);
    float alpha = fade * (0.22 + u.glow * 0.4) * u.dim;
    float3 col = mix(kMain, kHighlight, fade);
    o.color = float4(premul(col, alpha), alpha);
    o.size = 1.4 + fade * 1.8;
    return o;
}

fragment float4 point_fragment(PointVary in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - float2(0.5)) * 2.0;
    float falloff = soften(1.0 - d);
    return in.color * falloff;
}

fragment float4 solid_fragment(SolidVary in [[stage_in]]) {
    return in.color;
}

vertex BloomVary bloom_vertex(uint vid [[vertex_id]]) {
    BloomVary o;
    float2 pos = float2(-1.0, -1.0);
    float2 uv = float2(0.0, 1.0);
    if (vid == 1u) {
        pos = float2(3.0, -1.0);
        uv = float2(2.0, 1.0);
    } else if (vid == 2u) {
        pos = float2(-1.0, 3.0);
        uv = float2(0.0, -1.0);
    }
    o.position = float4(pos, 0.0, 1.0);
    o.uv = uv;
    return o;
}

fragment float4 bloom_fragment(BloomVary in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler samp(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 texel = 1.0 / float2(float(src.get_width()), float(src.get_height()));
    float4 blur = float4(0.0);
    blur += src.sample(samp, uv + texel * float2(-2.0, 0.0));
    blur += src.sample(samp, uv + texel * float2(2.0, 0.0));
    blur += src.sample(samp, uv + texel * float2(0.0, -2.0));
    blur += src.sample(samp, uv + texel * float2(0.0, 2.0));
    blur += src.sample(samp, uv + texel * float2(-1.5, -1.5));
    blur += src.sample(samp, uv + texel * float2(1.5, -1.5));
    blur += src.sample(samp, uv + texel * float2(-1.5, 1.5));
    blur += src.sample(samp, uv + texel * float2(1.5, 1.5));
    blur *= 0.125;
    float4 base = src.sample(samp, uv);
    return base + blur * 0.72;
}
