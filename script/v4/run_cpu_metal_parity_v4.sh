#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output DIRECTORY [--candidate-identity FILE] [--candidate-revision REVISION] [--derived-data DIRECTORY] [--smoke] [--keep-work]"
    exit 64
}

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
contract_source="${script_directory}/cpu-metal-parity-contract-v2.json"
capture_source="${script_directory}/ParityQualificationCaptureTests.swift"
evaluator_source="${script_directory}/cpu_metal_parity_v4.py"
runner_source="${0:A}"

output_directory=""
candidate_identity_source=""
candidate_revision="HEAD"
derived_data_root=""
smoke_mode=0
keep_work=0

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_directory="$2"
            shift 2
            ;;
        --candidate-identity)
            (( $# >= 2 )) || usage
            candidate_identity_source="$2"
            shift 2
            ;;
        --candidate-revision)
            (( $# >= 2 )) || usage
            candidate_revision="$2"
            shift 2
            ;;
        --derived-data)
            (( $# >= 2 )) || usage
            derived_data_root="$2"
            shift 2
            ;;
        --smoke)
            smoke_mode=1
            shift
            ;;
        --keep-work)
            keep_work=1
            shift
            ;;
        *) usage ;;
    esac
done

[[ -n "${output_directory}" ]] || usage
if (( smoke_mode == 0 )) && [[ -z "${candidate_identity_source}" ]]; then
    print -u2 "Final parity capture requires --candidate-identity"
    exit 64
fi

output_directory="$(
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' \
        "${output_directory}"
)"
if [[ -e "${output_directory}" ]] \
    && [[ -n "$(find "${output_directory}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    print -u2 "Refusing to overwrite nonempty parity output: ${output_directory}"
    exit 65
fi
mkdir -p -- "${output_directory}"

work_directory="$(
    mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-parity.XXXXXX"
)"
cleanup_parity_work() {
    if (( keep_work == 1 )); then
        print -u2 "Ephemeral parity workspace retained at ${work_directory}"
        return
    fi
    case "${work_directory}" in
        */mirmir-v4-parity.*) rm -rf -- "${work_directory}" ;;
        *) print -u2 "Refusing to clean unexpected path: ${work_directory}" ;;
    esac
}
trap cleanup_parity_work EXIT INT TERM

candidate_revision="$(
    git -C "${repository_root}" rev-parse --verify "${candidate_revision}^{commit}"
)"

sealed_tools="${output_directory}/sealed-tools"
mkdir -p -- "${sealed_tools}"
cp -- "${contract_source}" "${sealed_tools}/cpu-metal-parity-contract-v2.json"
cp -- "${capture_source}" "${sealed_tools}/ParityQualificationCaptureTests.swift"
cp -- "${evaluator_source}" "${sealed_tools}/cpu_metal_parity_v4.py"
cp -- "${runner_source}" "${sealed_tools}/run_cpu_metal_parity_v4.sh"
contract="${sealed_tools}/cpu-metal-parity-contract-v2.json"
capture="${sealed_tools}/ParityQualificationCaptureTests.swift"
evaluator="${sealed_tools}/cpu_metal_parity_v4.py"
runner="${sealed_tools}/run_cpu_metal_parity_v4.sh"

python3 - "${contract}" "${capture}" "${evaluator}" "${runner}" <<'PY'
import hashlib,json,pathlib,sys
contract_path,capture_path,evaluator_path,runner_path = map(pathlib.Path,sys.argv[1:])
contract = json.loads(contract_path.read_text())
observed = {
    "captureSourceSHA256": hashlib.sha256(capture_path.read_bytes()).hexdigest(),
    "evaluatorSHA256": hashlib.sha256(evaluator_path.read_bytes()).hexdigest(),
    "runnerSHA256": hashlib.sha256(runner_path.read_bytes()).hexdigest(),
}
for key,value in observed.items():
    if contract["tools"].get(key) != value:
        raise SystemExit(f"parity tool identity mismatch for {key}: {value}")
PY

if (( smoke_mode == 0 )); then
    for bound_path in \
        script/v4/cpu-metal-parity-contract-v2.json \
        script/v4/ParityQualificationCaptureTests.swift \
        script/v4/cpu_metal_parity_v4.py \
        script/v4/run_cpu_metal_parity_v4.sh; do
        git -C "${repository_root}" cat-file -e \
            "${candidate_revision}:${bound_path}" || {
            print -u2 "Candidate does not contain parity harness: ${bound_path}"
            exit 66
        }
        committed_hash="$(
            git -C "${repository_root}" show "${candidate_revision}:${bound_path}" \
                | shasum -a 256 | awk '{print $1}'
        )"
        working_hash="$(shasum -a 256 "${repository_root}/${bound_path}" | awk '{print $1}')"
        [[ "${committed_hash}" == "${working_hash}" ]] || {
            print -u2 "Candidate does not bind executing parity harness: ${bound_path}"
            exit 66
        }
    done
    git -C "${repository_root}" cat-file -e \
        "${candidate_revision}:Mirmir/Resources/ASH-P06.bundle/runtime-manifest.json" \
        || {
        print -u2 "Candidate does not contain checked-in ASH-P06.bundle"
        exit 66
    }
    if ! git -C "${repository_root}" show \
        "${candidate_revision}:Mirmir/Upscaling/Deterministic/DeterministicEngineV4Support.swift" \
        | python3 -c '
