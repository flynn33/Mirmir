#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output DIRECTORY [--baseline-only | --candidate FILE --application-archive FILE --runtime DIRECTORY --release-configuration FILE] [--warmups COUNT] [--samples COUNT] [--keep-work]"
    exit 64
}

script_directory="${0:A:h}"
runner_path="${0:A}"
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
warmup_count=5
sample_count=10
keep_work=0
baseline_only=0

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
        --baseline-only)
            baseline_only=1
            shift
            ;;
        *) usage ;;
    esac
done

[[ -n "$output_directory" ]] || usage
if (( baseline_only == 0 )); then
    [[ -n "$candidate_path" ]] || usage
    [[ -n "$application_archive" ]] || usage
    [[ -n "$runtime_directory" ]] || usage
    [[ -n "$release_configuration" ]] || usage
else
    [[ -z "$candidate_path" && -z "$application_archive" \
        && -z "$runtime_directory" && -z "$release_configuration" ]] || usage
fi
[[ "$warmup_count" == <-> && "$warmup_count" -ge 5 ]] || usage
[[ "$sample_count" == <-> && "$sample_count" -ge 10 ]] || usage

output_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$output_directory")"
if (( baseline_only == 0 )); then
    candidate_path="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$candidate_path")"
    application_archive="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$application_archive")"
    runtime_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$runtime_directory")"
    release_configuration="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$release_configuration")"
fi
if [[ -e "$output_directory" ]] && [[ -n "$(find "$output_directory" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    print -u2 "refusing to overwrite nonempty output directory: $output_directory"
    exit 65
fi
mkdir -p "$output_directory"

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-performance.XXXXXX")"
work_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve(strict=True))' "$work_directory")"
request_lock_directory="/private/tmp/mirmir-v4-performance-request-v2.lock"
request_path="$request_lock_directory/request.json"
stable_capture_source="$request_lock_directory/PerformanceGateCaptureTests.swift"
request_lock_owner_path="$request_lock_directory/owner-token"
request_lock_owner_token="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
request_lock_acquired=0
canonical_producer_root="/private/tmp/mirmir-v4-performance-producer-v2"
canonical_producer_owner_path="$canonical_producer_root/owner-token"
canonical_source_root="$canonical_producer_root/baseline-project"
canonical_derived_data="$canonical_producer_root/DerivedData/baseline"
canonical_module_cache="$canonical_producer_root/ModuleCache.noindex"
canonical_swift_wrapper="$canonical_producer_root/swiftc"
canonical_swift_audit="$canonical_producer_root/swift-driver-effective-argv.log"
canonical_swift_frontend_shim="$canonical_producer_root/swift-frontend"
canonical_swift_frontend_audit="$canonical_producer_root/swift-frontend-effective-argv.jsonl"
canonical_swift_temporary="$canonical_producer_root/Temporary"
canonical_swift_supplementary_maps="$canonical_producer_root/SupplementaryOutputMaps"
canonical_root_acquired=0
cleanup() {
    local owns_canonical_root=0
    if (( canonical_root_acquired == 1 )); then
        owns_canonical_root=1
    elif [[ -f "$canonical_producer_owner_path" ]] \
        && [[ "$(<"$canonical_producer_owner_path")" == "$request_lock_owner_token" ]]; then
        owns_canonical_root=1
    fi
    if (( owns_canonical_root == 1 )); then
        if [[ ! -f "$canonical_producer_owner_path" ]] \
            || [[ "$(<"$canonical_producer_owner_path")" != "$request_lock_owner_token" ]]; then
            print -u2 "refusing to clean a canonical performance root owned by another producer"
        else
            case "$canonical_producer_root" in
                /private/tmp/mirmir-v4-performance-producer-v2)
                    rm -rf -- "$canonical_producer_root"
                    ;;
                *)
                    print -u2 "refusing to clean unexpected canonical performance root: $canonical_producer_root"
                    ;;
            esac
        fi
    fi
    local owns_request_lock=0
    if (( request_lock_acquired == 1 )); then
        owns_request_lock=1
    elif [[ -f "$request_lock_owner_path" ]] \
        && [[ "$(<"$request_lock_owner_path")" == "$request_lock_owner_token" ]]; then
        owns_request_lock=1
    fi
    if (( owns_request_lock == 1 )); then
        if [[ ! -f "$request_lock_owner_path" ]] \
            || [[ "$(<"$request_lock_owner_path")" != "$request_lock_owner_token" ]]; then
            print -u2 "refusing to clean a performance request lock owned by another producer"
        else
        [[ "$request_path" == "/private/tmp/mirmir-v4-performance-request-v2.lock/request.json" ]] \
            && rm -f -- "$request_path"
        [[ "$stable_capture_source" == "/private/tmp/mirmir-v4-performance-request-v2.lock/PerformanceGateCaptureTests.swift" ]] \
            && rm -f -- "$stable_capture_source"
        [[ "$request_lock_owner_path" == "/private/tmp/mirmir-v4-performance-request-v2.lock/owner-token" ]] \
            && rm -f -- "$request_lock_owner_path"
        [[ "$request_lock_directory" == "/private/tmp/mirmir-v4-performance-request-v2.lock" ]] \
            && rmdir -- "$request_lock_directory" 2>/dev/null || true
        fi
    fi
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

