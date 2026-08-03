#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"

artifact_output=""
bundle_output=""
while (( $# > 0 )); do
    case "$1" in
        --artifacts)
            if (( $# < 2 )); then
                print -u2 "Missing value for --artifacts"
                exit 64
            fi
            artifact_output="$2"
            shift 2
            ;;
        --output)
            if (( $# < 2 )); then
                print -u2 "Missing value for --output"
                exit 64
            fi
            bundle_output="$2"
            shift 2
            ;;
        *)
            print -u2 "Unknown option: $1"
            exit 64
            ;;
    esac
done
if [[ -z "${artifact_output}" || -z "${bundle_output}" ]]; then
    print -u2 "usage: $0 --artifacts <new-input-directory> --output <new-bundle-directory>"
    exit 64
fi
artifact_output="${artifact_output:A}"
bundle_output="${bundle_output:A}"
if [[ "${artifact_output}" == "${bundle_output}" ]]; then
    print -u2 "Artifact input and runtime bundle outputs must differ"
    exit 64
fi
for destination in "${artifact_output}" "${bundle_output}"; do
    if [[ -e "${destination}" ]]; then
        print -u2 "Output already exists: ${destination}"
        exit 64
    fi
    if [[ ! -d "${destination:h}" ]]; then
        print -u2 "Output parent is not a directory: ${destination:h}"
        exit 64
    fi
done

build_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-p06-candidate.XXXXXX")"
cleanup_build_temporary_directory() {
    case "${build_temporary_directory}" in
        */mirmir-p06-candidate.*)
            rm -rf -- "${build_temporary_directory}"
            ;;
        *)
            print -u2 "Refusing to clean unexpected temporary path: ${build_temporary_directory}"
            ;;
    esac
}
trap cleanup_build_temporary_directory EXIT

metal_language="metal3.2"
deployment_target="macos-15.4"
target_triple="$(uname -m)-apple-macos15.4"
swift_compiler_identity="$(xcrun swiftc --version 2>&1 | head -n 1)"
metal_compiler_identity="$(xcrun -sdk macosx metal --version 2>&1 | head -n 1)"
sdk_build_identity="macosx$(xcrun --sdk macosx --show-sdk-version)-$(xcrun --sdk macosx --show-sdk-build-version)"

metal_source="${repository_root}/Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal"
xcrun -sdk macosx metal \
    -c \
    -mmacosx-version-min=15.4 \
    -std=metal3.2 \
    "${metal_source}" \
    -o "${build_temporary_directory}/FixedPointMetalKernelsV4.air"
xcrun -sdk macosx metallib \
    "${build_temporary_directory}/FixedPointMetalKernelsV4.air" \
    -o "${build_temporary_directory}/ash-p06.metallib"

production_sources=(
    "Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift"
    "Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift"
    "Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift"
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCoreV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHRuntimeManifestV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHMeasurementContractV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHDepthFourBranchProgramV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHP06RuntimeBundleV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHExecutionPlanV4.swift"
)
builder_sources=(
    "script/v4/P06RuntimeInputGeneratorMain.swift"
    "script/v4/P06RuntimeBuilderMain.swift"
    "script/v4/build_p06_runtime.sh"
    "script/v4/build_p06_semantic_candidate.sh"
)

source_revision="$({
    cd "${repository_root}"
    shasum -a 256 "${production_sources[@]}"
} | shasum -a 256 | awk '{print $1}')"
builder_source_sha256="$({
    cd "${repository_root}"
    shasum -a 256 "${builder_sources[@]}"
} | shasum -a 256 | awk '{print $1}')"
build_parameters_sha256="$(print -r -- \
    "status=semantic_candidate\nmetal_language=${metal_language}\ndeployment_target=${deployment_target}\ntarget_triple=${target_triple}\nsdk=${sdk_build_identity}" \
    | shasum -a 256 | awk '{print $1}')"

swift_sources=(
    "${repository_root}/Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCoreV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHRuntimeManifestV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHMeasurementContractV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHDepthFourBranchProgramV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHP06RuntimeBundleV4.swift"
)
xcrun swiftc -warnings-as-errors \
    "${swift_sources[@]}" \
    "${script_directory}/P06RuntimeInputGeneratorMain.swift" \
    -o "${build_temporary_directory}/p06-input-generator"
xcrun swiftc -warnings-as-errors \
    "${swift_sources[@]}" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHMetalLibraryValidatorV4.swift" \
    "${script_directory}/P06RuntimeBuilderMain.swift" \
    -o "${build_temporary_directory}/p06-runtime-builder"

"${build_temporary_directory}/p06-input-generator" \
    --repository-root "${repository_root}" \
    --metal-library "${build_temporary_directory}/ash-p06.metallib" \
    --output "${artifact_output}" \
    --swift-compiler "${swift_compiler_identity}" \
    --metal-compiler "${metal_compiler_identity}" \
    --metal-language "${metal_language}" \
    --sdk-build "${sdk_build_identity}" \
    --deployment-target "${deployment_target}" \
    --target-triple "${target_triple}"

"${build_temporary_directory}/p06-runtime-builder" \
    --input "${artifact_output}" \
    --output "${bundle_output}" \
    --status semantic_candidate \
    --source-revision "${source_revision}" \
    --builder-id ash-p06-semantic-candidate-builder-v4-2 \
    --builder-source-sha256 "${builder_source_sha256}" \
    --build-parameters-sha256 "${build_parameters_sha256}" \
    --swift-compiler "${swift_compiler_identity}" \
    --metal-compiler "${metal_compiler_identity}" \
    --metal-language "${metal_language}" \
    --sdk-build "${sdk_build_identity}" \
    --deployment-target "${deployment_target}" \
    --target-triple "${target_triple}"
