#include <metal_stdlib>
using namespace metal;

// Original sky orb. t = time * 2, sped up by `boost`. No rim, no glow.

float hash21(float2 cell) {
    float x = cell.x * 13.571 + cell.y * 79.013;
    float s = sin(x);
    return fract(s * s * 97.137 + x * 0.017);
}

float valueNoise(float2 p) {
    float2 cell = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(cell);
    float b = hash21(cell + float2(1.0, 0.0));
    float c = hash21(cell + float2(0.0, 1.0));
    float d = hash21(cell + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(float2 p) {
    float sum = 0.0;
    float weight = 0.52;
    float2 turn = float2(2.4, 6.1);
    for (int octave = 0; octave < 5; octave++) {
        sum += weight * valueNoise(p);
        p = p * 2.05 + turn;
        turn = float2(turn.y, -turn.x) * 0.86;
        weight *= 0.5;
    }
    return sum;
}

[[ stitchable ]] half4 skyClouds(float2 position,
                                  half4 color,
                                  float time,
                                  float boost,
                                  float2 size) {
    float2 safe = max(size, float2(1.0));
    float2 uv = position / safe;
    float2 centered = uv * 2.0 - 1.0;
    if (dot(centered, centered) > 1.0) {
        return half4(0.0h);
    }

    float pace = 1.0 + boost;
    float t = time * 2.0 * pace;
    float swirl = 0.28 + boost * 0.22;

    float2 warpScroll = float2(0.16 * t, 0.24 * t);
    float2 low = uv * 1.15 + warpScroll;
    float2 warp = float2(fbm(low), fbm(low + float2(3.7, 8.1)));
    float2 p = uv + (warp - 0.5) * swirl;

    float2 forth = float2(0.07 * t, 0.05 * t);
    float2 back = float2(-0.09 * t, -0.06 * t);
    float broad = fbm(p * 2.15 + forth);
    float tight = fbm(p * 3.55 + back);
    float clouds = broad * 0.58 + tight * 0.42;

    float2 wispDrift = float2(0.24 * t, -0.18 * t);
    float wispField = fbm(p * 4.8 + wispDrift);
    float wisps = smoothstep(0.74, 0.92, wispField);

    float shaped = clouds * 0.72 + smoothstep(0.2, 0.95, uv.y) * 0.28 + wisps * 0.22;
    float edge = smoothstep(0.34, 0.52, shaped) * (1.0 - smoothstep(0.52, 0.74, shaped));
    float detail = fbm(p * 13.0 + float2(0.04 * t, -0.03 * t));
    shaped += (detail - 0.5) * edge * 0.42;
    shaped = saturate(shaped);

    float3 deepBlue = float3(0.0, 0.35, 0.9);
    float3 skyBlue = float3(0.1, 0.65, 1.0);
    float3 cloudWhite = float3(0.95, 0.97, 1.0);
    float3 warmWhite = float3(1.0, 0.965, 0.93);

    float3 sky = mix(deepBlue, skyBlue, smoothstep(0.0, 1.0, uv.y));
    float cover = smoothstep(0.36, 0.74, shaped);
    float3 rgb = mix(sky, cloudWhite, cover);
    float hottest = smoothstep(0.78, 0.98, shaped);
    rgb = mix(rgb, warmWhite, hottest * 0.4);
    return half4(half3(rgb), 1.0h);
}
