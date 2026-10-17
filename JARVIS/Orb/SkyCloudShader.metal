#include <metal_stdlib>
using namespace metal;

// Original sky orb. Clouds morph in place at a constant speed. Audio never changes that speed.

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

float2 rotate2(float2 p, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

[[ stitchable ]] half4 skyClouds(float2 position,
                                  half4 color,
                                  float time,
                                  float2 size,
                                  float3 tint,
                                  float tintAmount,
                                  float feather) {
    float2 safe = max(size, float2(1.0));
    float2 uv = position / safe;
    float2 centered = uv * 2.0 - 1.0;
    float radius = length(centered);
    float fade = 1.0;
    if (feather > 0.001) {
        fade = 1.0 - smoothstep(1.0 - feather, 1.0, radius);
    }
    if (radius > 1.0 || fade <= 0.0) {
        return half4(0.0h);
    }

    // Slow, constant churn. Offsets orbit a small circle so the field morphs
    // instead of scrolling across the disc. Nothing here reads the microphone.
    float t = time;
    float2 q = rotate2(centered, t * 0.16);
    float2 q2 = rotate2(centered, -t * 0.11);
    float orbit = t * 0.42;
    float2 wobble = float2(cos(orbit), sin(orbit)) * 0.42;
    float2 wobbleB = float2(cos(orbit * 0.73 + 1.7), sin(orbit * 0.73 + 1.7)) * 0.36;

    float2 warp1 = float2(fbm(q * 1.85 + wobble), fbm(q * 1.85 + float2(-wobble.y, wobble.x) + 4.1));
    float2 warp2 = float2(fbm(q2 * 2.7 + wobbleB + 2.2), fbm(q2 * 2.7 - wobbleB + 7.4));
    float2 p = q + (warp1 - 0.5) * 0.55;
    float2 p2 = q2 + (warp2 - 0.5) * 0.40;

    float broad = fbm(p * 2.15);
    float tight = fbm(p2 * 3.35);
    float field = broad * 0.55 + tight * 0.45;
    // Stretch the middle of the noise so white masses and blue gaps are obvious.
    float clouds = smoothstep(0.36, 0.58, field);

    float2 holeOrbit = float2(cos(t * 0.23), sin(t * 0.19)) * 0.5;
    float holes = fbm(rotate2(centered, t * 0.09) * 1.55 + holeOrbit);
    float shaped = saturate(clouds - smoothstep(0.55, 0.74, holes) * 0.9);
    shaped += smoothstep(0.15, 0.95, uv.y) * 0.05;

    float edge = smoothstep(0.34, 0.50, shaped) * (1.0 - smoothstep(0.50, 0.72, shaped));
    float2 detailOrbit = float2(cos(t * 0.31), sin(t * 0.27)) * 0.25;
    float detail = fbm(p * 12.0 + detailOrbit);
    shaped += (detail - 0.5) * edge * 0.35;
    shaped = saturate(shaped);

    float3 deepBlue = float3(0.0, 0.35, 0.9);
    float3 skyBlue = float3(0.1, 0.65, 1.0);
    float3 cloudWhite = float3(0.95, 0.97, 1.0);
    float3 warmWhite = float3(1.0, 0.965, 0.93);
    float amount = saturate(tintAmount);
    float3 chosen = max(tint, float3(0.02));
    deepBlue = mix(deepBlue, chosen, amount);
    skyBlue = mix(skyBlue, chosen, amount * 0.72);

    float3 sky = mix(deepBlue, skyBlue, smoothstep(0.0, 1.0, uv.y));
    float cover = smoothstep(0.12, 0.55, shaped);
    float3 rgb = mix(sky, cloudWhite, cover);
    float hottest = smoothstep(0.78, 0.98, shaped);
    if (amount < 0.05) {
        rgb = mix(rgb, warmWhite, hottest * 0.4);
    }
    return half4(half3(rgb), half(fade));
}
