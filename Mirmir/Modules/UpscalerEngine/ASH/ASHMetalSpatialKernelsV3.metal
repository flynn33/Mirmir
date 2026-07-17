#include <metal_stdlib>
using namespace metal;

constant float ashPi = 3.14159265358979323846f;
constant float ashBinomial[5] = {1.0f, 4.0f, 6.0f, 4.0f, 1.0f};
constant float ashScharrX[9] = {-3.0f, 0.0f, 3.0f, -10.0f, 0.0f, 10.0f, -3.0f, 0.0f, 3.0f};
constant float ashScharrY[9] = {-3.0f, -10.0f, -3.0f, 0.0f, 0.0f, 0.0f, 3.0f, 10.0f, 3.0f};

struct ASHStateSamplePacked {
    ushort state;
    ushort flags;
    short orientation_q15;
    ushort magnitude_q15;
    ushort coherence_q15;
    ushort texture_q15;
    ushort risk_q15;
    ushort temporal_confidence_q15;
    ushort chroma_alignment_q15;
    ushort local_min;
    ushort local_max;
    short motion_x_q8_8;
    short motion_y_q8_8;
    ushort reserved0;
    uint reserved1;
};

struct ASHDispatchPacked {
    ushort primary_affine_state;
    ushort secondary_affine_state;
    uchar primary_descriptor;
    uchar secondary_descriptor;
    uchar primary_message;
    uchar secondary_message;
    ushort primary_weight_q16;
    ushort secondary_weight_q16;
    ushort margin_q16;
    ushort flags;
    uint parameter_index;
    uint provenance_crc32;
};

struct ASHStateProbeInput {
    float magnitude;
    float coherence;
    float texture;
    float risk;
    float chroma_alignment;
    float tangent;
};

struct ASHDescriptorParityProbeOutput {
    uint value0_bits;
    uint value1_bits;
    uint state;
    uint primary_message;
    uint descriptor;
    uint phase;
    uint plane;
    uint invocation_count;
    uint fallback_count;
    uint fatal_count;
    uint lut_word_0;
    uint lut_word_1;
    uint lut_word_2;
    uint lut_word_3;
    uint lut_word_4;
    uint lut_word_5;
};

static_assert(sizeof(ASHStateSamplePacked) == 32, "ASHStateSamplePacked ABI");
static_assert(sizeof(ASHDispatchPacked) == 24, "ASHDispatchPacked ABI");
static_assert(sizeof(ASHDescriptorParityProbeOutput) == 64, "ASHDescriptorParityProbeOutput ABI");

enum ASHUniformIndex : uint {
    sourceLumaWidth = 0,
    sourceLumaHeight = 1,
    sourceChromaWidth = 2,
    sourceChromaHeight = 3,
    destinationLumaWidth = 4,
    destinationLumaHeight = 5,
    destinationChromaWidth = 6,
    destinationChromaHeight = 7,
    analysisColumnCount = 8,
    analysisRowCount = 9,
    analysisStep = 10,
    scaleNumerator = 11,
    scaleDenominator = 12,
    phaseCount = 13,
    boundaryMode = 14,
    codeRange = 15,
    chromaSitingX = 16,
    chromaSitingY = 17,
    lumaCoordinatePolicy = 18,
    chromaCoordinatePolicy = 19,
    lumaAnisotropyMode = 20,
    chromaAnisotropyMode = 21,
    lutParameterOffset = 22,
    lutEntryOffset = 23,
    lutParameterCount = 24,
    lutByteCount = 25,
    riskLaplacianWeight = 30,
    riskAlternatingWeight = 31,
    analysisEpsilon = 32,
    chromaConfidenceThreshold = 33,
    edgeLow = 34,
    edgeHigh = 35,
    coherenceLow = 36,
    coherenceHigh = 37,
    textureLow = 38,
    textureHigh = 39,
    riskLow = 40,
    riskHigh = 41,
    temporalLow = 42,
    temporalHigh = 43,
    chromaLow = 44,
    chromaHigh = 45,
    fallbackMinimumMagnitude = 46,
    fallbackMinimumCoherence = 47,
    fallbackRiskThreshold = 48,
    fallbackLowPassRadius = 49,
    fallbackWeightEpsilon = 50
};

enum ASHTelemetryIndex : uint {
    stateHistogramBase = 0,
    messageHistogramBase = 512,
    operatorHistogramBase = 528,
    counterBase = 544,
    decodeExactCounter = 544,
    decodeCorrectedCounter = 545,
    decodeRejectedCounter = 546,
    candidateOneCounter = 547,
    candidateTwoCounter = 548,
    dispatchCounter = 549,
    invocationCounter = 550,
    numericalFallbackCounter = 551,
    sourceAlignedCounter = 552,
    lumaOutputCounter = 553,
    chromaOutputCounter = 554,
    fatalFaultCounter = 555,
    analysisCellCounter = 556,
    lumaInvocationCounter = 557,
    chromaInvocationCounter = 558,
    lumaNumericalFallbackCounter = 559,
    affineFallbackCounter = 560,
    parityRecomputationCounter = 561,
    telemetryWordCount = 562
};

// P08-only fixed-control specialization. Production never creates either
// fixed-control pipeline. Function constants bind the selected same-bank
// descriptor and its locked parameters when the evidence pipeline is built.
constant uint ashP08FixedDescriptor [[function_constant(100)]];
constant float ashP08FixedMinimumMagnitude [[function_constant(101)]];
constant float ashP08FixedMinimumCoherence [[function_constant(102)]];
constant float ashP08FixedDetailGain [[function_constant(103)]];
constant float ashP08FixedRelaxedAlpha [[function_constant(104)]];
constant float ashP08FixedRiskThreshold [[function_constant(105)]];
constant float ashP08FixedLowPassRadius [[function_constant(106)]];
constant float ashP08FixedWeightEpsilon [[function_constant(107)]];
constant float ashP08FixedSupportRadius [[function_constant(108)]];

inline float ashFloat(device const uint *uniforms, uint index) {
    return as_type<float>(uniforms[index]);
}

inline ushort ashLoadU16(device const uchar *bytes, uint offset) {
    return ushort(bytes[offset]) | (ushort(bytes[offset + 1]) << 8);
}

inline uint ashLoadU32(device const uchar *bytes, uint offset) {
    return uint(bytes[offset])
        | (uint(bytes[offset + 1]) << 8)
        | (uint(bytes[offset + 2]) << 16)
        | (uint(bytes[offset + 3]) << 24);
}

inline int ashResolveIndex(int proposed, uint extent, uint boundary) {
    if (boundary == 0 || extent <= 1) {
        return clamp(proposed, 0, int(extent) - 1);
    }
    int period = 2 * (int(extent) - 1);
    int value = proposed % period;
    if (value < 0) { value += period; }
    return value < int(extent) ? value : period - value;
}

inline float ashRawComponent(
    texture2d<float, access::read> texture,
    int x,
    int y,
    uint channel,
    uint boundary
) {
    int resolvedX = ashResolveIndex(x, texture.get_width(), boundary);
    int resolvedY = ashResolveIndex(y, texture.get_height(), boundary);
    float4 value = texture.read(uint2(uint(resolvedX), uint(resolvedY)));
    return channel == 0 ? value.r : value.g;
}

inline float ashCode(
    texture2d<float, access::read> texture,
    int x,
    int y,
    uint channel,
    uint boundary
) {
    return rint(ashRawComponent(texture, x, y, channel, boundary) * 255.0f);
}

