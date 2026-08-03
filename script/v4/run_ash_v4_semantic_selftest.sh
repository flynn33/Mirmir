#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
xcode_developer_directory="$(xcode-select -p)"
xctest_developer_directory="${xcode_developer_directory}/Platforms/MacOSX.platform/Developer"
selftest_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-selftest-build.XXXXXX")"

cleanup_selftest_temporary_directory() {
    case "${selftest_temporary_directory}" in
        */mirmir-v4-selftest-build.*)
            rm -rf -- "${selftest_temporary_directory}"
            ;;
        *)
            print -u2 "Refusing to clean unexpected temporary path: ${selftest_temporary_directory}"
            ;;
    esac
}
trap cleanup_selftest_temporary_directory EXIT

production_sources=(
    "${repository_root}/Mirmir/Modules/UpscalerEngine/RationalPresentationGeometryV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/SpatialScalePlanV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/FixedPointKernelV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCoreV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift"
    "${repository_root}/Mirmir/Domain/CanonicalMediaStateV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHRuntimeManifestV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHMetalLibraryValidatorV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHMeasurementContractV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHDepthFourBranchProgramV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHP06RuntimeBundleV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHExecutionPlanV4.swift"
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHDiagnosticEnvelopeV4.swift"
)

xcrun swiftc \
    -warnings-as-errors \
    -enable-testing \
    -emit-library \
    -emit-module \
    -module-name Mirmir \
    "${production_sources[@]}" \
    -emit-module-path "${selftest_temporary_directory}/Mirmir.swiftmodule" \
    -o "${selftest_temporary_directory}/libMirmir.dylib"

xcrun swiftc \
    -warnings-as-errors \
    -typecheck \
    -I "${selftest_temporary_directory}" \
    -I "${xctest_developer_directory}/usr/lib" \
    -F "${xctest_developer_directory}/Library/Frameworks" \
    "${repository_root}/MirmirTests/ASHV4SemanticArtifactTestSupport.swift" \
    "${repository_root}/MirmirTests/ASHV4SemanticArtifactTests.swift"

xcrun swiftc \
    -warnings-as-errors \
    -I "${selftest_temporary_directory}" \
    -L "${selftest_temporary_directory}" \
    -lMirmir \
    -Xlinker -rpath \
    -Xlinker "${selftest_temporary_directory}" \
    "${repository_root}/MirmirTests/ASHV4SemanticArtifactTestSupport.swift" \
    "${script_directory}/ASHV4SemanticSelfTestMain.swift" \
    -o "${selftest_temporary_directory}/ash-v4-semantic-selftest"

"${selftest_temporary_directory}/ash-v4-semantic-selftest"
