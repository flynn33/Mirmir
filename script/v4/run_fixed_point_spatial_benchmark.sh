#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
benchmark_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-fixed-benchmark.XXXXXX")"
locked_source="${repository_root}/docs/v4/evidence/v3-p05-baseline-2026-08-02/420f-direct_2x-radial_detail-source.bin"
expected_source_sha256="87dc513caa392105a02425704e15b9fbd0fa81f92c1a552daa37550822225024"

cleanup_benchmark_temporary_directory() {
    case "${benchmark_temporary_directory}" in
        */mirmir-v4-fixed-benchmark.*)
            rm -rf -- "${benchmark_temporary_directory}"
            ;;
        *)
            print -u2 "Refusing to clean unexpected temporary path: ${benchmark_temporary_directory}"
            ;;
    esac
}
trap cleanup_benchmark_temporary_directory EXIT

actual_source_sha256="$(shasum -a 256 "${locked_source}" | awk '{print $1}')"
if [[ "${actual_source_sha256}" != "${expected_source_sha256}" ]]; then
    print -u2 "Locked source SHA-256 mismatch: ${actual_source_sha256}"
    exit 1
fi

xcrun metal \
    -c \
    -O3 \
    -mmacosx-version-min=15.4 \
    -std=metal3.2 \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal" \
    -o "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.air"

xcrun metallib \
    "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.air" \
    -o "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.metallib"

xcrun swiftc \
    -O \
    -whole-module-optimization \
    -warnings-as-errors \
    -strict-concurrency=complete \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift" \
    "${script_directory}/FixedPointSpatialBenchmarkMain.swift" \
    -framework Metal \
    -o "${benchmark_temporary_directory}/fixed-point-spatial-benchmark"

"${benchmark_temporary_directory}/fixed-point-spatial-benchmark" \
    "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.metallib" \
    "${locked_source}"