inline float ashLinearNormalizedCode(float code, bool luma, uint range) {
    float minimum = range == 0 ? 16.0f : 0.0f;
    float maximum = range == 0 ? (luma ? 235.0f : 240.0f) : 255.0f;
    return (code - minimum) / (maximum - minimum);
}

inline float ashAnalysisPlaneSample(
    texture2d<float, access::read> texture,
    int x,
    int y,
    uint channel,
    bool luma,
    device const uint *uniforms
) {
    float value = ashLinearNormalizedCode(
        ashCode(texture, x, y, channel, uniforms[boundaryMode]),
        luma,
        uniforms[codeRange]
    );
    return luma ? value : value - 0.5f;
}

inline float ashReconstructionPlaneSample(
    texture2d<float, access::read> texture,
    int x,
    int y,
    uint channel,
    bool luma,
    device const uint *uniforms
) {
    return clamp(
        ashLinearNormalizedCode(
            ashCode(texture, x, y, channel, uniforms[boundaryMode]),
            luma,
            uniforms[codeRange]
        ),
        0.0f,
        1.0f
    );
}

inline float ashAnalysisBilinear(
    texture2d<float, access::read> texture,
    float x,
    float y,
    uint channel,
    bool luma,
    device const uint *uniforms
) {
    int lowerX = int(floor(x));
    int lowerY = int(floor(y));
    float fractionX = x - float(lowerX);
    float fractionY = y - float(lowerY);
    float top = mix(
        ashAnalysisPlaneSample(texture, lowerX, lowerY, channel, luma, uniforms),
        ashAnalysisPlaneSample(texture, lowerX + 1, lowerY, channel, luma, uniforms),
        fractionX
    );
    float bottom = mix(
        ashAnalysisPlaneSample(texture, lowerX, lowerY + 1, channel, luma, uniforms),
        ashAnalysisPlaneSample(texture, lowerX + 1, lowerY + 1, channel, luma, uniforms),
        fractionX
    );
    return mix(top, bottom, fractionY);
}

struct ASHGradient { float x; float y; };
struct ASHTensor { float xx; float yy; float xy; };
struct ASHStatistics { float variance; float minimum; float maximum; };

inline ASHGradient ashGradient(
    texture2d<float, access::read> texture,
    float x,
    float y,
    uint channel,
    bool luma,
    device const uint *uniforms
) {
    float gx = 0.0f;
    float gy = 0.0f;
    for (uint row = 0; row < 3; ++row) {
        for (uint column = 0; column < 3; ++column) {
            float value = ashAnalysisBilinear(
                texture,
                x + float(int(column) - 1),
                y + float(int(row) - 1),
                channel,
                luma,
                uniforms
            );
            uint index = row * 3 + column;
            gx += ashScharrX[index] * value;
            gy += ashScharrY[index] * value;
        }
    }
    return ASHGradient{gx / 32.0f, gy / 32.0f};
}

inline ASHTensor ashTensor(
    texture2d<float, access::read> texture,
    float x,
    float y,
    uint channel,
    bool luma,
    device const uint *uniforms
) {
    ASHTensor result{0.0f, 0.0f, 0.0f};
    for (uint row = 0; row < 5; ++row) {
        for (uint column = 0; column < 5; ++column) {
            float weight = ashBinomial[row] * ashBinomial[column] / 256.0f;
            ASHGradient gradient = ashGradient(
                texture,
                x + float(int(column) - 2),
                y + float(int(row) - 2),
                channel,
                luma,
                uniforms
            );
            result.xx += weight * gradient.x * gradient.x;
            result.yy += weight * gradient.y * gradient.y;
            result.xy += weight * gradient.x * gradient.y;
        }
    }
    return result;
}

inline ASHStatistics ashStatistics(
    texture2d<float, access::read> texture,
    float x,
    float y,
    uint channel,
    bool luma,
    device const uint *uniforms
) {
    float mean = 0.0f;
    float square = 0.0f;
    float minimum = INFINITY;
    float maximum = -INFINITY;
    for (uint row = 0; row < 5; ++row) {
        for (uint column = 0; column < 5; ++column) {
            float value = ashAnalysisBilinear(
                texture,
                x + float(int(column) - 2),
                y + float(int(row) - 2),
                channel,
                luma,
                uniforms
            );
            float weight = ashBinomial[row] * ashBinomial[column] / 256.0f;
            mean += weight * value;
            square += weight * value * value;
            minimum = min(minimum, value);
            maximum = max(maximum, value);
        }
    }
    return ASHStatistics{max(0.0f, square - mean * mean), minimum, maximum};
}

inline float ashBlur(
    texture2d<float, access::read> texture,
    float x,
    float y,
    device const uint *uniforms
) {
    float total = 0.0f;
    for (uint row = 0; row < 5; ++row) {
        for (uint column = 0; column < 5; ++column) {
            float weight = ashBinomial[row] * ashBinomial[column] / 256.0f;
            total += weight * ashAnalysisBilinear(
                texture,
                x + float(int(column) - 2),
                y + float(int(row) - 2),
                0,
                true,
                uniforms
            );
        }
    }
    return total;
}

inline float ashModuloPi(float value) {
    float reduced = fmod(value, ashPi);
    return reduced < 0.0f ? reduced + ashPi : reduced;
}

inline uint ashSector(float tangent) {
    float scaled = ashModuloPi(tangent) / (ashPi / 4.0f);
    int lower = int(floor(scaled));
    int fractionQ15 = int(rint((scaled - float(lower)) * 32768.0f));
    return uint((lower + (fractionQ15 > 16384 ? 1 : 0)) & 3);
}

inline ushort ashQ15(float value) {
    return ushort(clamp(rint(clamp(value, 0.0f, 1.0f) * 32767.0f), 0.0f, 32767.0f));
}

inline ushort ashQ16(float value) {
    return ushort(clamp(rint(clamp(value, 0.0f, 1.0f) * 65535.0f), 0.0f, 65535.0f));
}

inline float ashFromQ15(ushort value) { return float(value) / 32767.0f; }
inline float ashFromQ16(ushort value) { return float(value) / 65535.0f; }

