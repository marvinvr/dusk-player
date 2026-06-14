#include <metal_stdlib>
using namespace metal;

struct VideoVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct VideoEnhancementUniforms {
    float2 sourceSize;
    float2 outputSize;
    float sharpening;
    float useLanczos;
    float sourceRGBA;
    float padding;
};

vertex VideoVertexOut videoEnhancementVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };

    constexpr float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };

    VideoVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

static float sinc(float x) {
    constexpr float pi = 3.14159265358979323846;
    if (fabs(x) < 0.0001) {
        return 1.0;
    }
    float pix = pi * x;
    return sin(pix) / pix;
}

static float lanczos2(float x) {
    x = fabs(x);
    if (x >= 2.0) {
        return 0.0;
    }
    return sinc(x) * sinc(x * 0.5);
}

static half3 sampleSource(
    texture2d<half, access::sample> sourceTexture,
    sampler sourceSampler,
    float2 uv,
    float sourceRGBA
) {
    half3 color = sourceTexture.sample(sourceSampler, uv).rgb;
    return sourceRGBA > 0.5 ? color.bgr : color;
}

static half3 sampleLanczos(
    texture2d<half, access::sample> sourceTexture,
    float2 uv,
    float2 sourceSize,
    float sourceRGBA
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 sourcePosition = uv * sourceSize - 0.5;
    float2 basePosition = floor(sourcePosition);
    float2 f = sourcePosition - basePosition; // fractional offset in [0, 1)

    // Lanczos is separable, so the 4x4 grid only has four distinct weights per
    // axis. Evaluate the kernel eight times here instead of recomputing the
    // two-sinc product for all sixteen taps (the dominant per-pixel cost).
    float wx[4] = {
        lanczos2(-1.0 - f.x),
        lanczos2(0.0 - f.x),
        lanczos2(1.0 - f.x),
        lanczos2(2.0 - f.x),
    };
    float wy[4] = {
        lanczos2(-1.0 - f.y),
        lanczos2(0.0 - f.y),
        lanczos2(1.0 - f.y),
        lanczos2(2.0 - f.y),
    };

    half3 color = half3(0.0);
    float weightSum = 0.0;

    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            float weight = wx[x] * wy[y];
            float2 samplePosition = basePosition + float2(x - 1, y - 1);
            float2 clampedPosition = clamp(samplePosition, float2(0.0), sourceSize - 1.0);
            float2 sampleUV = (clampedPosition + 0.5) / sourceSize;
            color += sampleSource(sourceTexture, linearSampler, sampleUV, sourceRGBA) * half(weight);
            weightSum += weight;
        }
    }

    if (weightSum <= 0.0001) {
        return sampleSource(sourceTexture, linearSampler, uv, sourceRGBA);
    }

    return color / half(weightSum);
}

fragment half4 videoEnhancementFragment(
    VideoVertexOut in [[stage_in]],
    texture2d<half, access::sample> sourceTexture [[texture(0)]],
    constant VideoEnhancementUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    float2 uv = clamp(in.texCoord, float2(0.0), float2(1.0));
    float2 texel = 1.0 / uniforms.sourceSize;

    half3 baseColor = uniforms.useLanczos > 0.5
        ? sampleLanczos(sourceTexture, uv, uniforms.sourceSize, uniforms.sourceRGBA)
        : sampleSource(sourceTexture, linearSampler, uv, uniforms.sourceRGBA);

    if (uniforms.sharpening <= 0.001) {
        return half4(baseColor, 1.0);
    }

    half3 blur =
        sampleSource(sourceTexture, linearSampler, uv + float2( texel.x, 0.0), uniforms.sourceRGBA) +
        sampleSource(sourceTexture, linearSampler, uv + float2(-texel.x, 0.0), uniforms.sourceRGBA) +
        sampleSource(sourceTexture, linearSampler, uv + float2(0.0,  texel.y), uniforms.sourceRGBA) +
        sampleSource(sourceTexture, linearSampler, uv + float2(0.0, -texel.y), uniforms.sourceRGBA);
    blur *= 0.25;

    half3 sharpened = clamp(baseColor + (baseColor - blur) * half(uniforms.sharpening), half3(0.0), half3(1.0));
    return half4(sharpened, 1.0);
}