mkdir -m 700 "$request_lock_directory" 2>/dev/null || {
    print -u2 "another performance producer owns the fixed request path"
    exit 67
}
request_lock_acquired=1
[[ ! -e "$request_path" && ! -e "$stable_capture_source" \
    && ! -e "$request_lock_owner_path" ]] || {
    print -u2 "stale performance producer request/source artifact exists"
    exit 67
}
print -r -- "$request_lock_owner_token" > "$request_lock_owner_path"
cp "$capture_source" "$stable_capture_source"

[[ ! -e "$canonical_producer_root" ]] || {
    print -u2 "foreign or stale canonical performance producer root exists"
    exit 67
}
mkdir -m 700 "$canonical_producer_root"
canonical_root_acquired=1
[[ ! -e "$canonical_producer_owner_path" \
    && ! -e "$canonical_source_root" \
    && ! -e "$canonical_producer_root/DerivedData" \
    && ! -e "$canonical_module_cache" \
    && ! -e "$canonical_swift_wrapper" \
    && ! -e "$canonical_swift_audit" \
    && ! -e "$canonical_swift_frontend_shim" \
    && ! -e "$canonical_swift_frontend_audit" \
    && ! -e "$canonical_swift_temporary" \
    && ! -e "$canonical_swift_supplementary_maps" ]] || {
    print -u2 "canonical performance producer root was not empty"
    exit 67
}
print -r -- "$request_lock_owner_token" > "$canonical_producer_owner_path"
mkdir -p "$canonical_source_root" "$canonical_derived_data" \
    "$canonical_module_cache"

export SWIFT_DETERMINISTIC_HASHING=1
export SWIFTC_MAXIMUM_DETERMINISM=1

baseline_revision="$(python3 - "$contract" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["baseline"]["sourceRevision"])
PY
)"
candidate_revision=""
if (( baseline_only == 0 )); then
    candidate_revision="$(python3 - "$candidate_path" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
print(value.get("candidate", value)["sourceCommit"])
PY
    )"
    candidate_revision="$(git -C "$repository_root" rev-parse --verify "${candidate_revision}^{commit}")"
fi
contract_sha256="$(shasum -a 256 "$contract" | awk '{print $1}')"
capture_source_sha256="$(shasum -a 256 "$capture_source" | awk '{print $1}')"

python3 - "$contract" "$capture_source" "$evaluator" "$runner_path" <<'PY'
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

underlying_swiftc="$(python3 <<'PY'
import pathlib
import subprocess

raw = subprocess.check_output(
    ["/usr/bin/xcrun", "--find", "swiftc"],
    text=True,
    stderr=subprocess.STDOUT,
).strip()
path = pathlib.Path(raw).resolve(strict=True)
if not path.is_file():
    raise SystemExit("resolved Swift compiler is not a file")
print(path)
PY
)"
python3 "$evaluator" write-swift-helpers \
    --underlying-swiftc "$underlying_swiftc" \
    --wrapper "$canonical_swift_wrapper" \
    --driver-audit "$canonical_swift_audit" \
    --frontend-shim "$canonical_swift_frontend_shim" \
    --frontend-audit "$canonical_swift_frontend_audit" \
    --temporary-directory "$canonical_swift_temporary" \
    --supplementary-directory "$canonical_swift_supplementary_maps"