import re,sys
source = sys.stdin.read()
placeholders = (
    r"static\s+let\s+manifestSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*String\(repeating:\s*\"0\",\s*count:\s*64\)\s*\)",
    r"static\s+let\s+sourceRevision\s*=\s*String\(repeating:\s*\"0\",\s*count:\s*40\)",
    r"static\s+let\s+builderSourceSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*String\(repeating:\s*\"0\",\s*count:\s*64\)\s*\)",
)
raise SystemExit(1 if any(re.search(pattern, source) for pattern in placeholders) else 0)
'; then
        print -u2 "Candidate P06 code trust root is not configured"
        exit 66
    fi
fi

project_root="${work_directory}/candidate-project"
mkdir -p -- "${project_root}"
git -C "${repository_root}" archive --format=tar "${candidate_revision}" \
    | tar -xf - -C "${project_root}"

python3 - "${project_root}/Mirmir.xcodeproj/project.pbxproj" "${capture}" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
source = Path(sys.argv[2]).resolve()
text = project.read_text()
build_id = "C14000000000000000000001"
file_id = "C14000000000000000000002"
build_line = (
    f"\t\t{build_id} /* ParityQualificationCaptureTests.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {file_id} /* ParityQualificationCaptureTests.swift */; }};\n"
)
file_line = (
    f"\t\t{file_id} /* ParityQualificationCaptureTests.swift */ = "
    f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
    f"path = \"{source}\"; sourceTree = \"<absolute>\"; }};\n"
)
build_marker = "/* End PBXBuildFile section */"
file_marker = "/* End PBXFileReference section */"
phase_id = "400000000000000000000004 /* Sources */ = {"
anchor = "32000000000000000000004E /* DeterministicMetalBackendTests.swift in Sources */"
if text.count(build_marker) != 1 or text.count(file_marker) != 1:
    raise SystemExit("cannot locate unique PBX sections")
start = text.find(phase_id)
files_start = text.find("files = (", start)
files_end = text.find(");", files_start)
if start < 0 or files_start < 0 or files_end < 0:
    raise SystemExit("cannot locate MirmirTests source phase")
phase = text[files_start:files_end]
if phase.count(anchor) != 1:
    raise SystemExit("cannot locate deterministic test source anchor")
text = text.replace(build_marker, build_line + build_marker, 1)
text = text.replace(file_marker, file_line + file_marker, 1)
phase_insertion = (
    f"{build_id} /* ParityQualificationCaptureTests.swift in Sources */, "
)
start = text.find(phase_id)
files_start = text.find("files = (", start)
files_end = text.find(");", files_start)
anchor_position = text.find(anchor, files_start, files_end)
if anchor_position < 0:
    raise SystemExit("deterministic test source anchor moved outside the source phase")
text = text[:anchor_position] + phase_insertion + text[anchor_position:]
project.write_text(text)
PY

if [[ -z "${derived_data_root}" ]]; then
    derived_data_root="${work_directory}/DerivedData"
else
    derived_data_root="$(
        python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' \
            "${derived_data_root}"
    )"
fi
mkdir -p -- "${derived_data_root}"

contract_sha256="$(shasum -a 256 "${contract}" | awk '{print $1}')"
capture_sha256="$(shasum -a 256 "${capture}" | awk '{print $1}')"
runtime_mode="production"
if (( smoke_mode == 1 )); then
    runtime_mode="fixture"
fi

