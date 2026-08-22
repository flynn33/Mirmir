#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output EVIDENCE_ROOT/media_preservation --candidate CANDIDATE.json --application-archive Mirmir.zip --release-configuration Release.xcconfig [--candidate-revision REV] [--derived-data DIR] [--keep-work]"
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
application_archive=""
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
        --application-archive)
            (( $# >= 2 )) || usage
            application_archive="$2"
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
    [[ -z "$candidate" && -z "$application_archive" && -z "$release_configuration" && -z "$output_directory" ]] || usage
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

[[ -n "$candidate" && -n "$application_archive" && -n "$release_configuration" && -n "$output_directory" ]] || usage
candidate="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$candidate")"
application_archive="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$application_archive")"
release_configuration="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$release_configuration")"
output_directory="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$output_directory")"
[[ "${output_directory:t}" == "media_preservation" ]] || {
    print -u2 "output directory must be named media_preservation"
    exit 65
}
[[ ! -e "$output_directory" ]] || {
    print -u2 "refusing to overwrite output directory: $output_directory"
    exit 65
}
[[ -d "${output_directory:h}" ]] || {
    print -u2 "output parent does not exist: ${output_directory:h}"
    exit 65
}

python3 - "$candidate" "$candidate_revision" <<'PY_CHECK'
import json,sys
candidate=json.load(open(sys.argv[1]))
if candidate.get("sourceCommit") != sys.argv[2]:
    raise SystemExit("media fixture snapshot differs from candidate source commit")
PY_CHECK

for bound_path in \
    script/v4/media-preservation-contract-v1.json \
    script/v4/MediaPreservationCaptureTests.swift \
    script/v4/media_preservation_v4.py \
    script/v4/packaged_candidate_evidence_v4.py \
    script/v4/run_media_preservation_v4.sh \
    MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift \
    script/v4/release-qualification-contract-v1.json; do
    git -C "$repository_root" cat-file -e "${candidate_revision}:${bound_path}" || {
        print -u2 "candidate revision does not contain media harness file: $bound_path"
        exit 66
    }
    committed_hash="$(git -C "$repository_root" show "${candidate_revision}:${bound_path}" | shasum -a 256 | awk '{print $1}')"
    working_hash="$(shasum -a 256 "$repository_root/$bound_path" | awk '{print $1}')"
    [[ "$committed_hash" == "$working_hash" ]] || {
        print -u2 "candidate revision does not bind executing media harness: $bound_path"
        exit 66
    }
done

fixture_directory="$work_directory/fixture-package"
mkdir -p "$fixture_directory"
python3 - "$project_root/MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift" \
    "$fixture_directory" <<'PY_INJECT'
from pathlib import Path
import json,sys
path=Path(sys.argv[1])
text=path.read_text()
token="__MIRMIR_V4_MEDIA_FIXTURE_DIR__"
if text.count(token) != 1:
    raise SystemExit("media fixture sentinel is absent or repeated")
text=text.replace(token, json.dumps(sys.argv[2])[1:-1])
path.write_text(text)
PY_INJECT

xcodebuild test \
    -project "$project_root/Mirmir.xcodeproj" \
    -scheme Mirmir \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -only-testing:MirmirTests/DeterministicEngineV4MediaPreservationCaptureTests/testGenerateMediaPreservationFixturesWhenRequested \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
    ENABLE_TESTABILITY=YES \
    2>&1 | tee "$work_directory/fixture-xcodebuild.log"

fixture_manifest="$fixture_directory/fixture-manifest.json"
[[ -f "$fixture_manifest" ]] || {
    print -u2 "media fixture host did not publish fixture-manifest.json"
    exit 67
}

packaged_evidence="$work_directory/packaged-media-evidence"
runtime="$repository_root/Mirmir/Resources/ASH-P06.bundle"
python3 "$script_directory/packaged_candidate_evidence_v4.py" capture \
    --repository "$repository_root" \
    --candidate "$candidate" \
    --application-archive "$application_archive" \
    --runtime "$runtime" \
    --release-configuration "$release_configuration" \
    --lane media \
    --contract "$contract" \
    --media-fixture-manifest "$fixture_manifest" \
    --output "$packaged_evidence" \
    --timeout-seconds 3600

python3 "$script_directory/packaged_candidate_evidence_v4.py" verify \
    --repository "$repository_root" \
    --runtime "$runtime" \
    --evidence "$packaged_evidence"

python3 "$evaluator" evaluate \
    --capture "$packaged_evidence/capture" \
    --packaged-evidence "$packaged_evidence" \
    --candidate "$candidate" \
    --application-archive "$application_archive" \
    --output "$output_directory" \
    --contract "$contract" \
    --release-contract "$release_contract" \
    --runtime-manifest "$runtime/runtime-manifest.json" \
    --release-configuration "$release_configuration" \
    --capture-source "$capture_source" \
    --fixture-source "$fixture_source" \
    --runner "$0"
python3 "$evaluator" verify --evidence "$output_directory"
print -r -- "$output_directory/report.json"