if (( baseline_only == 0 )); then
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
fi

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

git -C "$repository_root" archive --format=tar "$baseline_revision" \
    | tar -xf - -C "$canonical_source_root"
if (( baseline_only == 0 )); then
    mkdir -p "$work_directory/candidate-project"
    git -C "$repository_root" archive --format=tar "$candidate_revision" \
        | tar -xf - -C "$work_directory/candidate-project"
fi
inject_capture_source() {
    local project_root="$1"
    local injected_source="$2"
    python3 - "$project_root/Mirmir.xcodeproj/project.pbxproj" \
        "$injected_source" <<'PY'
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

inject_capture_source "$canonical_source_root" "$stable_capture_source"

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
    local invocation_nonce
    invocation_nonce="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    local producer_challenge
    producer_challenge="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    mkdir -p "$capture_directory/producer"
    make_source_identity "$variant" "$revision" "$project_root" \
        "$capture_directory/source-identity.json"
    local source_identity_sha256
    source_identity_sha256="$(shasum -a 256 "$capture_directory/source-identity.json" | awk '{print $1}')"
    local source_tree_sha256
    source_tree_sha256="$(source_tree_identity "$repository_root" "$revision")"
    capture_environment "$capture_directory/environment-before.json"
    local result_bundle="$capture_directory/producer/baseline.xcresult"
    local -a build_environment=(
        "MIRMIR_V4_PERFORMANCE_CAPTURE_DIR=$capture_directory"
        "MIRMIR_V4_PERFORMANCE_INPUT=$locked_input"
        "MIRMIR_V4_PERFORMANCE_VARIANT=$variant"
        "MIRMIR_V4_PERFORMANCE_CONTRACT_SHA256=$contract_sha256"
        "MIRMIR_V4_PERFORMANCE_CAPTURE_SOURCE_SHA256=$capture_source_sha256"
        "MIRMIR_V4_PERFORMANCE_SOURCE_IDENTITY_SHA256=$source_identity_sha256"
        "MIRMIR_V4_PERFORMANCE_SOURCE_REVISION=$revision"
        "MIRMIR_V4_PERFORMANCE_SOURCE_TREE_SHA256=$source_tree_sha256"
        "MIRMIR_V4_PERFORMANCE_WARMUPS=$warmup_count"
        "MIRMIR_V4_PERFORMANCE_SAMPLES=$sample_count"
        "MIRMIR_V4_PERFORMANCE_PRODUCER_NONCE=$invocation_nonce"
        "MIRMIR_V4_PERFORMANCE_PRODUCER_CHALLENGE=$producer_challenge"
        "SWIFT_DETERMINISTIC_HASHING=1"
        "SWIFTC_MAXIMUM_DETERMINISM=1"
        "TMPDIR=$canonical_swift_temporary"
    )
    local source_root_alias
    source_root_alias="$(python3 - "$project_root" <<'PY'
import pathlib
import sys

path = pathlib.PurePosixPath(sys.argv[1]).as_posix()
if not path.startswith("/private/tmp/"):
    raise SystemExit("canonical performance source is outside /private/tmp")
print(path.removeprefix("/private"))
PY
    )"
    local derived_data_alias
    derived_data_alias="$(python3 - "$derived_data" <<'PY'
import pathlib
import sys

path = pathlib.PurePosixPath(sys.argv[1]).as_posix()
if not path.startswith("/private/tmp/"):
    raise SystemExit("canonical performance DerivedData is outside /private/tmp")
