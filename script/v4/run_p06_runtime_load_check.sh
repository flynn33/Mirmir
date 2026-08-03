#!/bin/zsh
set -euo pipefail

if (( $# != 4 )); then
    print -u2 \
        "usage: $0 <bundle> <manifest-sha256> <source-revision> <builder-sha256>"
    exit 64
fi

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
temporary_directory="$(
    mktemp -d "${TMPDIR:-/tmp}/mirmir-p06-load-check-build.XXXXXX"
)"

cleanup_temporary_directory() {
    case "${temporary_directory}" in
        */mirmir-p06-load-check-build.*)
            rm -rf -- "${temporary_directory}"
            ;;
        *)
            print -u2 "Refusing to clean unexpected temporary path: ${temporary_directory}"
            ;;
    esac
}
trap cleanup_temporary_directory EXIT

production_sources=(
    "Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift"
    "Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift"
    "Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift"
    "Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCoreV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift"
    "Mirmir/Domain/CanonicalMediaStateV4.swift"
    "Mirmir/Domain/MediaTrackGraphV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHRuntimeManifestV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHMetalLibraryValidatorV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHMeasurementContractV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHDepthFourBranchProgramV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHP06RuntimeBundleV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHExecutionPlanV4.swift"
    "Mirmir/Modules/UpscalerEngine/ASH/ASHDiagnosticEnvelopeV4.swift"
)
absolute_sources=()
for source in "${production_sources[@]}"; do
    absolute_sources+=("${repository_root}/${source}")
done

xcrun swiftc \
    -warnings-as-errors \
    "${absolute_sources[@]}" \
    "${script_directory}/P06RuntimeLoadCheckMain.swift" \
    -o "${temporary_directory}/p06-runtime-load-check"

"${temporary_directory}/p06-runtime-load-check" "$@"
