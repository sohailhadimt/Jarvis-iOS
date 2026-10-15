#include <metal_stdlib>
using namespace metal;

// ChatGPT full-screen voice orb. A circular blue sky with a scrolling, warping cloud field.
// SwiftUI clips the result to a hard circle; this shader does not draw a glow or a ring.

float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int octave = 0; octave < 5; octave++) {
        value += amplitude * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        amplitude *= 0.5;
    }
    return value;
}

[[ stitchable ]] half4 skyClouds(float2 position,
                                  half4 color,
                                  float time,
                                  float speed,
                                  float swell,
                                  float level,
                                  float2 size) {
    float2 safe = max(size, float2(1.0));
    float2 uv = position / safe;
    float2 centered = uv * 2.0 - 1.0;
    if (dot(centered, centered) > 1.0) {
        return half4(0.0h);
    }

    float3 skyTopA = float3(0.29412, 0.65882, 0.93333); // #4BA8EE
    float3 skyTopB = float3(0.35686, 0.70588, 0.94118); // #5BB4F0
    float3 skyLow = float3(0.74902, 0.89020, 0.98039);  // #BFE3FA
    float3 cloudWhite = float3(0.94902, 0.97255, 1.0);  // #F2F8FF
    float3 cloudPale = float3(0.86667, 0.93333, 1.0);   // #DDEEFF

    float cycle = 0.5 + 0.5 * sin(time * 0.62);
    cycle = saturate(cycle + swell);

    float2 drift = float2(time * speed * 0.24, time * speed * 0.08);
    float2 p = uv * 1.45 + drift + float2(0.0, -cycle * 0.42);

    float2 warp1 = float2(fbm(p + float2(0.0, time * speed * 0.05)),
                          fbm(p + float2(5.2, 1.3)));
    float2 warp2 = float2(fbm(p + 1.9 * warp1 + float2(1.7, 9.2)),
                          fbm(p + 1.9 * warp1 + float2(8.3, 2.8) + level * 0.15));
    float field = fbm(p + 2.6 * warp2);
    float detail = fbm(uv * 6.4 + drift * 1.3);
    float wisps = fbm(uv * 12.0 - drift);

    float lowerBand = smoothstep(0.30, 0.58, uv.y) * (1.0 - smoothstep(0.80, 0.98, uv.y));
    float topRight = smoothstep(0.62, 0.0, length(uv - float2(0.84, 0.14)));

    float threshold = mix(0.64, 0.26, cycle);
    threshold -= lowerBand * mix(0.24, 0.02, cycle);
    threshold += topRight * mix(0.0, 0.38, cycle);

    float density = smoothstep(threshold - 0.18, threshold + 0.22, field + detail * 0.14);
    float feather = smoothstep(0.05, 0.55, field + wisps * 0.22);
    density = saturate(density * mix(0.72, 1.0, feather));

    float shade = smoothstep(0.25, 0.92, field);
    float3 cloud = mix(cloudPale, cloudWhite, shade);
    float3 sky = mix(mix(skyTopA, skyTopB, saturate(uv.x)), skyLow, smoothstep(0.08, 0.95, uv.y));
    sky = mix(sky, skyTopA, smoothstep(0.42, 0.0, uv.y) * 0.45);

    float3 rgb = mix(sky, cloud, density);
    return half4(half3(rgb), 1.0h);
}