print(path.removeprefix("/private"))
PY
    )"
    local -a build_command=(
        xcodebuild
        -jobs 1
        -project Mirmir.xcodeproj
        -scheme Mirmir
        -configuration Release
        -destination platform=macOS
        -derivedDataPath "$derived_data"
        -resultBundlePath "$result_bundle"
        -parallel-testing-enabled NO
        test
        -only-testing:MirmirTests/DeterministicEngineV4PerformanceCaptureTests/testCaptureSameScopePerformanceWhenRequested
        CODE_SIGNING_ALLOWED=NO
        ENABLE_TESTABILITY=YES
        ONLY_ACTIVE_ARCH=YES
        "SWIFT_EXEC=$canonical_swift_wrapper"
        SWIFT_USE_INTEGRATED_DRIVER=NO
        SWIFT_COMPILATION_MODE=wholemodule
        SWIFT_ENABLE_BATCH_MODE=NO
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
        SWIFT_EAGER_MODULE_EMISSION_IN_WMO=NO
        SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO
        SWIFT_USE_PARALLEL_WMO_TARGETS=NO
        SWIFT_WHOLE_MODULE_OPTIMIZATION=YES
        SWIFT_NUM_THREADS=1
        "CLANG_MODULE_CACHE_PATH=$canonical_module_cache"
        "SWIFT_MODULE_CACHE_PATH=$canonical_module_cache"
        "MODULE_CACHE_DIR=$canonical_module_cache"
        "OTHER_SWIFT_FLAGS=\$(inherited) -j 1 -file-prefix-map $project_root=/mirmir-performance-p05 -debug-prefix-map $project_root=/mirmir-performance-p05 -file-prefix-map $source_root_alias=/mirmir-performance-p05 -debug-prefix-map $source_root_alias=/mirmir-performance-p05 -file-prefix-map $derived_data=/mirmir-performance-derived -debug-prefix-map $derived_data=/mirmir-performance-derived -file-prefix-map $derived_data_alias=/mirmir-performance-derived -debug-prefix-map $derived_data_alias=/mirmir-performance-derived -Xllvm -rng-seed=1"
        "OTHER_CFLAGS=\$(inherited) -ffile-prefix-map=$project_root=/mirmir-performance-p05 -fdebug-prefix-map=$project_root=/mirmir-performance-p05 -ffile-prefix-map=$source_root_alias=/mirmir-performance-p05 -fdebug-prefix-map=$source_root_alias=/mirmir-performance-p05 -ffile-prefix-map=$derived_data=/mirmir-performance-derived -fdebug-prefix-map=$derived_data=/mirmir-performance-derived -ffile-prefix-map=$derived_data_alias=/mirmir-performance-derived -fdebug-prefix-map=$derived_data_alias=/mirmir-performance-derived"
        "${build_environment[@]}"
    )
    local command_json="$work_directory/baseline-build-command.json"
    local environment_json="$work_directory/baseline-build-environment.json"
    python3 - "$command_json" "${build_command[@]}" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(sys.argv[2:], indent=2, ensure_ascii=False) + "\n"
)
PY
    python3 - "$environment_json" "${build_environment[@]}" <<'PY'
import json,pathlib,sys
environment = {}
for pair in sys.argv[2:]:
    key, value = pair.split("=", 1)
    if key in environment:
        raise SystemExit(f"duplicate performance producer environment key: {key}")
    environment[key] = value
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(environment, indent=2, sort_keys=True) + "\n"
)
PY
    cp "$environment_json" "$request_path"
    local started_ns
    started_ns="$(python3 -c 'import time; print(time.time_ns())')"
    set +e
    (
        cd "$project_root"
        env "${build_environment[@]}" "${build_command[@]}"
    ) >"$capture_directory/xcodebuild.log" 2>&1
    local exit_status=$?
    set -e
    local finished_ns
    finished_ns="$(python3 -c 'import time; print(time.time_ns())')"
    if (( exit_status != 0 )); then
        tail -n 240 "$capture_directory/xcodebuild.log" >&2
        local failure_diagnostics="$capture_directory/producer/failure-diagnostics"
        local preservation_status=0
        mkdir -m 700 "$failure_diagnostics" || preservation_status=$?
        if (( preservation_status == 0 )); then
            cp -p -- "$canonical_swift_wrapper" \
                "$failure_diagnostics/swiftc" || preservation_status=$?
        fi
        if (( preservation_status == 0 )); then
            cp -p -- "$canonical_swift_audit" \
                "$failure_diagnostics/swift-driver-effective-argv.log" \
                || preservation_status=$?
        fi
        if (( preservation_status == 0 )); then
            cp -p -- "$canonical_swift_frontend_shim" \
                "$failure_diagnostics/swift-frontend" \
                || preservation_status=$?
        fi
        if (( preservation_status == 0 )); then
            cp -p -- "$canonical_swift_frontend_audit" \
                "$failure_diagnostics/swift-frontend-effective-argv.jsonl" \
                || preservation_status=$?
        fi
        if (( preservation_status == 0 )); then
            cp -Rp -- "$canonical_swift_supplementary_maps" \
                "$failure_diagnostics/SupplementaryOutputMaps" \
                || preservation_status=$?
        fi
        if (( preservation_status == 0 )); then
            cp -Rp -- "$canonical_swift_temporary" \
                "$failure_diagnostics/Temporary" \
                || preservation_status=$?
        fi
        cleanup
        trap - EXIT INT TERM
        if (( preservation_status != 0 )); then
            print -u2 "failed to preserve the rejected Swift producer diagnostics"
            return 66
        fi
        return "$exit_status"
    fi
    [[ -f "$capture_directory/capture.json" ]] || {
        print -u2 "$variant test completed without capture.json"
        exit 66
    }
    capture_environment "$capture_directory/environment-after.json"
    [[ -d "$result_bundle" ]] || {
        print -u2 "baseline xcodebuild completed without an xcresult bundle"
        exit 66
    }
    local application_executable
    local test_executable
    application_executable="$(python3 - "$derived_data/Build/Products/Release" \
        '**/Mirmir.app/Contents/MacOS/Mirmir' <<'PY'
