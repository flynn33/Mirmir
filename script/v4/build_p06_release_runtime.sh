#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"

artifact_output=""
bundle_output=""
provenance_output=""
while (( $# > 0 )); do
    case "$1" in
        --artifacts)
            (( $# >= 2 )) || {
                print -u2 "Missing value for --artifacts"
                exit 64
            }
            artifact_output="$2"
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || {
                print -u2 "Missing value for --output"
                exit 64
            }
            bundle_output="$2"
            shift 2
            ;;
        --provenance)
            (( $# >= 2 )) || {
                print -u2 "Missing value for --provenance"
                exit 64
            }
            provenance_output="$2"
            shift 2
            ;;
        *)
            print -u2 "Unknown option: $1"
            exit 64
            ;;
    esac
done
if [[ -z "${artifact_output}" || -z "${bundle_output}" ]]; then
    print -u2 \
        "usage: $0 --artifacts <new-input-directory> --output <new-bundle-directory> [--provenance <new-directory>]"
    exit 64
fi
artifact_output="${artifact_output:A}"
bundle_output="${bundle_output:A}"
if [[ -n "${provenance_output}" ]]; then
    provenance_output="${provenance_output:A}"
fi
if [[ "${artifact_output}" == "${bundle_output}" ]]; then
    print -u2 "Artifact input and runtime bundle outputs must differ"
    exit 64
fi
destinations=("${artifact_output}" "${bundle_output}")
if [[ -n "${provenance_output}" ]]; then
    if [[ "${provenance_output}" == "${artifact_output}" \
        || "${provenance_output}" == "${bundle_output}" ]]; then
        print -u2 "Provenance output must differ from artifact and runtime outputs"
        exit 64
    fi
    destinations+=("${provenance_output}")
fi
for destination in "${destinations[@]}"; do
    if [[ -e "${destination}" ]]; then
        print -u2 "Output already exists: ${destination}"
        exit 64
    fi
    if [[ ! -d "${destination:h}" ]]; then
        print -u2 "Output parent is not a directory: ${destination:h}"
        exit 64
    fi
done

release_temporary_directory="$(
    mktemp -d "${TMPDIR:-/tmp}/mirmir-p06-release.XXXXXX"
)"
cleanup_release_temporary_directory() {
    case "${release_temporary_directory}" in
        */mirmir-p06-release.*)
            rm -rf -- "${release_temporary_directory}"
            ;;
        *)
            print -u2 \
                "Refusing to clean unexpected temporary path: ${release_temporary_directory}"
            ;;
    esac
}
trap cleanup_release_temporary_directory EXIT

first_artifacts="${release_temporary_directory}/first-artifacts"
first_candidate="${release_temporary_directory}/first-candidate"
second_artifacts="${release_temporary_directory}/second-artifacts"
second_candidate="${release_temporary_directory}/second-candidate"

"${script_directory}/build_p06_semantic_candidate.sh" \
    --artifacts "${first_artifacts}" \
    --output "${first_candidate}" \
    >"${release_temporary_directory}/first-build.log"
"${script_directory}/build_p06_semantic_candidate.sh" \
    --artifacts "${second_artifacts}" \
    --output "${second_candidate}" \
    >"${release_temporary_directory}/second-build.log"

if ! diff -rq -- "${first_artifacts}" "${second_artifacts}" \
    >"${release_temporary_directory}/artifact-diff.log"; then
    print -u2 "Independent P06 artifact builds were not byte-identical"
    cat "${release_temporary_directory}/artifact-diff.log" >&2
    exit 65
fi

# The source contract is a closed inventory of the complete v4 engine, media,
# and durable-workflow implementation. The identity tool fails if a new V4
# production source appears under a covered root without being added to that
# inventory. It normalizes only the three deployment trust-root assignments,
# which authenticate the result and would otherwise make the identity circular.
source_contract="${script_directory}/p06-source-provenance-v1.json"
source_identity_tool="${script_directory}/p06_source_identity_v4.py"
builder_sources=(
    "script/v4/P06RuntimeInputGeneratorMain.swift"
    "script/v4/P06RuntimeBuilderMain.swift"
    "script/v4/build_p06_runtime.sh"
    "script/v4/build_p06_semantic_candidate.sh"
    "script/v4/build_p06_release_runtime.sh"
    "script/v4/p06-source-provenance-v1.json"
    "script/v4/p06_source_identity_v4.py"
)

for relative_path in "${builder_sources[@]}"; do
    if [[ ! -f "${repository_root}/${relative_path}" ]]; then
        print -u2 "Missing locked P06 source: ${relative_path}"
        exit 66
    fi
