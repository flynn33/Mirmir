#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output DIRECTORY --candidate FILE --application-archive FILE --runtime DIRECTORY --release-configuration FILE [--derived-data DIRECTORY] [--warmups COUNT] [--samples COUNT] [--keep-work]"
    exit 64
}

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
contract="${script_directory}/performance-gate-contract-v1.json"
evaluator="${script_directory}/performance_gate_v4.py"
capture_source="${script_directory}/PerformanceGateCaptureTests.swift"
packaged_capture="${script_directory}/packaged_candidate_evidence_v4.py"
output_directory=""
candidate_path=""
application_archive=""
runtime_directory=""
release_configuration=""
derived_data_root=""
warmup_count=5
sample_count=10
keep_work=0

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_directory="$2"
            shift 2
            ;;
        --candidate)
            (( $# >= 2 )) || usage
            candidate_path="$2"
            shift 2
            ;;
        --application-archive)
            (( $# >= 2 )) || usage
            application_archive="$2"
            shift 2
            ;;
        --runtime)
            (( $# >= 2 )) || usage
            runtime_directory="$2"
            shift 2
            ;;
        --release-configuration)
            (( $# >= 2 )) || usage
            release_configuration="$2"
            shift 2
            ;;
        --derived-data)
            (( $# >= 2 )) || usage
            derived_data_root="$2"
            shift 2
            ;;
        --warmups)
            (( $# >= 2 )) || usage
            warmup_count="$2"
            shift 2
            ;;
        --samples)
            (( $# >= 2 )) || usage
            sample_count="$2"
            shift 2
            ;;
        --keep-work)
            keep_work=1
            shift
            ;;
        *) usage ;;
    esac
done

[[ -n "$output_directory" ]] || usage
[[ -n "$candidate_path" ]] || usage
[[ -n "$application_archive" ]] || usage
[[ -n "$runtime_directory" ]] || usage
[[ -n "$release_configuration" ]] || usage
[[ "$warmup_count" == <-> && "$warmup_count" -ge 5 ]] || usage
[[ "$sample_count" == <-> && "$sample_count" -ge 10 ]] || usage

output_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$output_directory")"
candidate_path="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$candidate_path")"
application_archive="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$application_archive")"
runtime_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$runtime_directory")"
release_configuration="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$release_configuration")"
if [[ -e "$output_directory" ]] && [[ -n "$(find "$output_directory" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    print -u2 "refusing to overwrite nonempty output directory: $output_directory"
    exit 65
fi
mkdir -p "$output_directory"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-performance.XXXXXX")"
cleanup() {
    if (( keep_work == 1 )); then
        print -u2 "ephemeral performance workspace retained at $work_directory"
        return
    fi
    case "$work_directory" in
        */mirmir-v4-performance.*) rm -rf -- "$work_directory" ;;
        *) print -u2 "refusing to clean unexpected path: $work_directory" ;;
    esac
}
trap cleanup EXIT INT TERM

baseline_revision="$(python3 - "$contract" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["baseline"]["sourceRevision"])
PY
)"
candidate_revision="$(python3 - "$candidate_path" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
print(value.get("candidate", value)["sourceCommit"])
PY
)"
candidate_revision="$(git -C "$repository_root" rev-parse --verify "${candidate_revision}^{commit}")"
contract_sha256="$(shasum -a 256 "$contract" | awk '{print $1}')"
capture_source_sha256="$(shasum -a 256 "$capture_source" | awk '{print $1}')"

python3 - "$contract" "$capture_source" "$evaluator" "$0" <<'PY'
import hashlib,json,pathlib,sys
contract_path, capture_path, evaluator_path, runner_path = map(pathlib.Path, sys.argv[1:])
contract = json.loads(contract_path.read_text())
actual = {
    "captureSourceSHA256": hashlib.sha256(capture_path.read_bytes()).hexdigest(),
    "evaluatorSourceSHA256": hashlib.sha256(evaluator_path.read_bytes()).hexdigest(),
    "runnerSourceSHA256": hashlib.sha256(runner_path.read_bytes()).hexdigest(),
}
for field, digest in actual.items():
    if contract["capture"].get(field) != digest:
        raise SystemExit(f"performance tool identity mismatch for {field}: {digest}")
PY

for bound_path in \
    Mirmir/App/MirmirApp.swift \
    script/v4/performance_gate_v4.py \
    script/v4/PerformanceGateCaptureTests.swift \
    script/v4/packaged_candidate_evidence_v4.py \
    script/v4/release_candidate_archive_v4.py \
    script/v4/run_performance_gate_v4.sh \
    script/v4/performance-gate-contract-v1.json; do
    git -C "$repository_root" cat-file -e "${candidate_revision}:${bound_path}" || {
        print -u2 "candidate revision does not contain locked harness file: $bound_path"
        exit 66
    }
    committed_hash="$(git -C "$repository_root" show "${candidate_revision}:${bound_path}" | shasum -a 256 | awk '{print $1}')"
    working_hash="$(shasum -a 256 "$repository_root/$bound_path" | awk '{print $1}')"
    [[ "$committed_hash" == "$working_hash" ]] || {
        print -u2 "candidate revision does not bind the executing harness: $bound_path"
        exit 66
    }
done

locked_input="$repository_root/$(python3 - "$contract" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["workload"]["input"]["repositoryPath"])
PY
)"
expected_input_sha256="$(python3 - "$contract" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["workload"]["input"]["sha256"])
PY
)"
actual_input_sha256="$(shasum -a 256 "$locked_input" | awk '{print $1}')"
[[ "$actual_input_sha256" == "$expected_input_sha256" ]] || {
    print -u2 "locked input SHA-256 mismatch: $actual_input_sha256"
    exit 66
}