kernel void ash_v3_analyze_luma(
    texture2d<float, access::read> source [[texture(0)]],
    device ASHStateSamplePacked *states [[buffer(0)]],
    device const uint *uniforms [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms[analysisColumnCount] || gid.y >= uniforms[analysisRowCount]) {
        return;
    }
    uint step = uniforms[analysisStep];
    uint originX = gid.x * step;
    uint originY = gid.y * step;
    uint actualWidth = min(step, uniforms[sourceLumaWidth] - originX);
    uint actualHeight = min(step, uniforms[sourceLumaHeight] - originY);
    float x = float(originX) + float(actualWidth - 1) * 0.5f;
    float y = float(originY) + float(actualHeight - 1) * 0.5f;

    ASHTensor tensor = ashTensor(source, x, y, 0, true, uniforms);
    ASHStatistics statistics = ashStatistics(source, x, y, 0, true, uniforms);
    float epsilon = ashFloat(uniforms, analysisEpsilon);
    float magnitude = sqrt(max(0.0f, tensor.xx + tensor.yy));
    float normalizedMagnitude = clamp(
        magnitude / (sqrt(statistics.variance) + epsilon),
        0.0f,
        1.0f
    );
    float coherence = clamp(
        sqrt((tensor.xx - tensor.yy) * (tensor.xx - tensor.yy)
            + 4.0f * tensor.xy * tensor.xy)
            / (tensor.xx + tensor.yy + epsilon),
        0.0f,
        1.0f
    );
    float normal = ashModuloPi(0.5f * atan2(2.0f * tensor.xy, tensor.xx - tensor.yy));
    float tangent = ashModuloPi(normal + ashPi * 0.5f);

    float residualEnergy = 0.0f;
    for (uint row = 0; row < 5; ++row) {
        for (uint column = 0; column < 5; ++column) {
            float localX = x + float(int(column) - 2);
            float localY = y + float(int(row) - 2);
            float value = ashAnalysisBilinear(source, localX, localY, 0, true, uniforms);
            float residual = value - ashBlur(source, localX, localY, uniforms);
            float weight = ashBinomial[row] * ashBinomial[column] / 256.0f;
            residualEnergy += weight * residual * residual;
        }
    }
    float texture = clamp(residualEnergy / (statistics.variance + epsilon), 0.0f, 1.0f);

    uint normalSector = ashSector(normal);
    int2 direction = normalSector == 0 ? int2(1, 0)
        : normalSector == 1 ? int2(1, 1)
        : normalSector == 2 ? int2(0, 1)
        : int2(1, -1);
    float laplacianEnergy = 0.0f;
    float alternatingEnergy = 0.0f;
    for (uint row = 0; row < 5; ++row) {
        for (uint column = 0; column < 5; ++column) {
            float localX = x + float(int(column) - 2);
            float localY = y + float(int(row) - 2);
            float center = ashAnalysisBilinear(source, localX, localY, 0, true, uniforms);
            float laplacian = fabs(
                4.0f * center
                - ashAnalysisBilinear(source, localX - 1.0f, localY, 0, true, uniforms)
                - ashAnalysisBilinear(source, localX + 1.0f, localY, 0, true, uniforms)
                - ashAnalysisBilinear(source, localX, localY - 1.0f, 0, true, uniforms)
                - ashAnalysisBilinear(source, localX, localY + 1.0f, 0, true, uniforms)
            ) * 0.25f;
            float before = ashAnalysisBilinear(
                source,
                localX - float(direction.x),
                localY - float(direction.y),
                0,
                true,
                uniforms
            );
            float after = ashAnalysisBilinear(
                source,
                localX + float(direction.x),
                localY + float(direction.y),
                0,
                true,
                uniforms
            );
            float weight = ashBinomial[row] * ashBinomial[column] / 256.0f;
            laplacianEnergy += weight * laplacian;
            alternatingEnergy += weight * fabs(before - 2.0f * center + after) * 0.5f;
        }
    }
    float laplacianWeight = ashFloat(uniforms, riskLaplacianWeight);
    float alternatingWeight = ashFloat(uniforms, riskAlternatingWeight);
    float risk = clamp(
        (laplacianWeight * laplacianEnergy + alternatingWeight * alternatingEnergy)
            / (laplacianWeight + alternatingWeight),
        0.0f,
        1.0f
    );

    uint index = gid.y * uniforms[analysisColumnCount] + gid.x;
    ASHStateSamplePacked packed{};
    packed.orientation_q15 = short(clamp(rint(tangent / ashPi * 32767.0f), 0.0f, 32767.0f));
    packed.magnitude_q15 = ashQ15(normalizedMagnitude);
    packed.coherence_q15 = ashQ15(coherence);
    packed.texture_q15 = ashQ15(texture);
    packed.risk_q15 = ashQ15(risk);
    packed.chroma_alignment_q15 = 32767;
    packed.local_min = ashQ16(statistics.minimum);
    packed.local_max = ashQ16(statistics.maximum);
    uint magnitudeBits = as_type<uint>(normalizedMagnitude);
    packed.flags = ushort(magnitudeBits & 0xffff);
    packed.reserved0 = ushort(magnitudeBits >> 16);
    packed.reserved1 = as_type<uint>(tangent);

    float edgeThreshold = (ashFloat(uniforms, edgeLow) + ashFloat(uniforms, edgeHigh)) * 0.5f;
    float coherenceThreshold = (ashFloat(uniforms, coherenceLow) + ashFloat(uniforms, coherenceHigh)) * 0.5f;
    float textureThreshold = (ashFloat(uniforms, textureLow) + ashFloat(uniforms, textureHigh)) * 0.5f;
    float riskThreshold = (ashFloat(uniforms, riskLow) + ashFloat(uniforms, riskHigh)) * 0.5f;
    uint edge = normalizedMagnitude >= edgeThreshold;
    uint orientation = edge != 0 ? ashSector(tangent) : 0;
    uint lumaPayload = ((orientation & 1) << 7)
        | (((orientation >> 1) & 1) << 6)
        | (edge << 5)
        | (uint(coherence >= coherenceThreshold) << 4)
        | (uint(texture >= textureThreshold) << 3)
        | (uint(risk >= riskThreshold) << 2);
    packed.state = ushort(lumaPayload << 1);
    states[index] = packed;
}

kernel void ash_v3_analyze_chroma_and_pack_state(
    texture2d<float, access::read> source [[texture(0)]],
    device ASHStateSamplePacked *states [[buffer(0)]],
    device const uint *uniforms [[buffer(1)]],
    device atomic_uint *telemetry [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms[analysisColumnCount] || gid.y >= uniforms[analysisRowCount]) {
        return;
    }
    uint step = uniforms[analysisStep];
    uint originX = gid.x * step;
    uint originY = gid.y * step;
    uint actualWidth = min(step, uniforms[sourceLumaWidth] - originX);
    uint actualHeight = min(step, uniforms[sourceLumaHeight] - originY);
    float lumaX = float(originX) + float(actualWidth - 1) * 0.5f;
    float lumaY = float(originY) + float(actualHeight - 1) * 0.5f;
    float x = (lumaX - float(uniforms[chromaSitingX]) * 0.5f) * 0.5f;
    float y = (lumaY - float(uniforms[chromaSitingY]) * 0.5f) * 0.5f;

    ASHTensor first = ashTensor(source, x, y, 0, false, uniforms);
    ASHTensor second = ashTensor(source, x, y, 1, false, uniforms);
    ASHTensor tensor{
        first.xx + second.xx,
        first.yy + second.yy,
        first.xy + second.xy
    };
    ASHStatistics firstStats = ashStatistics(source, x, y, 0, false, uniforms);
    ASHStatistics secondStats = ashStatistics(source, x, y, 1, false, uniforms);
    float epsilon = ashFloat(uniforms, analysisEpsilon);
    float confidence = clamp(
        sqrt(max(0.0f, tensor.xx + tensor.yy))
            / (sqrt(firstStats.variance + secondStats.variance) + epsilon),
        0.0f,
        1.0f
    );

    uint index = gid.y * uniforms[analysisColumnCount] + gid.x;
    ASHStateSamplePacked packed = states[index];
    float lumaTangent = as_type<float>(packed.reserved1);
    uint magnitudeBits = uint(packed.flags) | (uint(packed.reserved0) << 16);
    float lumaMagnitude = as_type<float>(magnitudeBits);
    float alignment = 1.0f;
    if (confidence >= ashFloat(uniforms, chromaConfidenceThreshold)) {
        float normal = ashModuloPi(
            0.5f * atan2(2.0f * tensor.xy, tensor.xx - tensor.yy)
        );
        float chromaTangent = ashModuloPi(normal + ashPi * 0.5f);
        float agreement = max(0.0f, cos(2.0f * (lumaTangent - chromaTangent)));
        alignment = clamp(
            agreement * min(lumaMagnitude, confidence),
            0.0f,
            1.0f
        );
    }
    packed.chroma_alignment_q15 = ashQ15(alignment);

    float chromaThreshold = (ashFloat(uniforms, chromaLow) + ashFloat(uniforms, chromaHigh)) * 0.5f;
    uint payload = (uint(packed.state) >> 1)
        | uint(alignment >= chromaThreshold);
    packed.state = ushort((payload << 1) | (popcount(payload) & 1));
    states[index] = packed;
    atomic_fetch_add_explicit(&telemetry[stateHistogramBase + packed.state], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&telemetry[analysisCellCounter], 1, memory_order_relaxed);
}