run_capture() {
    local run_id="$1"
    local capture_directory="${output_directory}/capture-${run_id}"
    local result_bundle="${work_directory}/parity-${run_id}.xcresult"
    local log_file="${output_directory}/xcodebuild-${run_id}.log"
    python3 - \
        "${project_root}/Mirmir.xcodeproj/xcshareddata/xcschemes/Mirmir.xcscheme" \
        "${capture_directory}" \
        "${contract}" \
        "${contract_sha256}" \
        "${capture_sha256}" \
        "${candidate_revision}" \
        "process-${run_id}" \
        "${runtime_mode}" <<'PY'
import pathlib,sys,xml.etree.ElementTree as ET

(
    scheme_path,
    capture_directory,
    contract_path,
    contract_sha256,
    capture_sha256,
    candidate_revision,
    process_run_id,
    runtime_mode,
) = sys.argv[1:]
values = {
    "MIRMIR_PARITY_CAPTURE_DIRECTORY": capture_directory,
    "MIRMIR_PARITY_CONTRACT_PATH": contract_path,
    "MIRMIR_PARITY_CONTRACT_SHA256": contract_sha256,
    "MIRMIR_PARITY_CAPTURE_SOURCE_SHA256": capture_sha256,
    "MIRMIR_PARITY_SOURCE_REVISION": candidate_revision,
    "MIRMIR_PARITY_BUILD_CONFIGURATION": "Release",
    "MIRMIR_PARITY_PROCESS_RUN_ID": process_run_id,
    "MIRMIR_PARITY_RUNTIME_MODE": runtime_mode,
}
path = pathlib.Path(scheme_path)
tree = ET.parse(path)
root = tree.getroot()
test_action = root.find("TestAction")
if test_action is None:
    raise SystemExit("cannot locate scheme TestAction")
test_action.set("shouldUseLaunchSchemeArgsEnv", "NO")
existing = test_action.find("EnvironmentVariables")
if existing is not None:
    test_action.remove(existing)
environment = ET.SubElement(test_action, "EnvironmentVariables")
for key,value in values.items():
    ET.SubElement(
        environment,
        "EnvironmentVariable",
        {"key": key, "value": value, "isEnabled": "YES"},
    )
tree.write(path, encoding="UTF-8", xml_declaration=True)
PY
    MIRMIR_PARITY_CAPTURE_DIRECTORY="${capture_directory}" \
    MIRMIR_PARITY_CONTRACT_PATH="${contract}" \
    MIRMIR_PARITY_CONTRACT_SHA256="${contract_sha256}" \
    MIRMIR_PARITY_CAPTURE_SOURCE_SHA256="${capture_sha256}" \
    MIRMIR_PARITY_SOURCE_REVISION="${candidate_revision}" \
    MIRMIR_PARITY_BUILD_CONFIGURATION="Release" \
    MIRMIR_PARITY_PROCESS_RUN_ID="process-${run_id}" \
    MIRMIR_PARITY_RUNTIME_MODE="${runtime_mode}" \
    xcodebuild test \
        -project "${project_root}/Mirmir.xcodeproj" \
        -scheme Mirmir \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "${derived_data_root}" \
        -resultBundlePath "${result_bundle}" \
        -only-testing:MirmirTests/ParityQualificationCaptureTests/testCaptureCPUAndMetalParityWhenRequested \
        CODE_SIGNING_ALLOWED=NO \
        ENABLE_TESTABILITY=YES \
        ONLY_ACTIVE_ARCH=YES \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        GCC_TREAT_WARNINGS_AS_ERRORS=YES \
        >"${log_file}" 2>&1
}

run_capture a
run_capture b

candidate_identity="${output_directory}/candidate-identity.json"
if (( smoke_mode == 1 )) && [[ -z "${candidate_identity_source}" ]]; then
    python3 - "${output_directory}/capture-a/capture.json" \
        "${candidate_revision}" "${candidate_identity}" <<'PY'
import hashlib,json,pathlib,sys
capture_path,source_revision,output_path = sys.argv[1:]
capture = json.load(open(capture_path))
runtime = capture["runtime"]
def identity(label):
    return hashlib.sha256(label.encode()).hexdigest()
candidate = {
    "sourceCommit": source_revision,
    "sourceTreeIdentitySHA256": identity("fixture-source-tree"),
    "runtimeManifestSHA256": runtime["manifestSHA256"],
    "runtimeManifestFileSHA256": runtime["manifestFileSHA256"],
    "runtimeArtifactSetSHA256": identity("fixture-runtime-artifacts"),
    "runtimeSourceRevision": runtime["sourceRevision"],
    "releaseConfigurationSHA256": identity("fixture-release-configuration"),
    "appBundleSHA256": identity("fixture-app-bundle"),
    "bundleIdentifier": "com.mirmir.fixture",
    "productVersion": "4.0-smoke",
    "productBuild": "smoke",
}
pathlib.Path(output_path).write_text(json.dumps(candidate,sort_keys=True,separators=(",",":"))+"\n")
PY
else
    candidate_identity_source="$(
        python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' \
            "${candidate_identity_source}"
    )"
    cp -- "${candidate_identity_source}" "${candidate_identity}"
fi

report="${output_directory}/cpu-metal-parity-report.json"
manifest="${output_directory}/artifact-manifest.json"
fixture_flag=()
if (( smoke_mode == 1 )); then
    fixture_flag=(--allow-fixture-runtime)
fi
python3 "${evaluator}" evaluate \
    --contract "${contract}" \
    --capture-a "${output_directory}/capture-a" \
    --capture-b "${output_directory}/capture-b" \
    --candidate "${candidate_identity}" \
    --capture-source "${capture}" \
    --evaluator "${evaluator}" \
    --runner "${runner}" \
    --evidence-root "${output_directory}" \
    --output "${report}" \
    --manifest "${manifest}" \
    "${fixture_flag[@]}"

python3 "${evaluator}" verify \
    --contract "${contract}" \
    --capture-a "${output_directory}/capture-a" \
    --capture-b "${output_directory}/capture-b" \
    --candidate "${candidate_identity}" \
    --capture-source "${capture}" \
    --evaluator "${evaluator}" \
    --runner "${runner}" \
    --evidence-root "${output_directory}" \
    --report "${report}" \
    --manifest "${manifest}" \
    "${fixture_flag[@]}"

print -r -- "Parity evidence: ${report}"
