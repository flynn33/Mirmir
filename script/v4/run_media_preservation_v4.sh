#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output EVIDENCE_ROOT/media_preservation --candidate CANDIDATE.json --release-configuration Release.xcconfig [--candidate-revision REV] [--derived-data DIR] [--keep-work]"
    print -u2 "       $0 --compile-only [--candidate-revision REV] [--derived-data DIR] [--keep-work]"
    exit 64
}

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
contract="${script_directory}/media-preservation-contract-v1.json"
release_contract="${script_directory}/release-qualification-contract-v1.json"
capture_source="${script_directory}/MediaPreservationCaptureTests.swift"
fixture_source="${repository_root}/MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift"
evaluator="${script_directory}/media_preservation_v4.py"
candidate=""
release_configuration=""
output_directory=""
candidate_revision="HEAD"
derived_data=""
keep_work=0
compile_only=0

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || usage
            output_directory="$2"
            shift 2
            ;;
        --candidate)
            (( $# >= 2 )) || usage
            candidate="$2"
            shift 2
            ;;
        --release-configuration)
            (( $# >= 2 )) || usage
            release_configuration="$2"
            shift 2
            ;;
        --candidate-revision)
            (( $# >= 2 )) || usage
            candidate_revision="$2"
            shift 2
            ;;
        --derived-data)
            (( $# >= 2 )) || usage
            derived_data="$2"
            shift 2
            ;;
        --keep-work)
            keep_work=1
            shift
            ;;
        --compile-only)
            compile_only=1
            shift
            ;;
        *) usage ;;
    esac
done

candidate_revision="$(git -C "$repository_root" rev-parse --verify "${candidate_revision}^{commit}")"
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/mirmir-v4-media-preservation.XXXXXX")"
cleanup() {
    if (( keep_work == 1 )); then
        print -u2 "ephemeral media-preservation workspace retained at $work_directory"
        return
    fi
    case "$work_directory" in
        */mirmir-v4-media-preservation.*) rm -rf -- "$work_directory" ;;
        *) print -u2 "refusing to clean unexpected path: $work_directory" ;;
    esac
}
trap cleanup EXIT INT TERM

project_root="$work_directory/project"
mkdir -p "$project_root"
git -C "$repository_root" archive --format=tar "$candidate_revision" \
    | tar -xf - -C "$project_root"

# The capture must remain in the same source file as the committed private
# fixture factory. Qualification code stays outside both shipping/test targets
# in the repository and is appended only inside this archived candidate.
cp "$capture_source" "$work_directory/capture.swift"
python3 - "$project_root/MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift" \
    "$work_directory/capture.swift" <<'PY'
from pathlib import Path
import sys
target, capture = map(Path, sys.argv[1:])
target.write_bytes(target.read_bytes() + capture.read_bytes())
PY

if [[ -z "$derived_data" ]]; then
    derived_data="$work_directory/DerivedData"
else
    derived_data="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$derived_data")"
fi

if (( compile_only == 1 )); then
    [[ -z "$candidate" && -z "$release_configuration" && -z "$output_directory" ]] || usage
    xcodebuild build-for-testing \
        -project "$project_root/Mirmir.xcodeproj" \
        -scheme Mirmir \
        -configuration Release \
        -destination 'platform=macOS' \
        -derivedDataPath "$derived_data" \
        SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
        ENABLE_TESTABILITY=YES \
        CODE_SIGNING_ALLOWED=NO
    print -r -- "media-preservation capture source compiled in Release"
    exit 0
fi

