#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output EVIDENCE_ROOT/recovery --candidate CANDIDATE.json --application-archive Mirmir.zip --release-configuration Release.xcconfig [--timeout-seconds N]"
    print -u2 "       $0 --compile-only [--derived-data DIR]"
    exit 64
}

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
contract_source="${script_directory}/recovery-qualification-contract-v1.json"
evaluator_source="${script_directory}/recovery_qualification_v4.py"
packaged_source="${script_directory}/packaged_candidate_evidence_v4.py"

output_directory=""
candidate=""
application_archive=""
release_configuration=""
derived_data=""
timeout_seconds=3600
compile_only=0

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_directory="$2"
            shift 2 ;;
        --candidate)
            (( $# >= 2 )) || usage
            candidate="$2"
            shift 2 ;;
        --application-archive)
            (( $# >= 2 )) || usage
            application_archive="$2"
            shift 2 ;;
        --release-configuration)
            (( $# >= 2 )) || usage
            release_configuration="$2"
            shift 2 ;;
        --timeout-seconds)
            (( $# >= 2 )) || usage
            timeout_seconds="$2"
            shift 2 ;;
        --derived-data)
            (( $# >= 2 )) || usage
            derived_data="$2"
            shift 2 ;;
        --compile-only)
            compile_only=1
            shift ;;
        *) usage ;;
    esac
done

if (( compile_only == 1 )); then
    [[ -z "${output_directory}" && -z "${candidate}" \
        && -z "${application_archive}" \
        && -z "${release_configuration}" ]] || usage
    if [[ -z "${derived_data}" ]]; then
        derived_data="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-recovery-compile.XXXXXX")"
        cleanup_compile=1
    else
        derived_data="${derived_data:A}"
        cleanup_compile=0
    fi
    cleanup_recovery_compile() {
        if (( cleanup_compile == 1 )); then
            case "${derived_data}" in
                */mirmir-v4-recovery-compile.*) rm -rf -- "${derived_data}" ;;
                *) print -u2 "refusing to clean unexpected path: ${derived_data}" ;;
            esac
        fi
    }
    trap cleanup_recovery_compile EXIT INT TERM
    xcodebuild build-for-testing \
        -project "${repository_root}/Mirmir.xcodeproj" \
        -scheme Mirmir \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "${derived_data}" \
        CODE_SIGNING_ALLOWED=NO \
        ENABLE_TESTABILITY=YES \
        ONLY_ACTIVE_ARCH=YES \
        ARCHS=arm64 \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        GCC_TREAT_WARNINGS_AS_ERRORS=YES
    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
    developer_path="$(xcode-select -p)"
    xcrun swiftc -typecheck \
        "${script_directory}/RecoveryQualificationCaptureTests.swift" \
        -target arm64-apple-macos15.4 \
        -sdk "${sdk_path}" \
        -I "${derived_data}/Build/Products/Release" \
        -F "${derived_data}/Build/Products/Release" \
        -F "${developer_path}/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
        -enable-testing \
        -warnings-as-errors
    print -r -- "recovery production runner and thin XCTest compiled in Release"
    exit 0
fi

[[ -n "${output_directory}" && -n "${candidate}" \
    && -n "${application_archive}" \
    && -n "${release_configuration}" ]] || usage
[[ "${timeout_seconds}" == <-> && "${timeout_seconds}" -gt 0 ]] || usage

output_directory="${output_directory:A}"
candidate="${candidate:A}"
application_archive="${application_archive:A}"
release_configuration="${release_configuration:A}"
[[ "${output_directory:t}" == "recovery" ]] || {
    print -u2 "output directory must be named recovery"
    exit 65
}
for input in "${candidate}" "${application_archive}" \
    "${release_configuration}"; do
    [[ -f "${input}" && ! -L "${input}" ]] || {
        print -u2 "required recovery input is not a regular file: ${input}"
        exit 66
    }
done
if [[ -e "${output_directory}" ]]; then
    [[ -d "${output_directory}" && ! -L "${output_directory}" \
        && -z "$(find "${output_directory}" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
        print -u2 "refusing to overwrite nonempty recovery output"
        exit 65
    }
else
    mkdir -p -- "${output_directory}"
fi

binding_directory="${output_directory}/bindings"
capture_directory="${output_directory}/captures"
mkdir -p -- "${binding_directory}" "${capture_directory}"
cp -- "${contract_source}" \
    "${binding_directory}/recovery-qualification-contract-v1.json"
cp -- "${evaluator_source}" \
    "${binding_directory}/recovery_qualification_v4.py"
cp -- "${packaged_source}" \
    "${binding_directory}/packaged_candidate_evidence_v4.py"
cp -- "${script_directory}/release_candidate_archive_v4.py" \
    "${binding_directory}/release_candidate_archive_v4.py"
cp -- "${repository_root}/Mirmir/App/MirmirApp.swift" \
    "${binding_directory}/MirmirApp.swift"
cp -- "${repository_root}/Mirmir/App/WorkflowApplicationCoordinatorV4.swift" \
    "${binding_directory}/WorkflowApplicationCoordinatorV4.swift"
cp -- "${0:A}" "${binding_directory}/run_recovery_qualification_v4.sh"

contract="${binding_directory}/recovery-qualification-contract-v1.json"
evaluator="${binding_directory}/recovery_qualification_v4.py"
packaged="${binding_directory}/packaged_candidate_evidence_v4.py"
runtime="${repository_root}/Mirmir/Resources/ASH-P06.bundle"

for process_name in process-a process-b; do
    python3 "${packaged}" capture \
        --repository "${repository_root}" \
        --candidate "${candidate}" \
        --application-archive "${application_archive}" \
        --runtime "${runtime}" \
        --release-configuration "${release_configuration}" \
        --lane recovery \
        --contract "${contract}" \
        --output "${capture_directory}/${process_name}" \
        --timeout-seconds "${timeout_seconds}"
done

python3 "${evaluator}" evaluate \
    --repository "${repository_root}" \
    --runtime "${runtime}" \
    --contract "${contract}" \
    --packaged-evidence-a "${capture_directory}/process-a" \
    --packaged-evidence-b "${capture_directory}/process-b" \
    --capture-manifest "${output_directory}/capture-artifact-manifest.json" \
    --sealed-manifest "${output_directory}/recovery-evidence-manifest.json" \
    --output "${output_directory}/recovery-report.json"

python3 "${evaluator}" verify \
    --repository "${repository_root}" \
    --runtime "${runtime}" \
    --contract "${contract}" \
    --packaged-evidence-a "${capture_directory}/process-a" \
    --packaged-evidence-b "${capture_directory}/process-b" \
    --capture-manifest "${output_directory}/capture-artifact-manifest.json" \
    --sealed-manifest "${output_directory}/recovery-evidence-manifest.json" \
    --report "${output_directory}/recovery-report.json"

print -r -- "recovery archived-executable qualification passed: ${output_directory}"