import pathlib,sys
root, pattern = pathlib.Path(sys.argv[1]), sys.argv[2]
matches = sorted(path for path in root.glob(pattern) if path.is_file())
if len(matches) != 1:
    raise SystemExit(f"expected one built application executable, found {len(matches)}")
print(matches[0].resolve())
PY
    )"
    test_executable="$(python3 - "$derived_data/Build/Products/Release" \
        '**/MirmirTests.xctest/Contents/MacOS/MirmirTests' <<'PY'
import pathlib,sys
root, pattern = pathlib.Path(sys.argv[1]), sys.argv[2]
matches = sorted(path for path in root.glob(pattern) if path.is_file())
if len(matches) != 1:
    raise SystemExit(f"expected one built test executable, found {len(matches)}")
print(matches[0].resolve())
PY
    )"
    python3 "$evaluator" transcribe \
        --capture "$capture_directory/capture.json" \
        --output "$capture_directory/sample-transcripts.json"
    python3 "$evaluator" summarize-result \
        --result-bundle "$result_bundle" \
        --output "$capture_directory/producer/test-summary.json"
    python3 "$evaluator" seal-baseline-producer \
        --directory "$capture_directory" \
        --contract "$contract" \
        --runner "$runner_path" \
        --invocation-nonce "$invocation_nonce" \
        --challenge "$producer_challenge" \
        --started-ns "$started_ns" \
        --finished-ns "$finished_ns" \
        --working-directory "$project_root" \
        --capture-directory "$capture_directory" \
        --derived-data "$derived_data" \
        --command-json "$command_json" \
        --environment-json "$environment_json" \
        --build-request "$request_path" \
        --application-executable "$application_executable" \
        --test-executable "$test_executable" \
        --locked-input "$locked_input" \
        --result-bundle "$result_bundle" \
        --swift-driver-wrapper "$canonical_swift_wrapper" \
        --swift-driver-audit "$canonical_swift_audit" \
        --swift-frontend-shim "$canonical_swift_frontend_shim" \
        --swift-frontend-audit "$canonical_swift_frontend_audit" \
        --swift-supplementary-maps "$canonical_swift_supplementary_maps" \
        --underlying-swiftc "$underlying_swiftc" || {
            local seal_status=$?
            cleanup
            trap - EXIT INT TERM
            return "$seal_status"
        }
    python3 "$evaluator" seal --directory "$capture_directory"
}

mkdir -p "$output_directory/baseline"

run_capture \
    baseline_p05 \
    "$baseline_revision" \
    "$canonical_source_root" \
    "$output_directory/baseline" \
    "$canonical_derived_data"

if (( baseline_only == 1 )); then
    python3 "$evaluator" verify-baseline-capture \
        --contract "$contract" \
        --directory "$output_directory/baseline"
    print "$output_directory/baseline"
    exit 0
fi

mkdir -p "$output_directory/candidate"

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
python3 "$evaluator" transcribe \
    --capture "$output_directory/candidate/capture.json" \
    --output "$output_directory/candidate/sample-transcripts.json"
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
