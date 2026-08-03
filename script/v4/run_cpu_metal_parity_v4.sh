#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "usage: $0 --output DIRECTORY --candidate-identity CANDIDATE.json --application-archive Mirmir.zip --runtime ASH-P06.bundle --release-configuration Release.xcconfig [--contract FILE]"
    exit 64
}

script_directory="${0:A:h}"
repository_root="${script_directory:h:h}"
runner_source="${0:A}"
contract_source="${script_directory}/cpu-metal-parity-contract-v2.json"
evaluator_source="${script_directory}/cpu_metal_parity_v4.py"
packaged_tool_source="${script_directory}/packaged_candidate_evidence_v4.py"
observer_source="${repository_root}/Mirmir/App/MirmirApp.swift"

output_directory=""
candidate_identity_source=""
application_archive=""
runtime=""
release_configuration=""
while (( $# > 0 )); do
    case "$1" in
        --output) (( $# >= 2 )) || usage; output_directory="$2"; shift 2 ;;
        --candidate-identity) (( $# >= 2 )) || usage; candidate_identity_source="$2"; shift 2 ;;
        --application-archive) (( $# >= 2 )) || usage; application_archive="$2"; shift 2 ;;
        --runtime) (( $# >= 2 )) || usage; runtime="$2"; shift 2 ;;
        --release-configuration) (( $# >= 2 )) || usage; release_configuration="$2"; shift 2 ;;
        --contract) (( $# >= 2 )) || usage; contract_source="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -n "$output_directory" && -n "$candidate_identity_source" \
    && -n "$application_archive" && -n "$runtime" \
    && -n "$release_configuration" ]] || usage

resolve_existing() {
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve(strict=True))' "$1"
}
resolve_output() {
    python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).expanduser().resolve())' "$1"
}
candidate_identity_source="$(resolve_existing "$candidate_identity_source")"
application_archive="$(resolve_existing "$application_archive")"
runtime="$(resolve_existing "$runtime")"
release_configuration="$(resolve_existing "$release_configuration")"
contract_source="$(resolve_existing "$contract_source")"
default_contract="$(resolve_existing "$script_directory/cpu-metal-parity-contract-v2.json")"
cmp -s -- "$contract_source" "$default_contract" || {
    print -u2 "Release parity contract differs from the candidate-locked contract"
    exit 66
}
output_directory="$(resolve_output "$output_directory")"
[[ ! -e "$output_directory" ]] || {
    print -u2 "Refusing to overwrite parity evidence: $output_directory"
    exit 65
}
mkdir -p -- "${output_directory:h}"

candidate_revision="$(python3 - "$candidate_identity_source" <<'PY'
import json
from pathlib import Path
import sys
value = json.loads(Path(sys.argv[1]).read_text())
value = value.get("candidate", value)
revision = value.get("sourceCommit")
if not isinstance(revision, str) or len(revision) != 40:
    raise SystemExit("candidate source revision is invalid")
print(revision)
PY
)"

# Every executable lane component, including the production observer source,
# must be byte-identical to the candidate commit before the archive can run.
python3 - "$repository_root" "$candidate_revision" \
    script/v4/cpu-metal-parity-contract-v2.json \
    script/v4/cpu_metal_parity_v4.py \
    script/v4/run_cpu_metal_parity_v4.sh \
    script/v4/packaged_candidate_evidence_v4.py \
    Mirmir/App/MirmirApp.swift <<'PY'
from pathlib import Path
import subprocess
import sys
repository = Path(sys.argv[1]).resolve(strict=True)
revision = sys.argv[2]
for relative in sys.argv[3:]:
    process = subprocess.run(
        ["git", "show", f"{revision}:{relative}"],
        cwd=repository,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    local = repository / relative
    if process.returncode != 0 or not local.is_file() or local.is_symlink():
        raise SystemExit(f"candidate omits parity lane input: {relative}")
    if process.stdout != local.read_bytes():
        raise SystemExit(f"executing parity lane differs from candidate: {relative}")
PY
cmp -s -- "$runner_source" "$repository_root/script/v4/run_cpu_metal_parity_v4.sh" || {
    print -u2 "Executing parity runner is not the candidate-bound repository file"
    exit 66
}

mkdir -- "$output_directory"
sealed_tools="$output_directory/sealed-tools"
mkdir -- "$sealed_tools"
cp -- "$contract_source" "$sealed_tools/cpu-metal-parity-contract-v2.json"
cp -- "$observer_source" "$sealed_tools/MirmirApp.swift"
cp -- "$evaluator_source" "$sealed_tools/cpu_metal_parity_v4.py"
cp -- "$packaged_tool_source" "$sealed_tools/packaged_candidate_evidence_v4.py"
cp -- "$runner_source" "$sealed_tools/run_cpu_metal_parity_v4.sh"
cp -- "$candidate_identity_source" "$output_directory/candidate-identity.json"

contract="$sealed_tools/cpu-metal-parity-contract-v2.json"
capture_source="$sealed_tools/MirmirApp.swift"
evaluator="$sealed_tools/cpu_metal_parity_v4.py"
runner="$sealed_tools/run_cpu_metal_parity_v4.sh"
packaged_tool="$sealed_tools/packaged_candidate_evidence_v4.py"

python3 - "$contract" "$capture_source" "$evaluator" "$runner" <<'PY'
from pathlib import Path
import hashlib
import json
import sys
contract_path, capture, evaluator, runner = map(Path, sys.argv[1:])
value = json.loads(contract_path.read_text())
observed = {
    "captureSourceSHA256": hashlib.sha256(capture.read_bytes()).hexdigest(),
    "evaluatorSHA256": hashlib.sha256(evaluator.read_bytes()).hexdigest(),
    "runnerSHA256": hashlib.sha256(runner.read_bytes()).hexdigest(),
}
if value.get("tools") != observed:
    raise SystemExit(f"parity tool identities are stale: {observed}")
PY

packaged_a="$output_directory/packaged-process-a"
packaged_b="$output_directory/packaged-process-b"
for destination in "$packaged_a" "$packaged_b"; do
    python3 "$packaged_tool" capture \
        --repository "$repository_root" \
        --candidate "$candidate_identity_source" \
        --application-archive "$application_archive" \
        --runtime "$runtime" \
        --release-configuration "$release_configuration" \
        --lane parity \
        --contract "$contract" \
        --output "$destination"
done

report="$output_directory/cpu-metal-parity-report.json"
manifest="$output_directory/artifact-manifest.json"
python3 "$evaluator" evaluate \
    --contract "$contract" \
    --capture-a "$packaged_a/capture" \
    --capture-b "$packaged_b/capture" \
    --candidate "$output_directory/candidate-identity.json" \
    --capture-source "$capture_source" \
    --evaluator "$evaluator" \
    --runner "$runner" \
    --packaged-evidence-a "$packaged_a" \
    --packaged-evidence-b "$packaged_b" \
    --repository "$repository_root" \
    --runtime "$runtime" \
    --evidence-root "$output_directory" \
    --output "$report" \
    --manifest "$manifest"

python3 "$evaluator" verify \
    --contract "$contract" \
    --capture-a "$packaged_a/capture" \
    --capture-b "$packaged_b/capture" \
    --candidate "$output_directory/candidate-identity.json" \
    --capture-source "$capture_source" \
    --evaluator "$evaluator" \
    --runner "$runner" \
    --packaged-evidence-a "$packaged_a" \
    --packaged-evidence-b "$packaged_b" \
    --repository "$repository_root" \
    --runtime "$runtime" \
    --evidence-root "$output_directory" \
    --report "$report" \
    --manifest "$manifest"

print -- "$output_directory"