inline uint ashDecodeStatus(uint packed) { return (packed >> 8) & 3; }
inline uint ashDecodeMessage(uint packed) { return packed & 0xff; }

kernel void ash_v3_decode_dispatch(
    device const ASHStateSamplePacked *states [[buffer(0)]],
    device const uchar *lut [[buffer(1)]],
    device const uint *decoder [[buffer(2)]],
    device ASHDispatchPacked *dispatches [[buffer(3)]],
    device const uint *uniforms [[buffer(4)]],
    device atomic_uint *telemetry [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    uint perPlane = uniforms[analysisColumnCount] * uniforms[analysisRowCount]
        * uniforms[phaseCount];
    if (gid >= perPlane * 2) { return; }
    uint plane = gid / perPlane;
    uint local = gid - plane * perPlane;
    uint cell = local / uniforms[phaseCount];
    uint phase = local - cell * uniforms[phaseCount];
    ushort state = states[cell].state;
    uint ordinal = uint(state) >> 1;
    uint logicalIndex = plane * (uniforms[phaseCount] * 4 * 256)
        + phase * (4 * 256)
        + ordinal;
    uint offset = uniforms[lutEntryOffset] + logicalIndex * 24;

    ASHDispatchPacked result{};
    result.primary_affine_state = ashLoadU16(lut, offset);
    result.secondary_affine_state = ashLoadU16(lut, offset + 2);
    result.primary_descriptor = lut[offset + 4];
    result.secondary_descriptor = lut[offset + 5];
    result.primary_message = lut[offset + 6];
    result.secondary_message = lut[offset + 7];
    result.primary_weight_q16 = ashLoadU16(lut, offset + 8);
    result.secondary_weight_q16 = ashLoadU16(lut, offset + 10);
    result.margin_q16 = ashLoadU16(lut, offset + 12);
    result.flags = ashLoadU16(lut, offset + 14);
    result.parameter_index = ashLoadU32(lut, offset + 16);
    result.provenance_crc32 = ashLoadU32(lut, offset + 20);

    bool fallback = false;
    uint primaryDecode = decoder[(uint(result.primary_affine_state) ^ uint(state)) & 511];
    uint primaryStatus = ashDecodeStatus(primaryDecode);
    if (primaryStatus > 1 || ashDecodeMessage(primaryDecode) != result.primary_message) {
        fallback = true;
        atomic_fetch_add_explicit(&telemetry[decodeRejectedCounter], 1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(
            &telemetry[primaryStatus == 0 ? decodeExactCounter : decodeCorrectedCounter],
            1,
            memory_order_relaxed
        );
    }

    bool hasSecondary = (result.flags & 1) != 0;
    if (hasSecondary) {
        uint secondaryDecode = decoder[(uint(result.secondary_affine_state) ^ uint(state)) & 511];
        uint secondaryStatus = ashDecodeStatus(secondaryDecode);
        if (secondaryStatus > 1 || ashDecodeMessage(secondaryDecode) != result.secondary_message) {
            fallback = true;
            atomic_fetch_add_explicit(&telemetry[decodeRejectedCounter], 1, memory_order_relaxed);
        } else {
            atomic_fetch_add_explicit(
                &telemetry[secondaryStatus == 0 ? decodeExactCounter : decodeCorrectedCounter],
                1,
                memory_order_relaxed
            );
        }
    }

    if (fallback || result.parameter_index >= uniforms[lutParameterCount]) {
        result.secondary_affine_state = 0xffff;
        result.primary_descriptor = 0;
        result.secondary_descriptor = 0xff;
        result.primary_message = 0;
        result.secondary_message = 0xff;
        result.primary_weight_q16 = 0xffff;
        result.secondary_weight_q16 = 0;
        result.margin_q16 = 0xffff;
        result.flags = 0x8000;
        hasSecondary = false;
    }
    dispatches[gid] = result;
    atomic_fetch_add_explicit(&telemetry[messageHistogramBase + result.primary_message], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&telemetry[operatorHistogramBase + result.primary_descriptor], 1, memory_order_relaxed);
    if (hasSecondary) {
        atomic_fetch_add_explicit(&telemetry[messageHistogramBase + result.secondary_message], 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&telemetry[operatorHistogramBase + result.secondary_descriptor], 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&telemetry[candidateTwoCounter], 1, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&telemetry[candidateOneCounter], 1, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&telemetry[dispatchCounter], 1, memory_order_relaxed);
}

struct ASHCandidateParameters {
    float minimumMagnitude;
    float minimumCoherence;
    float detailGain;
    float relaxedAlpha;
    float riskThreshold;
    float lowPassRadius;
    float weightEpsilon;
    float supportRadius;
    float anisotropyStrength;
    int orientationDelta;
    bool usesAnisotropy;
};

inline float ashAnisotropyStrength(uint mode) {
    return mode <= 1 ? 0.0f : float(mode - 1) * 0.25f;
}

inline ASHCandidateParameters ashParameters(
    device const uchar *lut,
    uint parameterIndex,
    bool secondary,
    uint anisotropyMode,
    device const uint *uniforms,
    bool fallback
) {
    if (fallback) {
        return ASHCandidateParameters{
            ashFloat(uniforms, fallbackMinimumMagnitude),
            ashFloat(uniforms, fallbackMinimumCoherence),
            0.0f,
            0.0f,
            ashFloat(uniforms, fallbackRiskThreshold),
            ashFloat(uniforms, fallbackLowPassRadius),
            ashFloat(uniforms, fallbackWeightEpsilon),
            2.0f,
            ashAnisotropyStrength(anisotropyMode),
            0,
            anisotropyMode != 0
        };
    }
    uint offset = uniforms[lutParameterOffset] + parameterIndex * 64 + (secondary ? 24 : 0);
    return ASHCandidateParameters{
        float(ashLoadU16(lut, offset + 2)) / 32767.0f,
        float(ashLoadU16(lut, offset + 4)) / 32767.0f,
        float(ashLoadU16(lut, offset + 6)) / 4096.0f,
        float(ashLoadU16(lut, offset + 8)) / 4096.0f,
        float(ashLoadU16(lut, offset + 10)) / 32767.0f,
        ashFloat(uniforms, fallbackLowPassRadius),
        as_type<float>(ashLoadU32(lut, offset + 14)),
        float(ashLoadU16(lut, offset + 12)) / 256.0f,
        ashAnisotropyStrength(anisotropyMode),
        int(char(lut[offset + 18])),
        anisotropyMode != 0
    };
}

inline float ashKernel(uint base, float value) {
    float distance = fabs(value);
    if (base == 0) {
        if (distance < 1.0f) {
            return 1.5f * distance * distance * distance
                - 2.5f * distance * distance + 1.0f;
        }
        if (distance < 2.0f) {
            return -0.5f * distance * distance * distance
                + 2.5f * distance * distance
                - 4.0f * distance + 2.0f;
        }
        return 0.0f;
    }
    if (distance <= 1.1920929e-7f) { return 1.0f; }
    if (distance >= 3.0f) { return 0.0f; }
    float first = sin(ashPi * value) / (ashPi * value);
    float scaled = value / 3.0f;
    float second = sin(ashPi * scaled) / (ashPi * scaled);
    return first * second;
}

struct ASHSampleEvaluation {
    float value;
    bool valid;
    bool sourceAligned;
};

inline ASHSampleEvaluation ashEvaluateCandidate(
    texture2d<float, access::read> source,
    uint channel,
    bool luma,
    float sourceX,
    float sourceY,
    uint descriptor,
    ASHCandidateParameters parameters,
    ASHStateSamplePacked state,
    bool exactSource,
    device const uint *uniforms
) {
    if (exactSource) {
        float value = ashReconstructionPlaneSample(
            source,
            int(rint(sourceX)),
            int(rint(sourceY)),
            channel,
            luma,
            uniforms
        );
        return ASHSampleEvaluation{clamp(value, 0.0f, 1.0f), true, true};
    }
    uint effectiveDescriptor = parameters.usesAnisotropy ? descriptor : (descriptor & ~2u);
    uint base = effectiveDescriptor & 1;
    bool anisotropic = (effectiveDescriptor & 2) != 0
        && ashFromQ15(state.magnitude_q15) >= parameters.minimumMagnitude
        && ashFromQ15(state.coherence_q15) >= parameters.minimumCoherence;
    float orientation = ashModuloPi(
        float(state.orientation_q15) / 32767.0f * ashPi
            + float(parameters.orientationDelta) * (ashPi / 4.0f)
    );
    float cosine = cos(orientation);
    float sine = sin(orientation);
    float tangentScale = anisotropic
        ? 1.0f + parameters.anisotropyStrength * ashFromQ15(state.coherence_q15)
        : 1.0f;
    float normalScale = anisotropic ? 1.0f / tangentScale : 1.0f;
    float baseRadius = base == 0 ? 2.0f : 3.0f;
    float radius = parameters.supportRadius;
    float coordinateScale = baseRadius / radius;
    float xRadius = radius * (fabs(cosine) * tangentScale + fabs(sine) * normalScale);
    float yRadius = radius * (fabs(sine) * tangentScale + fabs(cosine) * normalScale);
    int firstX = int(ceil(sourceX - xRadius));
    int lastX = int(floor(sourceX + xRadius));
    int firstY = int(ceil(sourceY - yRadius));
    int lastY = int(floor(sourceY + yRadius));
    float weighted = 0.0f;
    float weightTotal = 0.0f;
    float supportMinimum = INFINITY;
    float supportMaximum = -INFINITY;
    for (int row = firstY; row <= lastY; ++row) {
        for (int column = firstX; column <= lastX; ++column) {
            float offsetX = float(column) - sourceX;
            float offsetY = float(row) - sourceY;
            float kernelX = offsetX * coordinateScale;
            float kernelY = offsetY * coordinateScale;
            if (anisotropic) {
                kernelX = ((offsetX * cosine + offsetY * sine) / tangentScale)
                    * coordinateScale;
                kernelY = ((-offsetX * sine + offsetY * cosine) / normalScale)
                    * coordinateScale;
            }
            float weight = ashKernel(base, kernelX) * ashKernel(base, kernelY);
            if (!isfinite(weight)) { return ASHSampleEvaluation{0, false, false}; }
            if (fabs(weight) <= parameters.weightEpsilon) { continue; }
            float sample = ashReconstructionPlaneSample(
                source,
                column,
                row,
                channel,
                luma,
                uniforms
            );
            weighted += weight * sample;
            weightTotal += weight;
            supportMinimum = min(supportMinimum, sample);
            supportMaximum = max(supportMaximum, sample);
        }
    }
    if (!isfinite(weighted) || !isfinite(weightTotal)
        || fabs(weightTotal) <= parameters.weightEpsilon) {
        return ASHSampleEvaluation{0, false, false};
    }
    float value = weighted / weightTotal;
    if ((effectiveDescriptor & 4) != 0) {
        float lowWeighted = 0.0f;
        float lowTotal = 0.0f;
        int lowFirstX = int(ceil(sourceX - parameters.lowPassRadius));
        int lowLastX = int(floor(sourceX + parameters.lowPassRadius));
        int lowFirstY = int(ceil(sourceY - parameters.lowPassRadius));
        int lowLastY = int(floor(sourceY + parameters.lowPassRadius));
        for (int row = lowFirstY; row <= lowLastY; ++row) {
            for (int column = lowFirstX; column <= lowLastX; ++column) {
                float xWeight = max(0.0f, 1.0f - fabs(float(column) - sourceX) / parameters.lowPassRadius);
                float yWeight = max(0.0f, 1.0f - fabs(float(row) - sourceY) / parameters.lowPassRadius);
                float weight = xWeight * yWeight;
                if (weight <= parameters.weightEpsilon) { continue; }
                float sample = ashReconstructionPlaneSample(
                    source,
                    column,
                    row,
                    channel,
                    luma,
                    uniforms
                );
                lowWeighted += weight * sample;
                lowTotal += weight;
            }
        }
        if (fabs(lowTotal) <= parameters.weightEpsilon) {
            return ASHSampleEvaluation{0, false, false};
        }
        float risk = ashFromQ15(state.risk_q15);
        float riskScale = risk >= parameters.riskThreshold
            ? 0.0f
            : 1.0f - risk / parameters.riskThreshold;
        value += parameters.detailGain * riskScale * (value - lowWeighted / lowTotal);
    }
    float lower = supportMinimum;
    float upper = supportMaximum;
    if ((effectiveDescriptor & 8) != 0) {
        float allowance = parameters.relaxedAlpha * (upper - lower);
        lower -= allowance;
        upper += allowance;
    }
    value = clamp(value, lower, upper);
    return ASHSampleEvaluation{clamp(value, 0.0f, 1.0f), isfinite(value), false};
}

struct ASHDispatchEvaluation {
    float value;
    uint invocationCount;
    bool fallbackUsed;
    bool sourceAligned;
    bool fatal;
};

inline ASHDispatchEvaluation ashEvaluateDispatch(
    texture2d<float, access::read> source,
    uint channel,
    bool luma,
    float sourceX,
    float sourceY,
    uint phase,
    uint coordinatePolicy,
    ASHDispatchPacked dispatch,
    ASHStateSamplePacked state,
    device const uchar *lut,
    device const uint *uniforms,
    uint anisotropyMode
) {
    bool integralCoordinates = fabs(sourceX - rint(sourceX)) <= 1.0e-6f
        && fabs(sourceY - rint(sourceY)) <= 1.0e-6f;
    bool exact = coordinatePolicy == 1
        && phase == 0
        && (dispatch.flags & 2) != 0
        && integralCoordinates;
    bool dispatchFallback = (dispatch.flags & 0x8000) != 0;
    ASHCandidateParameters primaryParameters = ashParameters(
        lut,
        dispatch.parameter_index,
        false,
        anisotropyMode,
        uniforms,
        dispatchFallback
    );
    uint primaryDescriptor = dispatchFallback ? 0 : uint(dispatch.primary_descriptor);
    ASHSampleEvaluation primary = ashEvaluateCandidate(
        source,
        channel,
        luma,
        sourceX,
        sourceY,
        primaryDescriptor,
        primaryParameters,
        state,
        exact,
        uniforms
    );
    uint attempts = 1;
    if (primary.valid && (dispatch.flags & 1) == 0) {
        return ASHDispatchEvaluation{primary.value, attempts, false, primary.sourceAligned, false};
    }
    if (primary.valid && !dispatchFallback) {
        ++attempts;
        ASHCandidateParameters secondaryParameters = ashParameters(
            lut,
            dispatch.parameter_index,
            true,
            anisotropyMode,
            uniforms,
            false
        );
        ASHSampleEvaluation secondary = ashEvaluateCandidate(
            source,
            channel,
            luma,
            sourceX,
            sourceY,
            uint(dispatch.secondary_descriptor),
            secondaryParameters,
            state,
            exact,
            uniforms
        );
        if (secondary.valid) {
            float denominator = 65535.0f;
            float value = float(dispatch.primary_weight_q16) * primary.value / denominator
                + float(dispatch.secondary_weight_q16) * secondary.value / denominator;
            return ASHDispatchEvaluation{
                clamp(value, 0.0f, 1.0f),
                attempts,
                false,
                primary.sourceAligned && secondary.sourceAligned,
                false
            };
        }
    }

    ++attempts;
    ASHCandidateParameters fallbackParameters = ashParameters(
        lut,
        dispatch.parameter_index,
        false,
        anisotropyMode,
        uniforms,
        true
    );
    bool fallbackExact = coordinatePolicy == 1 && phase == 0 && integralCoordinates;
    ASHSampleEvaluation fallback = ashEvaluateCandidate(
        source,
        channel,
        luma,
        sourceX,
        sourceY,
        0,
        fallbackParameters,
        state,
        fallbackExact,
        uniforms
    );
    if (fallback.valid) {
        return ASHDispatchEvaluation{
            fallback.value,
            attempts,
            true,
            fallback.sourceAligned,
            false
        };
    }
    float nearest = ashReconstructionPlaneSample(
        source,
        int(rint(sourceX)),
        int(rint(sourceY)),
        channel,
        luma,
        uniforms
    );
    return ASHDispatchEvaluation{clamp(nearest, 0.0f, 1.0f), attempts, true, false, true};
}

inline float ashSourceCoordinate(uint index, uint sourceExtent, uint destinationExtent, uint policy) {
    if (policy == 1) {
        return float(index) * float(sourceExtent) / float(destinationExtent);
    }
    return (float(index) + 0.5f) * float(sourceExtent) / float(destinationExtent) - 0.5f;
}

inline float ashChromaSourceCoordinate(
    uint index,
    uint sourceExtent,
    uint destinationExtent,
    uint policy,
    uint siting
) {
    float base = ashSourceCoordinate(index, sourceExtent, destinationExtent, policy);
    float reference = policy == 0 ? 1.0f : 0.0f;
    return base + (float(siting) - reference)
        * (float(sourceExtent) - float(destinationExtent))
        / (4.0f * float(destinationExtent));
}

inline uint ashCellIndex(float coordinate, uint step, uint lastCell) {
    int value = int(floor((coordinate + 0.5f) / float(step)));
    return uint(clamp(value, 0, int(lastCell)));
}

inline float ashEncoded(float normalized, bool luma, uint range) {
    float minimum = range == 0 ? 16.0f : 0.0f;
    float maximum = range == 0 ? (luma ? 235.0f : 240.0f) : 255.0f;
    return (minimum + clamp(normalized, 0.0f, 1.0f) * (maximum - minimum)) / 255.0f;
}

inline ASHDispatchEvaluation ashP08EvaluateFixedDispatch(
    texture2d<float, access::read> source,
    uint channel,
    bool luma,
    float sourceX,
    float sourceY,
    ASHStateSamplePacked state,
    device const uint *uniforms,
    uint anisotropyMode
) {
    ASHCandidateParameters parameters = ASHCandidateParameters{
        ashP08FixedMinimumMagnitude,
        ashP08FixedMinimumCoherence,
        ashP08FixedDetailGain,
        ashP08FixedRelaxedAlpha,
        ashP08FixedRiskThreshold,
        ashP08FixedLowPassRadius,
        ashP08FixedWeightEpsilon,
        ashP08FixedSupportRadius,
        ashAnisotropyStrength(anisotropyMode),
        0,
        anisotropyMode != 0
    };
    ASHSampleEvaluation primary = ashEvaluateCandidate(
        source,
        channel,
        luma,
        sourceX,
        sourceY,
        ashP08FixedDescriptor,
        parameters,
        state,
        false,
        uniforms
    );
    if (primary.valid) {
        return ASHDispatchEvaluation{primary.value, 1, false, false, false};
    }
    ASHCandidateParameters fallbackParameters = ASHCandidateParameters{
        ashFloat(uniforms, fallbackMinimumMagnitude),
        ashFloat(uniforms, fallbackMinimumCoherence),
        0.0f,
        0.0f,
        ashFloat(uniforms, fallbackRiskThreshold),
        ashFloat(uniforms, fallbackLowPassRadius),
        ashFloat(uniforms, fallbackWeightEpsilon),
        2.0f,
        ashAnisotropyStrength(anisotropyMode),
        0,
        anisotropyMode != 0
    };
    ASHSampleEvaluation fallback = ashEvaluateCandidate(
        source,
        channel,
        luma,
        sourceX,
        sourceY,
        0,
        fallbackParameters,
        state,
        false,
        uniforms
    );
    if (fallback.valid) {
        return ASHDispatchEvaluation{fallback.value, 2, true, false, false};
    }
    float nearest = ashReconstructionPlaneSample(
        source,
        int(rint(sourceX)),
        int(rint(sourceY)),
        channel,
        luma,
        uniforms
    );
    return ASHDispatchEvaluation{clamp(nearest, 0.0f, 1.0f), 2, true, false, true};
}

kernel void ash_p08_fixed_reconstruct_luma(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    device const ASHStateSamplePacked *states [[buffer(0)]],
    device const uint *uniforms [[buffer(1)]],
    device atomic_uint *telemetry [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms[destinationLumaWidth] || gid.y >= uniforms[destinationLumaHeight]) {
        return;
    }
    uint policy = uniforms[lumaCoordinatePolicy];
    float sourceX = ashSourceCoordinate(
        gid.x,
        uniforms[sourceLumaWidth],
        uniforms[destinationLumaWidth],
        policy
    );
    float sourceY = ashSourceCoordinate(
        gid.y,
        uniforms[sourceLumaHeight],
        uniforms[destinationLumaHeight],
        policy
    );
    uint cellX = ashCellIndex(sourceX, uniforms[analysisStep], uniforms[analysisColumnCount] - 1);
    uint cellY = ashCellIndex(sourceY, uniforms[analysisStep], uniforms[analysisRowCount] - 1);
    uint cell = cellY * uniforms[analysisColumnCount] + cellX;
    ASHDispatchEvaluation result = ashP08EvaluateFixedDispatch(
        source,
        0,
        true,
        sourceX,
        sourceY,
        states[cell],
        uniforms,
        uniforms[lumaAnisotropyMode]
    );
    destination.write(float4(ashEncoded(result.value, true, uniforms[codeRange]), 0, 0, 1), gid);
    atomic_fetch_add_explicit(&telemetry[invocationCounter], result.invocationCount, memory_order_relaxed);
    atomic_fetch_add_explicit(&telemetry[lumaInvocationCounter], result.invocationCount, memory_order_relaxed);
    atomic_fetch_add_explicit(&telemetry[lumaOutputCounter], 1, memory_order_relaxed);
    if (result.fallbackUsed) {
        atomic_fetch_add_explicit(&telemetry[numericalFallbackCounter], 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&telemetry[lumaNumericalFallbackCounter], 1, memory_order_relaxed);
    }
    if (result.fatal) {
        atomic_fetch_add_explicit(&telemetry[fatalFaultCounter], 1, memory_order_relaxed);
    }
}

kernel void ash_p08_fixed_reconstruct_chroma(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    device const ASHStateSamplePacked *states [[buffer(0)]],
    device const uint *uniforms [[buffer(1)]],
    device atomic_uint *telemetry [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms[destinationChromaWidth] || gid.y >= uniforms[destinationChromaHeight]) {
        return;
    }
    uint policy = uniforms[chromaCoordinatePolicy];
    float sourceX = ashChromaSourceCoordinate(
        gid.x,
        uniforms[sourceChromaWidth],
        uniforms[destinationChromaWidth],
        policy,
        uniforms[chromaSitingX]
    );
    float sourceY = ashChromaSourceCoordinate(
        gid.y,
        uniforms[sourceChromaHeight],
        uniforms[destinationChromaHeight],
        policy,
        uniforms[chromaSitingY]
    );
    float lumaX = 2.0f * sourceX + float(uniforms[chromaSitingX]) * 0.5f;
    float lumaY = 2.0f * sourceY + float(uniforms[chromaSitingY]) * 0.5f;
    uint cellX = ashCellIndex(lumaX, uniforms[analysisStep], uniforms[analysisColumnCount] - 1);
    uint cellY = ashCellIndex(lumaY, uniforms[analysisStep], uniforms[analysisRowCount] - 1);
    uint cell = cellY * uniforms[analysisColumnCount] + cellX;
    ASHDispatchEvaluation cb = ashP08EvaluateFixedDispatch(
        source,
        0,
        false,
        sourceX,
        sourceY,
        states[cell],
        uniforms,
        uniforms[chromaAnisotropyMode]
    );
    ASHDispatchEvaluation cr = ashP08EvaluateFixedDispatch(
        source,
        1,
        false,
        sourceX,
        sourceY,
        states[cell],
        uniforms,
        uniforms[chromaAnisotropyMode]
    );
    destination.write(float4(
        ashEncoded(cb.value, false, uniforms[codeRange]),
        ashEncoded(cr.value, false, uniforms[codeRange]),
        0,
        1
    ), gid);
    uint invocationCount = cb.invocationCount + cr.invocationCount;
    atomic_fetch_add_explicit(&telemetry[invocationCounter], invocationCount, memory_order_relaxed);
    atomic_fetch_add_explicit(&telemetry[chromaInvocationCounter], invocationCount, memory_order_relaxed);
    atomic_fetch_add_explicit(&telemetry[chromaOutputCounter], 2, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &telemetry[numericalFallbackCounter],
        uint(cb.fallbackUsed) + uint(cr.fallbackUsed),
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &telemetry[fatalFaultCounter],
        uint(cb.fatal) + uint(cr.fatal),
        memory_order_relaxed
    );
}

kernel void ash_v3_reconstruct_luma(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    device const ASHStateSamplePacked *states [[buffer(0)]],
    device const ASHDispatchPacked *dispatches [[buffer(1)]],
    device const uchar *lut [[buffer(2)]],
    device const uint *uniforms [[buffer(3)]],
    device atomic_uint *telemetry [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms[destinationLumaWidth] || gid.y >= uniforms[destinationLumaHeight]) {
        return;
    }
    uint policy = uniforms[lumaCoordinatePolicy];
    float sourceX = ashSourceCoordinate(gid.x, uniforms[sourceLumaWidth], uniforms[destinationLumaWidth], policy);
    float sourceY = ashSourceCoordinate(gid.y, uniforms[sourceLumaHeight], uniforms[destinationLumaHeight], policy);
    uint cellX = ashCellIndex(sourceX, uniforms[analysisStep], uniforms[analysisColumnCount] - 1);
    uint cellY = ashCellIndex(sourceY, uniforms[analysisStep], uniforms[analysisRowCount] - 1);
    uint cell = cellY * uniforms[analysisColumnCount] + cellX;
    uint phase = (gid.y % uniforms[scaleNumerator]) * uniforms[scaleNumerator]
        + gid.x % uniforms[scaleNumerator];
    ASHDispatchPacked dispatch = dispatches[cell * uniforms[phaseCount] + phase];
    ASHDispatchEvaluation result = ashEvaluateDispatch(
        source,
        0,
        true,
        sourceX,
        sourceY,
        phase,
        policy,
        dispatch,
        states[cell],
        lut,
        uniforms,
        uniforms[lumaAnisotropyMode]
    );
    destination.write(float4(ashEncoded(result.value, true, uniforms[codeRange]), 0, 0, 1), gid);
    atomic_fetch_add_explicit(&telemetry[invocationCounter], result.invocationCount, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &telemetry[lumaInvocationCounter],
        result.invocationCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(&telemetry[lumaOutputCounter], 1, memory_order_relaxed);
    if ((dispatch.flags & 0x8000) != 0) {
        atomic_fetch_add_explicit(&telemetry[affineFallbackCounter], 1, memory_order_relaxed);
    }
    if (result.fallbackUsed) {
        atomic_fetch_add_explicit(&telemetry[numericalFallbackCounter], 1, memory_order_relaxed);
        atomic_fetch_add_explicit(
            &telemetry[lumaNumericalFallbackCounter],
            1,
            memory_order_relaxed
        );
    }
    if (result.sourceAligned) {
        atomic_fetch_add_explicit(&telemetry[sourceAlignedCounter], 1, memory_order_relaxed);
    }
    if (result.fatal) {
        atomic_fetch_add_explicit(&telemetry[fatalFaultCounter], 1, memory_order_relaxed);
    }
}

kernel void ash_v3_reconstruct_chroma(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    device const ASHStateSamplePacked *states [[buffer(0)]],
    device const ASHDispatchPacked *dispatches [[buffer(1)]],
    device const uchar *lut [[buffer(2)]],
    device const uint *uniforms [[buffer(3)]],
    device atomic_uint *telemetry [[buffer(4)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= uniforms[destinationChromaWidth] || gid.y >= uniforms[destinationChromaHeight]) {
        return;
    }
    uint policy = uniforms[chromaCoordinatePolicy];
    float sourceX = ashChromaSourceCoordinate(
        gid.x,
        uniforms[sourceChromaWidth],
        uniforms[destinationChromaWidth],
        policy,
        uniforms[chromaSitingX]
    );
    float sourceY = ashChromaSourceCoordinate(
        gid.y,
        uniforms[sourceChromaHeight],
        uniforms[destinationChromaHeight],
        policy,
        uniforms[chromaSitingY]
    );
    float lumaX = 2.0f * sourceX + float(uniforms[chromaSitingX]) * 0.5f;
    float lumaY = 2.0f * sourceY + float(uniforms[chromaSitingY]) * 0.5f;
    uint cellX = ashCellIndex(lumaX, uniforms[analysisStep], uniforms[analysisColumnCount] - 1);
    uint cellY = ashCellIndex(lumaY, uniforms[analysisStep], uniforms[analysisRowCount] - 1);
    uint cell = cellY * uniforms[analysisColumnCount] + cellX;
    uint phase = (gid.y % uniforms[scaleNumerator]) * uniforms[scaleNumerator]
        + gid.x % uniforms[scaleNumerator];
    uint planeOffset = uniforms[analysisColumnCount] * uniforms[analysisRowCount]
        * uniforms[phaseCount];
    ASHDispatchPacked dispatch = dispatches[planeOffset + cell * uniforms[phaseCount] + phase];
    ASHDispatchEvaluation cb = ashEvaluateDispatch(
        source, 0, false, sourceX, sourceY, phase, policy, dispatch, states[cell],
        lut, uniforms, uniforms[chromaAnisotropyMode]
    );
    ASHDispatchEvaluation cr = ashEvaluateDispatch(
        source, 1, false, sourceX, sourceY, phase, policy, dispatch, states[cell],
        lut, uniforms, uniforms[chromaAnisotropyMode]
    );
    destination.write(float4(
        ashEncoded(cb.value, false, uniforms[codeRange]),
        ashEncoded(cr.value, false, uniforms[codeRange]),
        0,
        1
    ), gid);
    atomic_fetch_add_explicit(
        &telemetry[invocationCounter],
        cb.invocationCount + cr.invocationCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &telemetry[chromaInvocationCounter],
        cb.invocationCount + cr.invocationCount,
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(&telemetry[chromaOutputCounter], 2, memory_order_relaxed);
    if ((dispatch.flags & 0x8000) != 0) {
        atomic_fetch_add_explicit(&telemetry[affineFallbackCounter], 2, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(
        &telemetry[numericalFallbackCounter],
        uint(cb.fallbackUsed) + uint(cr.fallbackUsed),
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &telemetry[sourceAlignedCounter],
        uint(cb.sourceAligned) + uint(cr.sourceAligned),
        memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &telemetry[fatalFaultCounter],
        uint(cb.fatal) + uint(cr.fatal),
        memory_order_relaxed
    );
}

kernel void ash_v3_finalize_reduction(
    device const atomic_uint *telemetry [[buffer(0)]],
    device uint *summary [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= 18) { return; }
    summary[gid] = atomic_load_explicit(&telemetry[counterBase + gid], memory_order_relaxed);
}

/// Parity-only state-packing probe. Production never creates this pipeline;
/// it exists so threshold and sector-tie semantics can be compared exactly
/// against the canonical CPU packer without a full-frame GPU readback.
kernel void ash_v3_state_pack_parity_probe(
    device const ASHStateProbeInput *inputs [[buffer(0)]],
    device const uint *uniforms [[buffer(1)]],
    device ushort *states [[buffer(2)]],
    constant uint &count [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= count) { return; }
    ASHStateProbeInput input = inputs[gid];
    float edgeThreshold = (ashFloat(uniforms, edgeLow) + ashFloat(uniforms, edgeHigh)) * 0.5f;
    float coherenceThreshold = (ashFloat(uniforms, coherenceLow) + ashFloat(uniforms, coherenceHigh)) * 0.5f;
    float textureThreshold = (ashFloat(uniforms, textureLow) + ashFloat(uniforms, textureHigh)) * 0.5f;
    float riskThreshold = (ashFloat(uniforms, riskLow) + ashFloat(uniforms, riskHigh)) * 0.5f;
    float chromaThreshold = (ashFloat(uniforms, chromaLow) + ashFloat(uniforms, chromaHigh)) * 0.5f;
    uint edge = input.magnitude >= edgeThreshold;
    uint orientation = edge != 0 ? ashSector(input.tangent) : 0;
    uint payload = ((orientation & 1) << 7)
        | (((orientation >> 1) & 1) << 6)
        | (edge << 5)
        | (uint(input.coherence >= coherenceThreshold) << 4)
        | (uint(input.texture >= textureThreshold) << 3)
        | (uint(input.risk >= riskThreshold) << 2)
        | uint(input.chroma_alignment >= chromaThreshold);
    states[gid] = ushort((payload << 1) | (popcount(payload) & 1));
}

/// Test-owned controlled reconstruction probe. The production runtime never
/// creates this pipeline. Each invocation performs an immutable LUT lookup and
/// executes one declared descriptor for one route/plane/phase row.
kernel void ash_v3_descriptor_parity_probe(
    texture2d<float, access::read> source_luma [[texture(0)]],
    texture2d<float, access::read> source_chroma [[texture(1)]],
    device const ASHStateSamplePacked *probe_state [[buffer(0)]],
    device const uchar *lut [[buffer(1)]],
    device const uint *uniforms [[buffer(2)]],
    device ASHDescriptorParityProbeOutput *outputs [[buffer(3)]],
    uint gid [[thread_position_in_grid]]
) {
    uint perPlane = uniforms[phaseCount] * 16;
    if (gid >= perPlane * 2) { return; }
    uint plane = gid / perPlane;
    uint local = gid - plane * perPlane;
    uint phase = local / 16;
    uint descriptor = local - phase * 16;
    ASHStateSamplePacked state = probe_state[0];
    uint logicalIndex = plane * (uniforms[phaseCount] * 4 * 256)
        + phase * (4 * 256)
        + (uint(state.state) >> 1);
    uint offset = uniforms[lutEntryOffset] + logicalIndex * 24;

    ASHDispatchPacked dispatch{};
    dispatch.primary_affine_state = ashLoadU16(lut, offset);
    bool controlledTwoCandidate = uniforms[29] != 0;
    dispatch.secondary_affine_state = controlledTwoCandidate
        ? ashLoadU16(lut, offset + 2)
        : 0xffff;
    dispatch.primary_descriptor = controlledTwoCandidate
        ? lut[offset + 4]
        : uchar(descriptor);
    dispatch.secondary_descriptor = controlledTwoCandidate ? lut[offset + 5] : 0xff;
    dispatch.primary_message = lut[offset + 6];
    dispatch.secondary_message = 0xff;
    dispatch.primary_weight_q16 = controlledTwoCandidate
        ? ashLoadU16(lut, offset + 8)
        : 0xffff;
    dispatch.secondary_weight_q16 = controlledTwoCandidate
        ? ashLoadU16(lut, offset + 10)
        : 0;
    dispatch.margin_q16 = ashLoadU16(lut, offset + 12);
    dispatch.flags = controlledTwoCandidate ? ashLoadU16(lut, offset + 14) : 0;
    dispatch.parameter_index = ashLoadU32(lut, offset + 16);
    dispatch.provenance_crc32 = ashLoadU32(lut, offset + 20);

    uint numerator = uniforms[scaleNumerator];
    uint horizontalPhase = phase % numerator;
    uint verticalPhase = phase / numerator;
    float sourceX = 3.0f
        + float(horizontalPhase * uniforms[scaleDenominator]) / float(numerator);
    float sourceY = 3.0f
        + float(verticalPhase * uniforms[scaleDenominator]) / float(numerator);
    ASHDispatchEvaluation first;
    ASHDispatchEvaluation second = ASHDispatchEvaluation{0, 0, false, false, false};
    if (plane == 0) {
        first = ashEvaluateDispatch(
            source_luma, 0, true, sourceX, sourceY, phase, 0, dispatch, state,
            lut, uniforms, uniforms[lumaAnisotropyMode]
        );
    } else {
        first = ashEvaluateDispatch(
            source_chroma, 0, false, sourceX, sourceY, phase, 0, dispatch, state,
            lut, uniforms, uniforms[chromaAnisotropyMode]
        );
        second = ashEvaluateDispatch(
            source_chroma, 1, false, sourceX, sourceY, phase, 0, dispatch, state,
            lut, uniforms, uniforms[chromaAnisotropyMode]
        );
    }

    ASHDescriptorParityProbeOutput output{};
    output.value0_bits = as_type<uint>(first.value);
    output.value1_bits = as_type<uint>(second.value);
    output.state = uint(state.state);
    output.primary_message = uint(dispatch.primary_message);
    output.descriptor = descriptor;
    output.phase = phase;
    output.plane = plane;
    output.invocation_count = first.invocationCount + second.invocationCount;
    output.fallback_count = uint(first.fallbackUsed) + uint(second.fallbackUsed);
    output.fatal_count = uint(first.fatal) + uint(second.fatal);
    output.lut_word_0 = ashLoadU32(lut, offset);
    output.lut_word_1 = ashLoadU32(lut, offset + 4);
    output.lut_word_2 = ashLoadU32(lut, offset + 8);
    output.lut_word_3 = ashLoadU32(lut, offset + 12);
    output.lut_word_4 = ashLoadU32(lut, offset + 16);
    output.lut_word_5 = ashLoadU32(lut, offset + 20);
    outputs[gid] = output;
}
