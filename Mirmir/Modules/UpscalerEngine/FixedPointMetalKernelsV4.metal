#include <metal_stdlib>
using namespace metal;

struct FixedPointPositionV4 {
    int sourceBase;
    uint kernelIndex;
};

struct FixedPointUniformsV4 {
    uint sourceWidth;
    uint sourceHeight;
    uint sourceRowStride;
    uint targetWidth;
    uint targetHeight;
    uint horizontalKernelCount;
    uint verticalKernelCount;
    uint horizontalBorderRule;
    uint verticalBorderRule;
    uint minimumCode;
    uint maximumCode;
    uint fractionalBits;
};

inline int ashV4BorderIndex(int index, uint count, uint rule) {
    if (rule == 0u) {
        return clamp(index, 0, int(count) - 1);
    }
    if (count <= 1u) {
        return 0;
    }
    int period = 2 * (int(count) - 1);
    int reflected = index % period;
    if (reflected < 0) {
        reflected += period;
    }
    return reflected < int(count) ? reflected : period - reflected;
}

inline long ashV4RoundTiesToEven(long value, uint fractionalBits) {
    long denominator = long(1) << fractionalBits;
    long quotient = value / denominator;
    long remainder = value % denominator;
    if (remainder < 0) {
        quotient -= 1;
        remainder += denominator;
    }
    long doubledRemainder = remainder * 2;
    if (doubledRemainder < denominator) {
        return quotient;
    }
    if (doubledRemainder > denominator) {
        return quotient + 1;
    }
    return (quotient & 1) == 0 ? quotient : quotient + 1;
}

kernel void ashFixedPointScaleV4(
    const device ushort *source [[buffer(0)]],
    const device FixedPointPositionV4 *horizontalPositions [[buffer(1)]],
    const device FixedPointPositionV4 *verticalPositions [[buffer(2)]],
    const device int *horizontalCoefficients [[buffer(3)]],
    const device int *verticalCoefficients [[buffer(4)]],
    device ushort *output [[buffer(5)]],
    constant FixedPointUniformsV4 &uniforms [[buffer(6)]],
    uint2 destination [[thread_position_in_grid]]
) {
    if (destination.x >= uniforms.targetWidth
        || destination.y >= uniforms.targetHeight) {
        return;
    }

    FixedPointPositionV4 horizontal = horizontalPositions[destination.x];
    FixedPointPositionV4 vertical = verticalPositions[destination.y];
    if (horizontal.kernelIndex >= uniforms.horizontalKernelCount
        || vertical.kernelIndex >= uniforms.verticalKernelCount) {
        output[destination.y * uniforms.targetWidth + destination.x]
            = ushort(uniforms.minimumCode);
        return;
    }

    const device int *horizontalKernel = horizontalCoefficients
        + horizontal.kernelIndex * 4u;
    const device int *verticalKernel = verticalCoefficients
        + vertical.kernelIndex * 4u;
    constexpr int tapOffsets[4] = {-1, 0, 1, 2};
    long accumulator = 0;

    for (uint verticalTap = 0; verticalTap < 4u; ++verticalTap) {
        int sourceY = ashV4BorderIndex(
            vertical.sourceBase + tapOffsets[verticalTap],
            uniforms.sourceHeight,
            uniforms.verticalBorderRule
        );
        long horizontalAccumulator = 0;
        for (uint horizontalTap = 0; horizontalTap < 4u; ++horizontalTap) {
            int sourceX = ashV4BorderIndex(
                horizontal.sourceBase + tapOffsets[horizontalTap],
                uniforms.sourceWidth,
                uniforms.horizontalBorderRule
            );
            ushort sample = source[
                uint(sourceY) * uniforms.sourceRowStride + uint(sourceX)
            ];
            horizontalAccumulator += long(sample)
                * long(horizontalKernel[horizontalTap]);
        }
        accumulator += horizontalAccumulator * long(verticalKernel[verticalTap]);
    }

    long rounded = ashV4RoundTiesToEven(
        accumulator,
        uniforms.fractionalBits * 2u
    );
    long clamped = clamp(
        rounded,
        long(uniforms.minimumCode),
        long(uniforms.maximumCode)
    );
    output[destination.y * uniforms.targetWidth + destination.x]
        = ushort(clamped);
}