done

source_revision="$(
    python3 "${source_identity_tool}" identity \
        --repository "${repository_root}" \
        --contract "${source_contract}"
)"
builder_source_sha256="$({
    cd "${repository_root}"
    shasum -a 256 "${builder_sources[@]}"
} | shasum -a 256 | awk '{print $1}')"
artifact_set_sha256="$({
    cd "${first_artifacts}"
    find . -type f -print0 | sort -z | xargs -0 shasum -a 256
} | shasum -a 256 | awk '{print $1}')"

metal_language="metal3.2"
deployment_target="macos-15.4"
target_triple="$(uname -m)-apple-macos15.4"
swift_compiler_identity="$(xcrun swiftc --version 2>&1 | head -n 1)"
metal_compiler_identity="$(
    xcrun -sdk macosx metal --version 2>&1 | head -n 1
)"
sdk_build_identity="macosx$(xcrun --sdk macosx --show-sdk-version)-$(
    xcrun --sdk macosx --show-sdk-build-version
)"
build_parameters_sha256="$(print -r -- \
    "status=release_qualified
metal_language=${metal_language}
deployment_target=${deployment_target}
target_triple=${target_triple}
sdk=${sdk_build_identity}
artifact_set_sha256=${artifact_set_sha256}
source_revision=${source_revision}" \
    | shasum -a 256 | awk '{print $1}')"

release_bundle="${release_temporary_directory}/release-runtime"
"${script_directory}/build_p06_runtime.sh" \
    --input "${first_artifacts}" \
    --output "${release_bundle}" \
    --status release_qualified \
    --source-revision "${source_revision}" \
    --builder-id ash-p06-release-builder-v4-1 \
    --builder-source-sha256 "${builder_source_sha256}" \
    --build-parameters-sha256 "${build_parameters_sha256}" \
    --swift-compiler "${swift_compiler_identity}" \
    --metal-compiler "${metal_compiler_identity}" \
    --metal-language "${metal_language}" \
    --sdk-build "${sdk_build_identity}" \
    --deployment-target "${deployment_target}" \
    --target-triple "${target_triple}"

diff -rq -- "${first_artifacts}" "${second_artifacts}" >/dev/null
mv -- "${first_artifacts}" "${artifact_output}"
mv -- "${release_bundle}" "${bundle_output}"
if [[ -n "${provenance_output}" ]]; then
    mkdir -- "${provenance_output}"
    python3 "${source_identity_tool}" manifest \
        --repository "${repository_root}" \
        --contract "${source_contract}" \
        >"${provenance_output}/production-source-manifest.json"
    reproduced_source_revision="$(
        python3 "${source_identity_tool}" verify-manifest \
            --repository "${repository_root}" \
            --contract "${source_contract}" \
            --manifest "${provenance_output}/production-source-manifest.json"
    )"
    if [[ "${reproduced_source_revision}" != "${source_revision}" ]]; then
        print -u2 "Production source manifest identity mismatch"
        exit 65
    fi
    {
        cd "${repository_root}"
        shasum -a 256 "${builder_sources[@]}"
    } >"${provenance_output}/builder-source-manifest.txt"
    python3 - \
        "${swift_compiler_identity}" \
        "${metal_compiler_identity}" \
        "${metal_language}" \
        "${sdk_build_identity}" \
        "${deployment_target}" \
        "${target_triple}" \
        >"${provenance_output}/toolchain-image.json" <<'PY'
import json
import sys

keys = (
    "swiftCompilerIdentity",
    "metalCompilerIdentity",
    "metalLanguageVersion",
    "sdkBuildIdentity",
    "deploymentTarget",
    "targetTriple",
)
if len(sys.argv[1:]) != len(keys):
    raise SystemExit("toolchain provenance argument count mismatch")
document = dict(zip(keys, sys.argv[1:]))
sys.stdout.write(json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
PY
    if [[ ! -s "${provenance_output}/toolchain-image.json" ]]; then
        print -u2 "Toolchain provenance artifact was not generated"
        exit 65
    fi
    actual_builder_source_sha256="$(
        shasum -a 256 "${provenance_output}/builder-source-manifest.txt" | awk '{print $1}'
    )"
    if [[ "${actual_builder_source_sha256}" != "${builder_source_sha256}" ]]; then
        print -u2 "Builder provenance artifact identity mismatch"
        exit 65
    fi
fi
print -r -- "source_revision=${source_revision}"
print -r -- "builder_source_sha256=${builder_source_sha256}"
print -r -- "artifact_set_sha256=${artifact_set_sha256}"