mkdir -p "$work_directory/baseline-project" "$work_directory/candidate-project"
git -C "$repository_root" archive --format=tar "$baseline_revision" \
    | tar -xf - -C "$work_directory/baseline-project"
git -C "$repository_root" archive --format=tar "$candidate_revision" \
    | tar -xf - -C "$work_directory/candidate-project"
cp "$capture_source" "$work_directory/baseline-project/script/v4/PerformanceGateCaptureTests.swift"

inject_capture_source() {
    local project_root="$1"
    python3 - "$project_root/Mirmir.xcodeproj/project.pbxproj" \
        "$project_root/script/v4/PerformanceGateCaptureTests.swift" <<'PY'
from pathlib import Path
import sys

project = Path(sys.argv[1])
source = Path(sys.argv[2]).resolve()
text = project.read_text()
build_id = "C12000000000000000000002"
file_id = "C11000000000000000000002"
build_line = (
    f"\t\t{build_id} /* PerformanceGateCaptureTests.swift in Sources */ = "
    f"{{isa = PBXBuildFile; fileRef = {file_id} /* PerformanceGateCaptureTests.swift */; }};\n"
)
file_line = (
    f"\t\t{file_id} /* PerformanceGateCaptureTests.swift */ = "
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
    raise SystemExit("cannot locate the MirmirTests source phase")
source_files = text[files_start:files_end]
if source_files.count(anchor) != 1:
    raise SystemExit("cannot locate the MirmirTests source anchor")
insertion = (
    f"{build_id} /* PerformanceGateCaptureTests.swift in Sources */,\n\t\t\t"
)
text = text[:files_end] + insertion + text[files_end:]
text = text.replace(build_marker, build_line + build_marker)
text = text.replace(file_marker, file_line + file_marker)
project.write_text(text)
PY
    plutil -lint "$project_root/Mirmir.xcodeproj/project.pbxproj" >/dev/null
}

inject_capture_source "$work_directory/baseline-project"

source_tree_identity() {
    local repository="$1"
    local revision="$2"
    python3 - "$repository" "$revision" <<'PY'
import hashlib
import subprocess
import sys

repository, revision = sys.argv[1:]
process = subprocess.run(
    ["git", "ls-tree", "-r", "-z", "--full-tree", revision],
    cwd=repository,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    check=False,
)
if process.returncode != 0:
    raise SystemExit(
        "cannot resolve source tree: "
        + process.stderr.decode("utf-8", errors="replace").strip()
    )
print(hashlib.sha256(b"mirmir-source-tree-v1\0" + process.stdout).hexdigest())
PY
}

make_source_identity() {
    local variant="$1"
    local revision="$2"
    local project_root="$3"
    local destination="$4"
    local tree_sha256
    tree_sha256="$(source_tree_identity "$repository_root" "$revision")"
    python3 - "$variant" "$revision" "$tree_sha256" "$project_root" "$contract" "$destination" <<'PY'
import hashlib,json,pathlib,re,sys

variant, revision, tree_sha, project_text, contract_text, destination_text = sys.argv[1:]
project = pathlib.Path(project_text)
contract = json.loads(pathlib.Path(contract_text).read_text())
if variant == "baseline_p05":
    expected = contract["baseline"]["implementationVersions"]
    source = "\n".join(
        (project / path).read_text()
        for path in (
            "Mirmir/Upscaling/Deterministic/DeterministicCPUBackend.swift",
            "Mirmir/Modules/UpscalerEngine/ASH/ASHMetalDevelopmentRuntimeV3.swift",
        )
    )
    if any(identity not in source for identity in expected):
        raise SystemExit("the frozen P05 implementation identities are absent")
    runtime = {
        "status": contract["baseline"]["runtimeStatus"],
        "runtimeID": None,
        "implementationVersions": expected,
        "manifestSHA256": None,
        "releaseQualified": False,
        "trustRootConfigured": False,
        "artifactsVerified": True,
    }
else:
    candidate = contract["candidate"]
    bundle = project / candidate["bundleRepositoryPath"]
    if not bundle.is_dir() or bundle.is_symlink():
        raise SystemExit(f"release-qualified P06 bundle is missing or unsafe: {bundle}")
    for entry in bundle.rglob("*"):
        if entry.is_symlink():
            raise SystemExit(f"symbolic links are forbidden in the P06 bundle: {entry}")
    manifest_path = bundle / "runtime-manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise SystemExit(f"release-qualified P06 manifest is missing: {manifest_path}")
    manifest_bytes = manifest_path.read_bytes()
    manifest = json.loads(manifest_bytes)
    canonical_manifest_bytes = json.dumps(
        manifest,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    if manifest_bytes != canonical_manifest_bytes:
        raise SystemExit("candidate P06 manifest bytes are not canonical")
    manifest_hash = hashlib.sha256(
        b"ash-p06-runtime-manifest-v4\0" + canonical_manifest_bytes
    ).hexdigest()
    if manifest.get("schemaID") != "ash.p06.runtime-manifest.v1":
        raise SystemExit("candidate P06 manifest schema differs")
    if manifest.get("releaseStatus") != candidate["requiredRuntimeStatus"]:
        raise SystemExit("candidate P06 manifest is not release-qualified")
    if manifest.get("runtimeID") != candidate["requiredRuntimeID"]:
        raise SystemExit("candidate P06 runtime ID differs")
    descriptors = manifest.get("artifacts")
    if not isinstance(descriptors, list) or len(descriptors) != 12:
        raise SystemExit("candidate P06 artifact matrix is incomplete")
    expected_roles = {
        "benchmark_corpus_identity",
        "branch_aggregation",
        "codeword_tables",
        "core_certificate",
        "measurement_contract",
        "metal_compiler_contract",
        "metal_library",
        "metric_contract",
        "operator_bank",
        "phase_coefficient_procedure",
        "quality_corpus_identity",
        "verification_contract",
    }
    roles = [descriptor.get("role") for descriptor in descriptors]
    if roles != sorted(expected_roles):
        raise SystemExit("candidate P06 artifact role set/order differs")
    declared = set()
    for descriptor in descriptors:
        role = descriptor.get("role")
        relative = descriptor.get("relativePath")
        if not isinstance(relative, str) or pathlib.PurePosixPath(relative).is_absolute() or ".." in pathlib.PurePosixPath(relative).parts:
            raise SystemExit(f"unsafe P06 artifact path: {relative}")
        expected_relative = (
            "artifacts/ash-p06.metallib"
            if role == "metal_library"
            else f"artifacts/{role}.json"
        )
        if relative != expected_relative:
            raise SystemExit(f"noncanonical P06 artifact path: {relative}")
        content_hash = descriptor.get("contentSHA256")
        byte_count = descriptor.get("byteCount")
        if not isinstance(content_hash, str) or re.fullmatch(r"[0-9a-f]{64}", content_hash) is None:
            raise SystemExit(f"invalid P06 artifact hash: {relative}")
        if not isinstance(byte_count, int) or isinstance(byte_count, bool) or byte_count <= 0:
            raise SystemExit(f"invalid P06 artifact byte count: {relative}")
        artifact = bundle / relative
        if not artifact.is_file() or artifact.is_symlink():
            raise SystemExit(f"missing or unsafe P06 artifact: {relative}")
        data = artifact.read_bytes()
        if len(data) != byte_count or hashlib.sha256(data).hexdigest() != content_hash:
            raise SystemExit(f"P06 artifact identity mismatch: {relative}")
        if relative in declared:
            raise SystemExit(f"duplicate P06 artifact path: {relative}")
        declared.add(relative)
    actual = {
        path.relative_to(bundle).as_posix()
        for path in bundle.rglob("*")
        if path.is_file() and path.name != "runtime-manifest.json"
    }
    if actual != declared:
        raise SystemExit("P06 bundle has unmanifested or missing files")
    provenance = manifest.get("provenance")
    if not isinstance(provenance, dict):
        raise SystemExit("candidate P06 provenance is missing")
    builder_hash = provenance.get("builderSourceSHA256")
    source_revision = provenance.get("sourceRevision")
    if not isinstance(builder_hash, str) or re.fullmatch(r"[0-9a-f]{64}", builder_hash) is None:
        raise SystemExit("candidate P06 builder identity is invalid")
    if not isinstance(source_revision, str) or re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", source_revision) is None:
        raise SystemExit("candidate P06 source identity is invalid")

    trust_source = (project / candidate["trustRootSourcePath"]).read_text()
    def unique_literal(pattern, label):
        values = re.findall(pattern, trust_source)
        if len(values) != 1:
            raise SystemExit(f"code-owned P06 {label} trust root is not unique")
        return values[0]

    trusted_manifest = unique_literal(
        r'manifestSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"([0-9a-f]{64})"\s*\)',
        "manifest",
    )
    trusted_source_revision = unique_literal(
        r'sourceRevision\s*=\s*"((?:[0-9a-f]{40}|[0-9a-f]{64}))"',
        "source revision",
    )
    trusted_builder = unique_literal(
        r'builderSourceSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"([0-9a-f]{64})"\s*\)',
        "builder",
    )
    if manifest_hash != trusted_manifest:
        raise SystemExit("code-owned P06 manifest trust root differs")
    if builder_hash != trusted_builder or source_revision != trusted_source_revision:
        raise SystemExit("code-owned P06 provenance trust roots differ")
    runtime = {
        "status": manifest["releaseStatus"],
        "runtimeID": manifest["runtimeID"],
        "implementationVersions": [manifest["runtimeID"]],
        "manifestSHA256": manifest_hash,
        "manifestSourceRevision": source_revision,
        "builderSourceSHA256": builder_hash,
        "releaseQualified": True,
        "trustRootConfigured": True,
        "artifactsVerified": True,
    }

identity = {
    "schemaVersion": "mirmir-v4-performance-source-identity-v1",
    "variant": variant,
    "sourceRevision": revision,
    "sourceTreeSHA256": tree_sha,
    "runtime": runtime,
}
pathlib.Path(destination_text).write_text(json.dumps(identity, indent=2, sort_keys=True) + "\n")
PY
}

capture_environment() {
    local destination="$1"
    python3 - "$destination" <<'PY'
import hashlib,json,subprocess,sys

def command(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT).strip()

def optional(*arguments):
    try:
        return command(*arguments)
    except Exception as error:
        raise SystemExit(f"required environment command failed ({' '.join(arguments)}): {error}")

graphics = json.loads(optional("system_profiler", "SPDisplaysDataType", "-json"))
gpu_names = sorted(
    item.get("_name", "")
    for item in graphics.get("SPDisplaysDataType", [])
    if item.get("_name")
)
thermal_raw = optional("pmset", "-g", "therm")
required_thermal = (
    "No thermal warning level has been recorded",
    "No performance warning level has been recorded",
)
thermal_accepted = all(text in thermal_raw for text in required_thermal)
battery = optional("pmset", "-g", "batt").splitlines()[0]
power_configuration = optional("pmset", "-g", "custom")
power_identity = hashlib.sha256(
    (battery + "\n" + power_configuration).encode()
).hexdigest()
value = {
    "schemaVersion": "mirmir-v4-performance-environment-v1",
    "stableIdentity": {
        "hardwareModel": optional("sysctl", "-n", "hw.model"),
        "memoryBytes": int(optional("sysctl", "-n", "hw.memsize")),
        "processor": optional("sysctl", "-n", "machdep.cpu.brand_string"),
        "gpuIdentity": gpu_names,
        "macOSBuild": optional("sw_vers", "-buildVersion"),
        "xcodeBuild": optional("xcodebuild", "-version"),
        "swiftCompiler": optional("swift", "--version"),
    },
    "power": {
        "identity": power_identity,
        "source": battery,
    },
    "thermal": {
        "accepted": thermal_accepted,
        "observationSHA256": hashlib.sha256(thermal_raw.encode()).hexdigest(),
    },
}
with open(sys.argv[1], "w") as stream:
    json.dump(value, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY
}

run_capture() {
    local variant="$1"
    local revision="$2"
    local project_root="$3"
    local capture_directory="$4"
    local derived_data="$5"
    mkdir -p "$capture_directory"
    make_source_identity "$variant" "$revision" "$project_root" \
        "$capture_directory/source-identity.json"
    local source_identity_sha256
    source_identity_sha256="$(shasum -a 256 "$capture_directory/source-identity.json" | awk '{print $1}')"
    local source_tree_sha256
    source_tree_sha256="$(source_tree_identity "$repository_root" "$revision")"
    python3 - \
        "$project_root/script/v4/PerformanceGateCaptureTests.swift" \
        "$capture_directory" \
        "$locked_input" \
        "$variant" \
        "$contract_sha256" \
        "$capture_source_sha256" \
        "$source_identity_sha256" \
        "$revision" \
        "$source_tree_sha256" \
        "$warmup_count" \
        "$sample_count" <<'PY'
from pathlib import Path
import json
import sys

path = Path(sys.argv[1])
names = (
    "CAPTURE_DIR",
    "INPUT",
    "VARIANT",
    "CONTRACT_SHA256",
    "CAPTURE_SOURCE_SHA256",
    "SOURCE_IDENTITY_SHA256",
    "SOURCE_REVISION",
    "SOURCE_TREE_SHA256",
    "WARMUPS",
    "SAMPLES",
)
text = path.read_text()
for name, value in zip(names, sys.argv[2:]):
    sentinel = f"__MIRMIR_V4_PERFORMANCE_{name}__"
    quoted = json.dumps(sentinel)
    if text.count(quoted) != 1:
        raise SystemExit(f"performance capture sentinel is not unique: {sentinel}")
    text = text.replace(quoted, json.dumps(value))
path.write_text(text)
PY
    capture_environment "$capture_directory/environment-before.json"
    (
        cd "$project_root"
        MIRMIR_V4_PERFORMANCE_CAPTURE_DIR="$capture_directory" \
        MIRMIR_V4_PERFORMANCE_INPUT="$locked_input" \
        MIRMIR_V4_PERFORMANCE_VARIANT="$variant" \
        MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256="$contract_sha256" \
        MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256="$capture_source_sha256" \
        MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256="$source_identity_sha256" \
        MIRMIR_V4_PERFORMANCE_SOURCE_REVISION="$revision" \
        MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256="$source_tree_sha256" \
        MIRMIR_V4_PERFORMANCE_WARMUPS="$warmup_count" \
        MIRMIR_V4_PERFORMANCE_SAMPLES="$sample_count" \
        xcodebuild \
            -project Mirmir.xcodeproj \
            -scheme Mirmir \
            -configuration Release \
            -destination platform=macOS \
            -derivedDataPath "$derived_data" \
            -parallel-testing-enabled NO \
            test \
            -only-testing:MirmirTests/DeterministicEngineV4PerformanceCaptureTests/testCaptureSameScopePerformanceWhenRequested \
            CODE_SIGNING_ALLOWED=NO \
            ENABLE_TESTABILITY=YES \
            ONLY_ACTIVE_ARCH=YES \
            "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR=$capture_directory" \
            "MIRMIR_V4_PERFORMANCE_INPUT=$locked_input" \
            "MIRMIR_V4_PERFORMANCE_VARIANT=$variant" \
            "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256=$contract_sha256" \
            "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256=$capture_source_sha256" \
            "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256=$source_identity_sha256" \
            "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION=$revision" \
            "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256=$source_tree_sha256" \
            "MIRMIR_V4_PERFORMANCE_WARMUPS=$warmup_count" \
            "MIRMIR_V4_PERFORMANCE_SAMPLES=$sample_count"
    ) >"$capture_directory/xcodebuild.log" 2>&1 || {
        tail -n 240 "$capture_directory/xcodebuild.log" >&2
        exit 1
    }
    [[ -f "$capture_directory/capture.json" ]] || {
        print -u2 "$variant test completed without capture.json"
        exit 66
    }
    capture_environment "$capture_directory/environment-after.json"
    python3 "$evaluator" seal --directory "$capture_directory"
}

if [[ -z "$derived_data_root" ]]; then
    derived_data_root="$work_directory/DerivedData"
else
    derived_data_root="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$derived_data_root")"
fi
mkdir -p "$output_directory/baseline" "$output_directory/candidate"

run_capture \
    baseline_p05 \
    "$baseline_revision" \
    "$work_directory/baseline-project" \
    "$output_directory/baseline" \
    "$derived_data_root/baseline"

make_source_identity \
    candidate_p06 \
    "$candidate_revision" \
    "$work_directory/candidate-project" \
    "$output_directory/candidate/source-identity.json"
capture_environment "$output_directory/candidate/environment-before.json"
python3 "$packaged_capture" capture \
    --repository "$repository_root" \
    --candidate "$candidate_path" \
    --application-archive "$application_archive" \
    --runtime "$runtime_directory" \
    --release-configuration "$release_configuration" \
    --lane performance \
    --contract "$contract" \
    --performance-input "$locked_input" \
    --performance-source-identity "$output_directory/candidate/source-identity.json" \
    --warmups "$warmup_count" \
    --samples "$sample_count" \
    --output "$output_directory/packaged-candidate"
cp "$output_directory/packaged-candidate/capture/capture.json" \
    "$output_directory/candidate/capture.json"
python3 - \
    "$output_directory/packaged-candidate/capture-record.json" \
    "$output_directory/candidate/packaged-observer.log" <<'PY'
import json,pathlib,sys
record_path, output_path = map(pathlib.Path, sys.argv[1:])
record = json.loads(record_path.read_text())
summary = {
    "captureProducer": "exact_attested_application_observer",
    "applicationArchiveSHA256": record["packageIdentity"]["applicationArchiveSHA256"],
    "applicationExecutableSHA256": record["packageIdentity"]["applicationExecutableSHA256"],
    "captureTreeSHA256": record["captureTree"]["sha256"],
    "evidenceRequestSHA256": record["requestSHA256"],
    "observerSourceSHA256": record["observerSourceSHA256"],
}
output_path.write_text(json.dumps(summary, separators=(",", ":"), sort_keys=True) + "\n")
PY
capture_environment "$output_directory/candidate/environment-after.json"
python3 "$evaluator" seal --directory "$output_directory/candidate"

python3 "$evaluator" evaluate \
    --contract "$contract" \
    --baseline "$output_directory/baseline" \
    --candidate "$output_directory/candidate" \
    --packaged-evidence "$output_directory/packaged-candidate" \
    --repository "$repository_root" \
    --runtime "$runtime_directory" \
    --output "$output_directory/performance-gate-report.json"
python3 "$evaluator" verify \
    --contract "$contract" \
    --report "$output_directory/performance-gate-report.json" \
    --baseline "$output_directory/baseline" \
    --candidate "$output_directory/candidate" \
    --packaged-evidence "$output_directory/packaged-candidate" \
    --repository "$repository_root" \
    --runtime "$runtime_directory"
cp "$contract" "$output_directory/performance-gate-contract-v1.json"

python3 - "$output_directory" <<'PY'
import hashlib,json,pathlib,sys
root = pathlib.Path(sys.argv[1]).resolve()
artifacts = []
for path in sorted(root.rglob("*")):
    if path.is_file() and path != root / "artifact-manifest.json":
        artifacts.append({
            "path": path.relative_to(root).as_posix(),
            "byteCount": path.stat().st_size,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
(root / "artifact-manifest.json").write_text(json.dumps({
    "schemaVersion": "mirmir-v4-performance-evidence-manifest-v1",
    "artifacts": artifacts,
}, indent=2, sort_keys=True) + "\n")
PY

print "$output_directory"