[[ -n "$candidate" && -n "$release_configuration" && -n "$output_directory" ]] || usage
candidate="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$candidate")"
release_configuration="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$release_configuration")"
output_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$output_directory")"
[[ "${output_directory:t}" == "media_preservation" ]] || {
    print -u2 "output directory must be named media_preservation"
    exit 65
}
if [[ -e "$output_directory" ]] && [[ -n "$(find "$output_directory" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    print -u2 "refusing to overwrite nonempty output directory: $output_directory"
    exit 65
fi

contract_sha256="$(shasum -a 256 "$contract" | awk '{print $1}')"
release_contract_sha256="$(shasum -a 256 "$release_contract" | awk '{print $1}')"
capture_sha256="$(shasum -a 256 "$capture_source" | awk '{print $1}')"
fixture_sha256="$(shasum -a 256 "$fixture_source" | awk '{print $1}')"
evaluator_sha256="$(shasum -a 256 "$evaluator" | awk '{print $1}')"
runner_sha256="$(shasum -a 256 "$0" | awk '{print $1}')"

python3 - "$contract" "$capture_sha256" "$fixture_sha256" \
    "$evaluator_sha256" "$runner_sha256" <<'PY'
import json,sys
contract = json.load(open(sys.argv[1]))
actual = {
    "captureSourceSHA256": sys.argv[2],
    "fixtureSourceSHA256": sys.argv[3],
    "evaluatorSHA256": sys.argv[4],
    "runnerSHA256": sys.argv[5],
}
for key, value in actual.items():
    if contract["capture"].get(key) != value:
        raise SystemExit(f"media-preservation tool identity mismatch for {key}: {value}")
PY

for bound_path in \
    script/v4/media-preservation-contract-v1.json \
    script/v4/MediaPreservationCaptureTests.swift \
    script/v4/media_preservation_v4.py \
    script/v4/run_media_preservation_v4.sh \
    MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift \
    script/v4/release-qualification-contract-v1.json; do
    git -C "$repository_root" cat-file -e "${candidate_revision}:${bound_path}" || {
        print -u2 "candidate revision does not contain locked media harness file: $bound_path"
        exit 66
    }
    committed_hash="$(git -C "$repository_root" show "${candidate_revision}:${bound_path}" | shasum -a 256 | awk '{print $1}')"
    working_hash="$(shasum -a 256 "$repository_root/$bound_path" | awk '{print $1}')"
    [[ "$committed_hash" == "$working_hash" ]] || {
        print -u2 "candidate revision does not bind executing media harness: $bound_path"
        exit 66
    }
done

runtime_manifest="$project_root/Mirmir/Resources/ASH-P06.bundle/runtime-manifest.json"
trust_source="$project_root/Mirmir/Upscaling/Deterministic/DeterministicEngineV4Support.swift"
python3 - "$candidate" "$candidate_revision" "$runtime_manifest" \
    "$trust_source" "$release_configuration" <<'PY'
import hashlib,json,pathlib,re,sys
candidate_path, revision, manifest_text, trust_text, release_text = sys.argv[1:]
candidate = json.load(open(candidate_path))
if candidate.get("sourceCommit") != revision:
    raise SystemExit("media candidate source revision differs")
manifest_path = pathlib.Path(manifest_text)
if not manifest_path.is_file() or manifest_path.is_symlink():
    raise SystemExit("release-qualified P06 runtime manifest is missing or unsafe")
manifest_bytes = manifest_path.read_bytes()
manifest_file_hash = hashlib.sha256(manifest_bytes).hexdigest()
manifest = json.loads(manifest_bytes)
if manifest.get("releaseStatus") != "release_qualified" or manifest.get("runtimeID") != "ash-p06-deterministic-v4":
    raise SystemExit("media candidate P06 runtime is not release-qualified")
if candidate.get("runtimeManifestFileSHA256") != manifest_file_hash:
    raise SystemExit("media candidate runtime-manifest file differs")
if candidate.get("runtimeSourceRevision") != manifest.get("provenance", {}).get("sourceRevision"):
    raise SystemExit("media candidate runtime source revision differs")
if candidate.get("releaseConfigurationSHA256") != hashlib.sha256(pathlib.Path(release_text).read_bytes()).hexdigest():
    raise SystemExit("media candidate Release configuration differs")
trust = pathlib.Path(trust_text).read_text()
def unique(pattern, label):
    values = re.findall(pattern, trust)
    if len(values) != 1:
        raise SystemExit(f"code-owned P06 {label} trust root is not unique")
    return values[0]
trusted_manifest = unique(r'manifestSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"([0-9a-f]{64})"\s*\)', "manifest")
trusted_source = unique(r'sourceRevision\s*=\s*"((?:[0-9a-f]{40}|[0-9a-f]{64}))"', "source")
trusted_builder = unique(r'builderSourceSHA256\s*=\s*try!\s*ASHSHA256V4\(\s*"([0-9a-f]{64})"\s*\)', "builder")
if trusted_manifest == "0" * 64 or trusted_source == "0" * 40 or trusted_builder == "0" * 64:
    raise SystemExit("code-owned P06 trust root is not configured")
if trusted_manifest != candidate.get("runtimeManifestSHA256"):
    raise SystemExit("code-owned P06 semantic manifest identity differs")
if trusted_source != candidate.get("runtimeSourceRevision"):
    raise SystemExit("code-owned P06 source trust root differs")
if trusted_builder != manifest.get("provenance", {}).get("builderSourceSHA256"):
    raise SystemExit("code-owned P06 builder trust root differs")
PY

capture_directory="$work_directory/capture"
mkdir -p "$capture_directory"
cp "$candidate" "$work_directory/candidate.json"

python3 - "$project_root/MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift" \
    "$capture_directory" "$work_directory/candidate.json" \
    "$contract_sha256" "$release_contract_sha256" "$capture_sha256" \
    "$fixture_sha256" "$evaluator_sha256" "$runner_sha256" <<'PY'
from pathlib import Path
import json,sys
path = Path(sys.argv[1])
values = sys.argv[2:]
sentinels = (
    "MIRMIR_V4_MEDIA_CAPTURE_DIR",
    "MIRMIR_V4_MEDIA_CANDIDATE",
    "MIRMIR_V4_MEDIA_LANE_CONTRACT_SHA256",
    "MIRMIR_V4_MEDIA_RELEASE_CONTRACT_SHA256",
    "MIRMIR_V4_MEDIA_CAPTURE_SOURCE_SHA256",
    "MIRMIR_V4_MEDIA_FIXTURE_SOURCE_SHA256",
    "MIRMIR_V4_MEDIA_EVALUATOR_SHA256",
    "MIRMIR_V4_MEDIA_RUNNER_SHA256",
)
text = path.read_text()
for name, value in zip(sentinels, values):
    escaped = json.dumps(value)[1:-1]
    token = f"__{name}__"
    if text.count(token) != 1:
        raise SystemExit(f"capture sentinel is absent or repeated: {token}")
    text = text.replace(token, escaped)
path.write_text(text)
PY

xcodebuild test \
    -project "$project_root/Mirmir.xcodeproj" \
    -scheme Mirmir \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -only-testing:MirmirTests/DeterministicEngineV4MediaPreservationCaptureTests/testCaptureExactMediaPreservationWhenRequested \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    ENABLE_TESTABILITY=YES \
    2>&1 | tee "$capture_directory/xcodebuild.log"

[[ -f "$capture_directory/capture.json" ]] || {
    print -u2 "media-preservation capture did not publish capture.json"
    exit 67
}

python3 "$evaluator" evaluate \
    --capture "$capture_directory" \
    --candidate "$candidate" \
    --output "$output_directory" \
    --contract "$contract" \
    --release-contract "$release_contract" \
    --runtime-manifest "$runtime_manifest" \
    --release-configuration "$release_configuration" \
    --capture-source "$capture_source" \
    --fixture-source "$fixture_source" \
    --runner "$0"
python3 "$evaluator" verify --evidence "$output_directory"
print -r -- "$output_directory/report.json"
