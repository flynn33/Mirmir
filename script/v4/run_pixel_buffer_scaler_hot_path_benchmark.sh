#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
engine_source_root="${1:-$repository_root}"
benchmark_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-pixel-buffer-benchmark.XXXXXX")"
engine_source_paths=(
    Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift
    Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift
    Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift
    Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift
    Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift
    Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal
    Mirmir/Modules/UpscalerEngine/PixelLayoutV4.swift
    Mirmir/Modules/UpscalerEngine/HDRMetadataV4.swift
    Mirmir/Modules/UpscalerEngine/AVFoundationHDRMetadataAdapterV4.swift
    Mirmir/Modules/UpscalerEngine/FixedPointPixelBufferScalerV4.swift
)

cleanup_benchmark_temporary_directory() {
    case "${benchmark_temporary_directory}" in
        */mirmir-v4-pixel-buffer-benchmark.*)
            rm -rf -- "${benchmark_temporary_directory}"
            ;;
        *)
            print -u2 "Refusing to clean unexpected temporary path: ${benchmark_temporary_directory}"
            ;;
    esac
}
trap cleanup_benchmark_temporary_directory EXIT

engine_source_manifest=""
for relative_path in "${engine_source_paths[@]}"; do
    source_path="${engine_source_root}/${relative_path}"
    [[ -f "${source_path}" ]] || {
        print -u2 "Missing benchmark engine source: ${source_path}"
        exit 66
    }
    source_sha256="$(shasum -a 256 "${source_path}" | awk '{print $1}')"
    engine_source_manifest+="${relative_path} ${source_sha256}"$'\n'
done
engine_source_sha256="$(
    print -rn -- "${engine_source_manifest}" | shasum -a 256 | awk '{print $1}'
)"
benchmark_harness_sha256="$(
    shasum -a 256 "${script_directory}/PixelBufferScalerHotPathBenchmarkMain.swift" \
        | awk '{print $1}'
)"
runner_source_sha256="$(
    shasum -a 256 "${script_directory}/run_pixel_buffer_scaler_hot_path_benchmark.sh" \
        | awk '{print $1}'
)"

xcrun metal \
    -c \
    -O3 \
    -mmacosx-version-min=15.4 \
    -std=metal3.2 \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal" \
    -o "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.air"

xcrun metallib \
    "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.air" \
    -o "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.metallib"

xcrun swiftc \
    -target "$(uname -m)-apple-macos15.4" \
    -O \
    -whole-module-optimization \
    -warnings-as-errors \
    -strict-concurrency=complete \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/PixelLayoutV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/HDRMetadataV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/AVFoundationHDRMetadataAdapterV4.swift" \
    "${engine_source_root}/Mirmir/Modules/UpscalerEngine/FixedPointPixelBufferScalerV4.swift" \
    "${script_directory}/PixelBufferScalerHotPathBenchmarkMain.swift" \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework CryptoKit \
    -framework Metal \
    -framework VideoToolbox \
    -o "${benchmark_temporary_directory}/pixel-buffer-scaler-hot-path-benchmark"

benchmark_executable="${benchmark_temporary_directory}/pixel-buffer-scaler-hot-path-benchmark"
metal_library="${benchmark_temporary_directory}/FixedPointMetalKernelsV4.metallib"
executable_sha256="$(shasum -a 256 "${benchmark_executable}" | awk '{print $1}')"
metal_library_sha256="$(shasum -a 256 "${metal_library}" | awk '{print $1}')"

MIRMIR_V4_BENCHMARK_HARDWARE_MODEL="$(sysctl -n hw.model)" \
MIRMIR_V4_BENCHMARK_PROCESSOR="$(sysctl -n machdep.cpu.brand_string)" \
MIRMIR_V4_BENCHMARK_MEMORY_BYTES="$(sysctl -n hw.memsize)" \
MIRMIR_V4_BENCHMARK_MACOS_VERSION="$(sw_vers -productVersion)" \
MIRMIR_V4_BENCHMARK_MACOS_BUILD="$(sw_vers -buildVersion)" \
MIRMIR_V4_BENCHMARK_XCODE_VERSION="$(xcodebuild -version)" \
MIRMIR_V4_BENCHMARK_SWIFT_VERSION="$(swift --version)" \
MIRMIR_V4_BENCHMARK_HARNESS_SHA256="${benchmark_harness_sha256}" \
MIRMIR_V4_BENCHMARK_RUNNER_SHA256="${runner_source_sha256}" \
MIRMIR_V4_BENCHMARK_ENGINE_SOURCE_SHA256="${engine_source_sha256}" \
MIRMIR_V4_BENCHMARK_ENGINE_SOURCE_MANIFEST="${engine_source_manifest}" \
MIRMIR_V4_BENCHMARK_EXECUTABLE_SHA256="${executable_sha256}" \
MIRMIR_V4_BENCHMARK_METALLIB_SHA256="${metal_library_sha256}" \
"${benchmark_executable}" \
    "${benchmark_temporary_directory}/FixedPointMetalKernelsV4.metallib"
