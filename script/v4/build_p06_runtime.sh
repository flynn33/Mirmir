#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
builder_temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-p06-builder.XXXXXX")"

cleanup_builder_temporary_directory() {
    case "${builder_temporary_directory}" in
        */mirmir-p06-builder.*)
            rm -rf -- "${builder_temporary_directory}"
            ;;
        *)
            print -u2 "Refusing to clean unexpected temporary path: ${builder_temporary_directory}"
            ;;
    esac
}
trap cleanup_builder_temporary_directory EXIT

xcrun swiftc \
    -warnings-as-errors \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCode.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCoreV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHCanonicalJSONV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHRuntimeManifestV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHMeasurementContractV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHDepthFourBranchProgramV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHP06RuntimeBundleV4.swift" \
    "${repository_root}/Mirmir/Modules/UpscalerEngine/ASH/ASHMetalLibraryValidatorV4.swift" \
    "${script_directory}/P06RuntimeBuilderMain.swift" \
    -o "${builder_temporary_directory}/p06-runtime-builder"

"${builder_temporary_directory}/p06-runtime-builder" "$@"
